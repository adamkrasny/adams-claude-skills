---
name: jules-compare
description: "Orchestrate parallel Jules agents to implement a feature, then compare and rank results. Use when user says: 'compare jules implementations', 'jules compare', 'parallel jules', 'have multiple agents try this', 'let jules compete'."
argument-hint: "[--agents N] [idea or prompt]"
---

# Jules Compare Skill

Orchestrate multiple Jules AI agents working in parallel on the same task, then compare their implementations to find the best solution.

---

## Jules CLI Reference

**IMPORTANT:** Always use `npx -y @google/jules@latest` to run Jules commands. This ensures the CLI is available without requiring global installation.

### Available Commands

```bash
# Create new session(s)
npx -y @google/jules@latest new --repo <owner/repo> "<prompt>"
npx -y @google/jules@latest new --repo <owner/repo> --parallel <N> "<prompt>"

# List sessions and check status
npx -y @google/jules@latest remote list --session

# Pull changes from a session
npx -y @google/jules@latest remote pull --session <session_id>           # Show diff only
npx -y @google/jules@latest remote pull --session <session_id> --apply   # Apply changes locally

# Authentication
npx -y @google/jules@latest login
```

### Polling Script

This skill includes a polling script that handles waiting for sessions to complete:

```bash
~/.claude/skills/jules-compare/poll-sessions.sh <session_id1> <session_id2> ...
```

The script polls every 30 seconds and displays a clean status table with URLs. It exits when all sessions reach terminal state.

### Commands That DO NOT Exist (do not try these)
- `npx -y @google/jules@latest --version` - Does not exist
- `npx -y @google/jules@latest auth status` - Does not exist
- `npx -y @google/jules@latest status` - Does not exist
- `npx -y @google/jules@latest check` - Does not exist

### Session Status Values

When parsing `npx -y @google/jules@latest remote list --session` output, these are the possible status values:

| Status | Meaning | Action |
|--------|---------|--------|
| `Planning` | Agent is creating a plan | Keep polling |
| `Awaiting Plan Approval` or `Awaiting Plan A...` | Plan created, will auto-approve shortly | **Keep polling - do NOT ask user to approve** |
| `In Progress` | Agent is implementing | Keep polling |
| `Completed` | Agent finished successfully | Ready for evaluation |
| `Failed` | Agent encountered an error | Mark as failed |
| `Awaiting User F...` | Needs user input (rare) | Keep polling for a few cycles, then notify user |

**CRITICAL:** The "Awaiting Plan Approval" status is TRANSIENT. Plans auto-approve after a short delay. Do NOT stop polling or ask the user to manually approve plans. Just continue the polling loop.

---

## Workflow Overview

This skill executes a 5-phase workflow:

1. **Planning** - Collaborate with user to refine their idea into a clear plan
2. **Dispatch** - Send the task to N parallel Jules agents
3. **Polling** - Monitor progress until all agents complete
4. **Evaluation** - Pull changes, create diffs, perform deep analysis, rank results
5. **Cleanup** - Ask user about branch retention

## State Management

Use Claude's task system to track workflow state. Create a parent task for the workflow and child tasks for each phase. Store critical state in task metadata so the workflow can resume if interrupted.

**Required metadata to track:**
- `phase`: Current workflow phase
- `repo`: GitHub repository (owner/repo format)
- `plan`: The high-level plan created in Phase 1
- `prompt`: The enhanced prompt sent to Jules
- `agentCount`: Number of parallel agents
- `sessions`: Array of `{id, url, status, branch}` for each Jules session

When resuming, read the parent task metadata to determine current state and continue from where you left off.

---

## Phase 1: Planning

**Goal:** Transform the user's idea into a clear, actionable plan.

**Your role:** Act as a sounding board and partner architect. Be collaborative but thorough.

**Steps:**

1. Parse any arguments from the skill invocation:
   - `--agents N` sets the number of parallel agents (default: 5)
   - Everything else is the initial idea/prompt

2. If the user provided an idea, acknowledge it. If not, ask them to describe what they want to build.

3. Ask clarifying questions to understand:
   - What problem does this solve?
   - What are the success criteria?
   - Are there any constraints or preferences?
   - Which parts of the codebase are involved?

4. Inspect relevant files in the project:
   - Read README, CONTRIBUTING, or similar docs
   - Look at the files/modules that will be modified
   - Understand existing patterns and conventions

5. Synthesize a **high-level plan** that includes:
   - **Goals**: What we're trying to achieve (2-3 bullet points)
   - **Approach**: How we'll achieve it (3-5 bullet points)
   - **Key files**: Which files will likely be created/modified
   - **Success criteria**: How we'll know it's done correctly

6. Present the plan to the user and get their approval before proceeding.

7. Create the workflow tracking task:
   ```
   TaskCreate:
     subject: "Jules Compare: [brief description]"
     description: "Parallel Jules workflow for: [idea summary]"
     metadata: {
       phase: "planning",
       plan: "[the approved plan]",
       agentCount: [N],
       sessions: []
     }
   ```

---

## Phase 2: Dispatch

**Goal:** Send the task to multiple Jules agents in parallel.

**Steps:**

1. Auto-detect the repository:
   ```bash
   git remote get-url origin
   ```
   Parse the output to extract `owner/repo` format (handle both HTTPS and SSH URLs).

2. Build the enhanced prompt for Jules. The prompt should include:

   ```
   ## Task
   [Clear description of what to implement]

   ## Plan
   [The high-level plan from Phase 1]

   ## Success Criteria
   [List from the plan]

   ## Important Instructions
   - You are operating in NON-INTERACTIVE mode
   - Do NOT ask questions or request clarification
   - Do NOT wait for user feedback at any point
   - Make reasonable decisions autonomously and proceed
   - If you encounter ambiguity, choose the most sensible option and document your choice
   - Complete the full implementation without stopping

   ## Verification Requirements
   Before marking your work as complete, you MUST verify your changes pass all checks:
   1. If package.json contains a "verify" script, run: npm run verify
   2. Otherwise, run all available linting and type-checking:
      - npm run lint (if available)
      - npm run typecheck (if available)
      - npm run type-check (if available)
      - npm run check (if available)
   3. Fix any errors before completing
   4. Do NOT submit code that fails verification
   ```

3. Execute the Jules command:
   ```bash
   npx -y @google/jules@latest new --repo <owner/repo> --parallel <N> "<prompt>"
   ```

   **IMPORTANT:**
   - Do NOT run this command in the background. You must capture the output synchronously to get the session IDs.
   - Use a longer timeout (e.g., 2-3 minutes) as session creation can take time.
   - The command will block until all sessions are created.

   **If parallel creation partially fails (server errors):**
   - Do NOT fall back to creating sessions individually
   - Do NOT retry with separate `npx -y @google/jules@latest new` commands
   - Instead: proceed with however many sessions were successfully created
   - Inform the user: "X of Y sessions created due to server issues. Proceeding with X agents."
   - If zero sessions were created, wait 30 seconds and retry the parallel command once

4. Parse the output to extract session IDs and URLs. Expected format:
   ```
   N parallel sessions created successfully:
   Task: <prompt>

   Session #N:
     ID: <session_id>
     URL: https://jules.google.com/session/<session_id>
   ```

5. Update the workflow task with session information:
   ```
   TaskUpdate:
     metadata: {
       phase: "polling",
       repo: "<owner/repo>",
       prompt: "<the enhanced prompt>",
       sessions: [
         {id: "<id1>", url: "<url1>", status: "Started", branch: null},
         {id: "<id2>", url: "<url2>", status: "Started", branch: null},
         ...
       ]
     }
   ```

6. Inform the user that agents have been dispatched and provide links to all sessions.

---

## Phase 3: Polling

**Goal:** Monitor all Jules sessions until they reach a terminal state.

**CRITICAL:** This phase is fully autonomous. Do NOT ask the user for input or approval. Just run the polling script and wait for it to complete.

**Steps:**

1. Run the polling script with all session IDs:
   ```bash
   ~/.claude/skills/jules-compare/poll-sessions.sh <session_id_1> <session_id_2> <session_id_3> <session_id_4> <session_id_5>
   ```

   The script will:
   - Poll `npx -y @google/jules@latest remote list --session` every 30 seconds
   - Display a clean status table with Session ID, Status, and Jules Web URL
   - Automatically handle all status transitions (Planning → In Progress → Completed)
   - Exit when ALL sessions reach terminal state (Completed or Failed)
   - Print a final summary

2. **Run with a long timeout** (at least 15-20 minutes) since Jules agents can take time:
   ```bash
   # Use timeout of 20 minutes (1200000ms)
   ```

3. **IMPORTANT:** The script handles everything. Do NOT:
   - Manually poll with separate bash commands
   - Ask the user about plan approval (it's automatic)
   - Display separate status tables between polls

4. **If the polling script fails or exits with an error:**
   - Do NOT fall back to manual polling
   - Do NOT try to implement polling logic yourself
   - STOP and inform the user of the error
   - Ask the user how they want to proceed
   - Provide the session URLs so they can check status manually if needed

5. Once the script completes successfully, read the final summary and proceed to evaluation phase.

**Example output from the script:**
```
Jules Compare - Polling Sessions (every 30s)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Session ID             Status                   URL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
15117933240154076744   In Progress              https://jules.google.com/session/15117933240154076744
7829403212940903160    Completed ✓              https://jules.google.com/session/7829403212940903160
18002240231784670042   Planning                 https://jules.google.com/session/18002240231784670042
11394807168730841386   Awaiting Plan Approval   https://jules.google.com/session/11394807168730841386
92837465019283746501   In Progress              https://jules.google.com/session/92837465019283746501
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Waiting 30s for next poll... (Ctrl+C to stop)
```

---

## Phase 4: Evaluation

**Goal:** Pull changes from each successful agent, create comparison branches, and perform deep analysis.

**Steps:**

### 4a. Prepare branches for each successful session

**NOTE:** Do NOT run lint, typecheck, or verification commands. Jules already verified the code before completing. Just apply the changes and analyze the diffs.

For each session with status "Completed":

1. Ensure we're on a clean working tree:
   ```bash
   git status --porcelain
   ```
   If there are uncommitted changes, warn the user and ask how to proceed.

2. Checkout main and create comparison branch using the **actual numeric session ID**:
   ```bash
   git checkout main
   git pull origin main
   git checkout -b jules-compare/<session_id>
   ```

   For example, if session ID is `15117933240154076744`, create branch `jules-compare/15117933240154076744`.
   Do NOT use generic names like `session-1` or `session-2`.

3. Apply the Jules changes:
   ```bash
   npx -y @google/jules@latest remote pull --session <session_id> --apply
   ```

4. If apply fails (conflicts), mark this session as failed and continue with others.

5. Capture the diff:
   ```bash
   git diff main --stat
   git diff main
   ```
   Store both the summary stats and full diff for analysis.

6. Commit the changes on the branch:
   ```bash
   git add -A
   git commit -m "Jules implementation from session <session_id>"
   ```

7. Update task metadata with branch name for this session.

8. Return to main before processing next session:
   ```bash
   git checkout main
   ```

### 4b. Deep analysis and comparison

After all branches are created, perform a thorough analysis:

1. For EACH implementation, analyze:
   - **Correctness**: Does it meet the success criteria from the plan?
   - **Completeness**: Are all requirements addressed?
   - **Code quality**: Is it well-structured, readable, maintainable?
   - **Consistency**: Does it follow existing codebase patterns?
   - **Edge cases**: Are error conditions and edge cases handled?
   - **Testing**: Were tests added/updated appropriately?
   - **Documentation**: Are changes documented if needed?

2. Compare implementations against each other:
   - What approaches did different agents take?
   - Which made better architectural decisions?
   - Which has fewer potential bugs or issues?
   - Which is more maintainable long-term?

3. Create a detailed comparison document with:
   - Summary table of all implementations
   - Detailed pros/cons for each
   - Code-level observations (specific lines, patterns, issues)
   - Clear recommendation with justification

### 4c. Present results to user

Format the results clearly:

```
# Jules Compare Results

## Summary

| Rank | Session ID           | Status    | Branch                              | Recommendation   |
|------|----------------------|-----------|-------------------------------------|------------------|
| 1    | 15117933240154076744 | Completed | jules-compare/15117933240154076744  | RECOMMENDED      |
| 2    | 7829403212940903160  | Completed | jules-compare/7829403212940903160   | Good alternative |
| 3    | 18002240231784670042 | Failed    | -                                   | Could not apply  |

## Recommended Implementation: Session 15117933240154076744

**Why this is the best choice:**
[Detailed justification]

**Pros:**
- [List of strengths]

**Cons:**
- [List of weaknesses or concerns]

**Key code decisions:**
- [Notable implementation choices]

[Link: https://jules.google.com/session/15117933240154076744]
[Branch: jules-compare/15117933240154076744]

## Alternative: Session 7829403212940903160

[Similar detailed analysis]

## Failed Sessions

### Session 18002240231784670042
**Failure reason:** [explanation]
[Link: https://jules.google.com/session/18002240231784670042]

---

## Next Steps

To use the recommended implementation, create a PR from the Jules interface:
https://jules.google.com/session/15117933240154076744

To review locally first: `git checkout jules-compare/15117933240154076744`
```

---

## Phase 5: Cleanup

**Goal:** Clean up comparison branches based on user preference.

**IMPORTANT:** Do NOT offer to merge any implementation into main. The user will create a PR from the Jules web interface. Your job ends after cleanup.

**Steps:**

1. Ask the user what they'd like to do with the comparison branches:
   - **Keep all**: Leave branches for further inspection
   - **Delete all**: Remove all `jules-compare/*` branches
   - **Keep recommended only**: Delete all except the top-ranked branch

2. Execute their choice:
   ```bash
   git branch -D jules-compare/<session_id>
   ```

3. Mark the workflow task as completed.

4. Provide final summary:
   - Link to recommended Jules session (user will create PR from there)
   - Reminder of which branch (if any) was kept locally

5. **Do NOT:**
   - Offer to merge into main
   - Offer to create a PR
   - Ask if the user wants to apply changes

   The workflow is complete. The user will handle merging via the Jules interface.

---

## Resumption Logic

If the skill is invoked and an existing incomplete workflow task exists:

1. Read the task metadata to determine current phase
2. Resume from that phase:
   - **planning**: Continue the planning conversation
   - **polling**: Resume status polling with stored session IDs
   - **evaluation**: Continue evaluation with stored session data
   - **cleanup**: Re-ask cleanup question

Always check for existing `Jules Compare:*` tasks in progress before starting a new workflow.

---

## Error Handling

- **Jules CLI authentication required**: Inform user to run `npx -y @google/jules@latest login` to authenticate
- **No git repository**: Skill requires being run inside a git repository
- **All agents failed**: Report failure, provide links to sessions for manual inspection
- **Git conflicts on apply**: Mark session as failed, continue with others
- **Network issues during polling**: Retry with backoff, inform user if persistent
- **Session stuck in Awaiting User Feedback for 5+ poll cycles**: Notify user they may need to check the Jules web UI

## Troubleshooting

**If `npx -y @google/jules@latest new` seems to hang:**
- Do NOT cancel and retry immediately
- The command can take 1-2 minutes to create parallel sessions
- Use a timeout of at least 3 minutes
- Check if Jules is authenticated: run `npx -y @google/jules@latest login` if needed

**If session IDs weren't captured:**
- Run `npx -y @google/jules@latest remote list --session` to find recent sessions
- Look for sessions matching your task description
- Sessions are listed with most recent first

---

## Example Invocations

```
/jules-compare Add a dark mode toggle to the settings page

/jules-compare --agents 6 Implement user authentication with JWT

/jules-compare
(Then describe your idea when prompted)
```
