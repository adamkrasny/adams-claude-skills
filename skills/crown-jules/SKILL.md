---
name: crown-jules
description: "Orchestrate parallel Jules agents to implement a feature, then compare and rank results. Use when user says: 'crown jules', 'compare jules implementations', 'jules compare', 'parallel jules', 'have multiple agents try this', 'let jules compete'."
argument-hint: "[--agents N] [idea or prompt]"
---

# Crown Jules Skill

Orchestrate multiple Jules AI agents working in parallel on the same task, then compare their implementations to find the best solution.

---

## Important Notes

- **Requires `JULES_API_KEY` environment variable** - Set your Jules API key before using this skill:
  ```bash
  export JULES_API_KEY='your-api-key'
  ```
- **Dependencies**: `curl` and `jq` must be installed (standard on most systems)

## Jules API Reference

This skill uses the Jules REST API (`https://jules.googleapis.com/v1alpha`) for all operations.

### Authentication

All API requests require the `x-goog-api-key` header with your API key.

### API Endpoints Used

| Operation | Endpoint | Method |
|-----------|----------|--------|
| Create session | `/v1alpha/sessions` | POST |
| Get session status | `/v1alpha/sessions/{id}` | GET |
| Get activities (patches) | `/v1alpha/sessions/{id}/activities` | GET |

### Session States

| API State | Display Name | Action |
|-----------|--------------|--------|
| `QUEUED` | Queued | Keep polling |
| `PLANNING` | Planning | Keep polling |
| `AWAITING_PLAN_APPROVAL` | Awaiting Plan Approval | Keep polling (auto-approves) |
| `IN_PROGRESS` | In Progress | Keep polling |
| `COMPLETED` | Completed | Ready for evaluation |
| `FAILED` | Failed | Mark as failed |
| `AWAITING_USER_FEEDBACK` | Awaiting User Feedback | Keep polling, notify user if persistent |

**CRITICAL:** The "Awaiting Plan Approval" status is TRANSIENT. Plans auto-approve after a short delay. Do NOT stop polling or ask the user to manually approve plans. Just continue the polling loop.

### Scripts

This skill includes several scripts for workflow automation:

```bash
# Create N parallel sessions
~/.claude/skills/crown-jules/create-sessions.sh <repo> <count> "<prompt>" [branch]

# Poll sessions until completion
~/.claude/skills/crown-jules/poll-sessions.sh <session_id1> <session_id2> ...

# Generate patch files from completed sessions
~/.claude/skills/crown-jules/generate-patches.sh <run_id> <session_id1> <session_id2> ...

# Analyze patches and generate comparison report
~/.claude/skills/crown-jules/compare-sessions.sh <run_id> [base_branch]

# Clean up patch files and reports
~/.claude/skills/crown-jules/cleanup.sh <run_id>
```

The `run_id` is a unique identifier for each Crown Jules workflow run. This allows multiple Crown Jules sessions to run in parallel on the same repository without conflicts.

---

## Workflow Overview

This skill executes a 5-phase workflow:

1. **Planning** - Collaborate with user to refine their idea into a clear plan
2. **Dispatch** - Send the task to N parallel Jules agents
3. **Polling** - Monitor progress until all agents complete
4. **Evaluation** - Generate patches, perform deep analysis, rank results
5. **Cleanup** - Remove patch files and reports

## State Management

Use Claude's task system to track workflow state. Create a parent task for the workflow and child tasks for each phase. Store critical state in task metadata so the workflow can resume if interrupted.

**Required metadata to track:**
- `phase`: Current workflow phase
- `runId`: Unique identifier for this workflow run (use a short random string, e.g., first 8 chars of a UUID)
- `repo`: GitHub repository (owner/repo format)
- `plan`: The high-level plan created in Phase 1
- `prompt`: The enhanced prompt sent to Jules
- `agentCount`: Number of parallel agents
- `sessions`: Array of `{id, url, status}` for each Jules session

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
   [Short descriptive title - e.g., "Add dark mode toggle to settings page"]

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

4. Execute the session creation script:
   ```bash
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> <N> "<prompt>" main
   ```

   **IMPORTANT:**
   - Do NOT run this command in the background. You must capture the output synchronously to get the session IDs.
   - Use a longer timeout (e.g., 2-3 minutes) as session creation can take time.

   **If session creation partially fails:**
   - Proceed with however many sessions were successfully created
   - Inform the user: "X of Y sessions created due to server issues. Proceeding with X agents."
   - If zero sessions were created, wait 30 seconds and retry once

5. Parse the output to extract session IDs and URLs from the JSON output.

6. Update the workflow task with session information:
   ```
   TaskUpdate:
     metadata: {
       phase: "polling",
       repo: "<owner/repo>",
       prompt: "<the enhanced prompt>",
       sessions: [
         {id: "<id1>", url: "<url1>", status: "Started"},
         {id: "<id2>", url: "<url2>", status: "Started"},
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
   - Poll each session via API every 30 seconds
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

**Goal:** Generate patch files for each implementation, run automated comparison, and present results.

**Steps:**

### 4a. Generate Patches

1. Extract the `runId` and completed session IDs from workflow metadata.

2. Run the patch generation script:
   ```bash
   ~/.claude/skills/crown-jules/generate-patches.sh <run_id> <session_id_1> <session_id_2> ...
   ```

   The script will:
   - Fetch activities for each session via the Jules API
   - Extract the unified diff patch from the `changeSet.gitPatch.unidiffPatch` field
   - Save patches to `.crown-jules/<run_id>/<session_id>.patch`
   - Report success/failure for each session

3. Verify patches were created:
   ```bash
   ls -la .crown-jules/<run_id>/*.patch
   ```

4. **If the script fails or exits with an error:**
   - Do NOT fall back to manual patch generation
   - STOP and inform the user of the error
   - Ask how they want to proceed

### 4b. Run Automated Analysis

1. Execute the comparison script with the run ID:
   ```bash
   ~/.claude/skills/crown-jules/compare-sessions.sh <run_id> main
   ```

   The script analyzes each patch file and collects metrics:

   | Category | Metrics |
   |----------|---------|
   | **Change** | Lines +/-, files changed, hunks, new/modified/deleted files |
   | **Complexity** | Decision points, max nesting depth, function count |
   | **Patterns** | Test files, type definitions, config changes, comments, error handling |

   **Important:** The script collects metrics but does NOT rank implementations. You (Claude) will evaluate and rank them based on correctness.

2. The script generates two reports in `.crown-jules/<run_id>/`:
   - `report.json` - Machine-readable metrics data
   - `report.md` - Human-readable metrics summary

3. Read the generated reports and patch files:
   ```bash
   cat .crown-jules/<run_id>/report.md    # For metrics summary
   cat .crown-jules/<run_id>/<session_id>.patch  # Read each patch to evaluate correctness
   ```

### 4c. Evaluate and Rank

**This is where you (Claude) evaluate the implementations.** The script only collected metrics - you must read each patch and rank them based on correctness.

**Evaluation criteria (in order of importance):**

1. **Correctness (primary)**: Does it correctly implement what was requested?
   - Does it address the core requirements from the original plan?
   - Does it actually work as expected?
   - Are there bugs, missing pieces, or misunderstandings?

2. **Completeness**: Did it implement everything asked for?
   - All features from the plan included?
   - Edge cases handled appropriately?

3. **Code quality (secondary)**: Is it well-implemented?
   - Follows project conventions
   - Reasonable approach
   - No obvious issues

**Do NOT over-weight:**
- Amount of code (more isn't better, less isn't better)
- Number of tests (nice to have, not required)
- Documentation/comments (nice to have, not required)
- Complexity metrics (informational only)

**Steps:**

1. **Read each patch file** to understand what each implementation actually does:
   ```bash
   cat .crown-jules/<run_id>/<session_id>.patch
   ```

2. **Compare each implementation** against the original plan and success criteria from Phase 1.

3. **Rank the implementations** based primarily on correctness and completeness.

### 4d. Present Results

After your evaluation, present results to the user:

1. **Your rankings** with justification for each:
   - Why #1 is best (what it got right)
   - What each implementation did differently
   - Any issues or gaps you noticed

2. **Metrics table** (informational, from the report):

| Session | Lines +/- | Files | Tests |
|---------|-----------|-------|-------|
| [abc123](url) | +245/-12 | 5 | 2 |
| [def456](url) | +189/-8 | 4 | 1 |

3. **Recommendation** with clear reasoning:
   - What made this implementation the best fit for the request
   - Any tradeoffs the user should know about

4. **Next steps**:
   - How to apply locally: `git apply .crown-jules/<run_id>/<session_id>.patch`
   - Link to create PR from Jules interface

Example output format:
```
# Crown Jules Results

## My Evaluation

After reviewing all patches against the original request to "add dark mode toggle":

### #1: Session abc123
**Best implementation** - Correctly adds toggle to settings, persists preference to localStorage, and applies theme immediately on change. Clean implementation that does exactly what was asked.

### #2: Session def456
Good attempt but missing localStorage persistence - theme resets on page reload.

### #3: Session ghi789
Over-engineered - added a full theming system with 5 color schemes when only dark/light was requested. Also introduced a bug in the CSS that breaks mobile layout.

## Metrics (informational)

| Session | Lines +/- | Files | Tests |
|---------|-----------|-------|-------|
| [abc123](url) | +245/-12 | 5 | 2 |
| [def456](url) | +189/-8 | 4 | 1 |
| [ghi789](url) | +512/-45 | 12 | 3 |

## Recommendation

**Session abc123** is the clear winner - it does exactly what was asked, nothing more, nothing less.

**To apply:** `git apply .crown-jules/<run_id>/abc123.patch`
**To create PR:** https://jules.google.com/session/abc123
```

---

## Phase 5: Cleanup

**Goal:** Clean up patch files and reports.

**IMPORTANT:** Do NOT offer to merge any implementation into main. The user will create a PR from the Jules web interface.

**Steps:**

1. Ask the user if they'd like to clean up now or keep the files for later review.

2. If they want to clean up, execute the cleanup script:
   ```bash
   ~/.claude/skills/crown-jules/cleanup.sh <run_id>
   ```

   The script will:
   - Remove all patch files in `.crown-jules/<run_id>/`
   - Remove reports (report.json, report.md)
   - Remove the entire `.crown-jules/<run_id>/` directory
   - Clean up the parent `.crown-jules/` directory if empty

3. Mark the workflow task as completed.

4. Provide final summary:
   - Link to recommended Jules session (user will create PR from there)

5. **Do NOT:**
   - Offer to merge into main
   - Offer to create a PR
   - Offer to apply changes

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
│   └── <run_id>/
│       ├── <session_id_1>.patch    # Patch file for session 1
│       ├── <session_id_2>.patch    # Patch file for session 2
│       ├── ...
│       ├── report.json             # Machine-readable analysis
│       └── report.md               # Human-readable report
```

This structure allows multiple Crown Jules workflows to run in parallel on the same repository without conflicts. Each run has its own isolated patch files and reports.

---

## Error Handling

- **JULES_API_KEY not set**: Inform user to set the environment variable: `export JULES_API_KEY='your-api-key'`
- **Invalid or expired API key**: Inform user their API key may be invalid and to check/regenerate it
- **No git repository**: Skill requires being run inside a git repository
- **All agents failed**: Report failure, provide links to sessions for manual inspection
- **No patch in activities**: The session may not have generated changes - check the Jules web UI
- **Network issues during polling**: Retry with backoff, inform user if persistent
- **Rate limiting (429 errors)**: Scripts handle this automatically with exponential backoff
- **Session stuck in Awaiting User Feedback for 5+ poll cycles**: Notify user they may need to check the Jules web UI

## Troubleshooting

**If session creation seems slow:**
- API calls can take 10-30 seconds per session
- Creating multiple sessions in parallel helps
- Check your network connection

**If no patches are found:**
- Verify the session completed successfully (not failed)
- Check the Jules web UI to see if the agent made changes
- Some sessions may complete without making changes if the task was unclear

**If you see authentication errors:**
- Verify `JULES_API_KEY` is set: `echo $JULES_API_KEY`
- Ensure the key is valid and not expired
- Try generating a new API key if issues persist

**If session IDs weren't captured:**
- Check the output of create-sessions.sh for errors
- Sessions are also visible in the Jules web UI at https://jules.google.com

---

## Example Invocations

```
/crown-jules Add a dark mode toggle to the settings page

/crown-jules --agents 6 Implement user authentication with JWT

/crown-jules
(Then describe your idea when prompted)
```
