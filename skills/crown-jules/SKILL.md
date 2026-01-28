---
name: crown-jules
description: "Orchestrate parallel Jules agents to implement a feature, then compare and rank results. Use when user says: 'crown jules', 'compare jules implementations', 'jules compare', 'parallel jules', 'have multiple agents try this', 'let jules compete'."
argument-hint: "[--agents N] [idea or prompt]"
---

# Crown Jules Skill

Orchestrate multiple Jules AI agents working in parallel on the same task, then compare their implementations to find the best solution.

---

## Important Notes

- **Always use `npx -y @google/jules@latest`** to run Jules commands. This ensures the CLI is available without requiring global installation.
- **Never use `cd <path> && git ...`** when running git commands on worktrees. Use `git -C <path> ...` instead. This avoids issues with shell hooks (like zoxide) that can break in subprocesses.

## Jules CLI Reference

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
~/.claude/skills/crown-jules/poll-sessions.sh <session_id1> <session_id2> ...
```

The script polls every 30 seconds and displays a clean status table with URLs. It exits when all sessions reach terminal state.

### Evaluation Scripts

These scripts handle the evaluation phase using git worktrees for parallel processing:

```bash
# Create worktrees for all sessions (runs in parallel)
~/.claude/skills/crown-jules/setup-worktrees.sh <run_id> <base_branch> <session_id1> <session_id2> ...

# Analyze all worktrees and generate comparison reports
~/.claude/skills/crown-jules/compare-sessions.sh <run_id> [base_branch]

# Clean up worktrees and optionally branches
~/.claude/skills/crown-jules/cleanup-worktrees.sh <run_id> [true]  # true = also delete branches
```

The `run_id` is a unique identifier for each Crown Jules workflow run. This allows multiple Crown Jules sessions to run in parallel on the same repository without conflicts.

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
- `runId`: Unique identifier for this workflow run (use a short random string, e.g., first 8 chars of a UUID)
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
   - `--agents N` sets the number of parallel agents (default: 4)
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

7. Generate a unique run ID (first 8 characters of a UUID or similar short random string).

8. Create the workflow tracking task:
   ```
   TaskCreate:
     subject: "Crown Jules: [brief description]"
     description: "Parallel Jules workflow for: [idea summary]"
     metadata: {
       phase: "planning",
       runId: "[unique run ID]",
       plan: "[the approved plan]",
       agentCount: [N],
       sessions: []
     }
   ```

---

## Phase 2: Dispatch

**Goal:** Send the task to multiple Jules agents in parallel.

**Steps:**

1. Ensure `.crown-jules` is in `.gitignore`:
   ```bash
   # Check if .gitignore exists and contains .crown-jules (with or without trailing slash)
   grep -qE "^\.crown-jules/?$" .gitignore 2>/dev/null
   ```

   This pattern matches both `.crown-jules` and `.crown-jules/` at the start of a line.

   If the pattern is not found (grep returns non-zero):
   - If `.gitignore` doesn't exist, create it with `.crown-jules/` as the only entry
   - If `.gitignore` exists, append `.crown-jules/` **on a new line**:
     ```bash
     # Ensure we add on a new line (handles files that don't end with newline)
     [[ -s .gitignore && $(tail -c1 .gitignore) != "" ]] && echo "" >> .gitignore
     echo ".crown-jules/" >> .gitignore
     ```
   - Inform the user: "Added `.crown-jules/` to `.gitignore` to prevent workflow files from being committed."

2. Auto-detect the repository:
   ```bash
   git remote get-url origin
   ```
   Parse the output to extract `owner/repo` format (handle both HTTPS and SSH URLs).

3. Build the enhanced prompt for Jules. The prompt should include:

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

4. Execute the Jules command:
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

5. Parse the output to extract session IDs and URLs. Expected format:
   ```
   N parallel sessions created successfully:
   Task: <prompt>

   Session #N:
     ID: <session_id>
     URL: https://jules.google.com/session/<session_id>
   ```

6. Update the workflow task with session information:
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

7. Inform the user that agents have been dispatched and provide links to all sessions.

---

## Phase 3: Polling

**Goal:** Monitor all Jules sessions until they reach a terminal state.

**CRITICAL:** This phase is fully autonomous. Do NOT ask the user for input or approval. Just run the polling script and wait for it to complete.

**Steps:**

1. Run the polling script with all session IDs:
   ```bash
   ~/.claude/skills/crown-jules/poll-sessions.sh <session_id_1> <session_id_2> <session_id_3> <session_id_4>
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
Crown Jules - Polling Sessions (every 30s)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Session ID             Status                   URL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
15117933240154076744   In Progress              https://jules.google.com/session/15117933240154076744
7829403212940903160    Completed ✓              https://jules.google.com/session/7829403212940903160
18002240231784670042   Planning                 https://jules.google.com/session/18002240231784670042
11394807168730841386   Awaiting Plan Approval   https://jules.google.com/session/11394807168730841386
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Waiting 30s for next poll... (Ctrl+C to stop)
```

---

## Phase 4: Evaluation

**Goal:** Create worktrees for parallel analysis, run automated comparison, and present results.

**Steps:**

### 4a. Setup Worktrees

1. Verify clean working state:
   ```bash
   git status --porcelain
   ```
   If there are uncommitted changes, warn the user and ask how to proceed.

2. Extract the `runId` and completed session IDs from workflow metadata.

3. Run the worktree setup script:
   ```bash
   ~/.claude/skills/crown-jules/setup-worktrees.sh <run_id> main <session_id_1> <session_id_2> ...
   ```

   The script will:
   - Create `.crown-jules/<run_id>/worktrees/` directory in the repo root
   - Process all sessions in parallel
   - For each session: create branch `crown-jules/<run_id>/<session_id>` → create worktree → apply Jules changes → commit
   - Report success/failure for each session

4. Verify worktrees were created:
   ```bash
   git worktree list
   ```

5. **If the script fails or exits with an error:**
   - Do NOT fall back to manual worktree creation
   - STOP and inform the user of the error
   - Ask how they want to proceed

### 4b. Run Automated Analysis

1. Execute the comparison script with the run ID:
   ```bash
   ~/.claude/skills/crown-jules/compare-sessions.sh <run_id> main
   ```

   The script analyzes each implementation and collects metrics:

   | Category | Metrics |
   |----------|---------|
   | **Change** | Lines +/-, files changed, hunks, new/modified/deleted files |
   | **Complexity** | Decision points, max nesting depth, function count |
   | **Patterns** | Test files, type definitions, config changes, comments, error handling |

   It calculates scores (0-100) for each implementation:

   | Component | Weight | Criteria |
   |-----------|--------|----------|
   | Size | 25% | Penalize too small (<20 lines) or too large (>1000 lines) |
   | Complexity | 20% | Reward moderate decision points (1-50) |
   | Testing | 25% | Bonus for test files detected |
   | Documentation | 15% | Bonus for comments added |
   | Error handling | 15% | Bonus for try/catch, validation |

2. The script generates two reports in `.crown-jules/<run_id>/`:
   - `report.json` - Machine-readable with full metrics and rankings
   - `report.md` - Human-readable summary

3. Read the generated reports:
   ```bash
   cat .crown-jules/<run_id>/report.json  # For structured data
   cat .crown-jules/<run_id>/report.md    # For readable summary
   ```

### 4c. Present Results

After the automated analysis, present results to the user:

1. **Summary table** with rankings and scores from the report

2. **Recommended implementation** with justification:
   - Why it scored highest
   - Key strengths from metrics
   - Any concerns or tradeoffs

3. **Detailed breakdown** of top 2-3 implementations:
   - Score breakdown by category
   - Change summary (lines, files)
   - Notable patterns detected

4. **Cross-implementation insights**:
   - How approaches differed
   - Common patterns across implementations
   - Unique solutions worth noting

5. **Next steps**:
   - How to review locally: `cd .crown-jules/<run_id>/worktrees/session-<id>`
   - How to view diff: `git diff main` (in worktree)
   - Link to create PR from Jules interface

Example output format:
```
# Crown Jules Results

## Rankings

| Rank | Session | Score | Lines +/- | Files | Tests |
|------|---------|-------|-----------|-------|-------|
| 🥇 1 | [abc123](url) | **78** | +245/-12 | 5 | 2 |
| 🥈 2 | [def456](url) | **65** | +189/-8 | 4 | 1 |
| 🥉 3 | [ghi789](url) | **52** | +312/-45 | 7 | 0 |

## Recommended: Session abc123

**Overall Score: 78**

| Metric | Score |
|--------|-------|
| Size | 72 |
| Complexity | 68 |
| Testing | 100 |
| Documentation | 60 |
| Error Handling | 70 |

**Why this is the best choice:**
- Highest testing score (added 2 test files)
- Moderate complexity with good error handling
- Clean, focused changes

**To review:** `cd .crown-jules-worktrees/session-abc123`
**To create PR:** https://jules.google.com/session/abc123
```

---

## Phase 5: Cleanup

**Goal:** Clean up worktrees and branches based on user preference.

**IMPORTANT:** Do NOT offer to merge any implementation into main. The user will create a PR from the Jules web interface.

**Steps:**

1. Ask the user what they'd like to do:
   - **Keep all**: Leave worktrees and branches for further inspection
   - **Delete worktrees only**: Remove worktrees but keep branches
   - **Delete all**: Remove worktrees and delete all `crown-jules/*` branches

2. Execute their choice using the cleanup script with the run ID:
   ```bash
   # Keep branches (worktrees only)
   ~/.claude/skills/crown-jules/cleanup-worktrees.sh <run_id>

   # Delete everything (worktrees + branches)
   ~/.claude/skills/crown-jules/cleanup-worktrees.sh <run_id> true
   ```

   The script will:
   - Remove all worktrees in `.crown-jules/<run_id>/worktrees/`
   - Optionally delete all `crown-jules/<run_id>/*` branches
   - Remove the entire `.crown-jules/<run_id>/` directory (including reports)
   - Clean up the parent `.crown-jules/` directory if empty
   - Print summary of what was cleaned up

3. Mark the workflow task as completed.

4. Provide final summary:
   - Link to recommended Jules session (user will create PR from there)
   - Reminder of which branches (if any) were kept locally

5. **Do NOT:**
   - Offer to merge into main
   - Offer to create a PR
   - Ask if the user wants to apply changes

   The workflow is complete. The user will handle merging via the Jules interface.

---

## Resumption Logic

If the skill is invoked and an existing incomplete workflow task exists:

1. Read the task metadata to determine current phase and run ID
2. Resume from that phase using the stored run ID:
   - **planning**: Continue the planning conversation
   - **polling**: Resume status polling with stored session IDs
   - **evaluation**: Continue evaluation with stored session data and run ID
   - **cleanup**: Re-ask cleanup question

Always check for existing `Crown Jules:*` tasks in progress before starting a new workflow.

## Directory Structure

All Crown Jules files for a run are stored under `.crown-jules/<run_id>/`:

```
<repo>/
├── .crown-jules/
│   └── <run_id>/                    # Unique per workflow run
│       ├── worktrees/               # Git worktrees
│       │   ├── session-<id1>/       # Worktree with applied changes
│       │   ├── session-<id2>/
│       │   └── ...
│       ├── report.json              # Machine-readable analysis
│       └── report.md                # Human-readable report
```

This structure allows multiple Crown Jules workflows to run in parallel on the same repository without conflicts. Each run has its own isolated worktrees, branches (`crown-jules/<run_id>/<session_id>`), and reports.

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
/crown-jules Add a dark mode toggle to the settings page

/crown-jules --agents 6 Implement user authentication with JWT

/crown-jules
(Then describe your idea when prompted)
```
