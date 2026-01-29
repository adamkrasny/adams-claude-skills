---
name: crown-jules
description: "Orchestrate parallel Jules agents to implement a feature, then compare and rank results. Use when user says: 'crown jules', 'compare jules implementations', 'jules compare', 'parallel jules', 'have multiple agents try this', 'let jules compete'."
argument-hint: "[idea or prompt]"
---

# Crown Jules Skill

Orchestrate multiple Jules AI agents working in parallel on the same task, then compare their implementations to find the best solution.

---

## Important Notes

- **Requires `JULES_API_KEY` environment variable** - Set your Jules API key before using this skill:
  ```bash
  export JULES_API_KEY='your-api-key'
  ```
- **GitHub repo must be connected to Jules first** - Connect the repository via the [Jules web interface](https://jules.google.com) before using this skill. The API can only use sources that have already been connected.
- **Dependencies**: `curl` and `jq` must be installed (standard on most systems)

## Jules API Reference

This skill uses the Jules REST API (`https://jules.googleapis.com/v1alpha`) for all operations.

### Authentication

All API requests require the `x-goog-api-key` header with your API key.

### API Endpoints Used

| Operation | Endpoint | Method |
|-----------|----------|--------|
| List sources | `/v1alpha/sources` | GET |
| Get source | `/v1alpha/sources/{id}` | GET |
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
~/.claude/skills/crown-jules/create-sessions.sh <repo> <count> "<prompt>" [branch] [title]

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
2. **Dispatch** - Send the task to 4 parallel Jules agents with different prompt strategies
3. **Polling** - Monitor progress until all agents complete
4. **Evaluation** - Generate patches, perform deep analysis, rank results
5. **Cleanup** - Remove patch files and reports

## State Management

Use Claude's task system to track workflow state. Create a parent task for the workflow and child tasks for each phase. Store critical state in task metadata so the workflow can resume if interrupted.

**Required metadata to track:**
- `phase`: Current workflow phase
- `runId`: Unique identifier for this workflow run (use a short random string, e.g., first 8 chars of a UUID)
- `repo`: GitHub repository (owner/repo format)
- `originalPrompt`: The user's original prompt, verbatim
- `plan`: The high-level plan created in Phase 1
- `sessions`: Array of `{id, url, status, promptType}` for each Jules session (promptType is "detailed", "original", or "high-level")

When resuming, read the parent task metadata to determine current state and continue from where you left off.

---

## Phase 1: Planning

**Goal:** Transform the user's idea into a clear, actionable plan.

**Your role:** Act as a sounding board and partner architect. Be collaborative but thorough.

**Steps:**

1. Parse arguments from the skill invocation - everything provided is the initial idea/prompt.

2. **IMMEDIATELY save the user's exact input as `originalPrompt`** - this is critical for the "Original" prompt strategy later. Save it character-for-character, before any clarification or planning. If the user didn't provide an idea, ask them to describe what they want to build and save THAT response verbatim.

3. Ask clarifying questions to understand:
   - What problem does this solve?
   - What are the success criteria?
   - Are there any constraints or preferences?
   - Which parts of the codebase are involved?

4. **Use the Plan agent** to explore the codebase and design the implementation plan:

   ```
   Task:
     subagent_type: "Plan"
     prompt: |
       Explore this codebase and create an implementation plan for the following task:

       ## Task
       [User's idea/request]

       ## Context from user
       [Any clarifications gathered in step 3]

       ## What I need from you
       1. Inspect relevant files (README, existing modules, patterns)
       2. Identify which files will need to be created or modified
       3. Understand existing conventions and patterns
       4. Create a high-level implementation plan with:
          - **Goals**: What we're trying to achieve (2-3 bullet points)
          - **Approach**: How we'll achieve it (3-5 bullet points)
          - **Key files**: Which files will likely be created/modified
          - **Success criteria**: How we'll know it's done correctly

       Return the plan in a structured format I can present to the user.
   ```

5. Review the Plan agent's output and present the plan to the user. Get their approval before proceeding.

6. Generate a unique run ID (first 8 characters of a UUID or similar short random string).

7. Create the workflow tracking task:
   ```
   TaskCreate:
     subject: "Crown Jules: [brief description]"
     description: "Parallel Jules workflow for: [idea summary]"
     metadata: {
       phase: "planning",
       runId: "[unique run ID]",
       originalPrompt: "[the user's original prompt, verbatim]",
       plan: "[the approved plan]",
       sessions: []
     }
   ```

---

## Phase 2: Dispatch

**Goal:** Send the task to 4 Jules agents using different prompt strategies to test which approach yields the best results.

**Prompt Strategy:**
- **2 agents** receive the **detailed enhanced prompt** (full plan with step-by-step guidance)
- **1 agent** receives the **original user prompt** (exactly as provided, unmodified)
- **1 agent** receives a **high-level enhanced prompt** (goals and success criteria only, no detailed plan)

This variety tests whether more guidance helps or hinders the agents.

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

3. Build three different prompts for Jules:

   **Prompt A: Detailed Enhanced Prompt** (used by 2 agents)
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
   - Do NOT create or submit a pull request - just commit your changes

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

   **Prompt B: Original User Prompt** (used by 1 agent)

   **CRITICAL:** Use the `originalPrompt` saved in Phase 1 metadata - the user's EXACT words before any planning or clarification. Do NOT use the refined/expanded version.

   ```
   [originalPrompt from metadata - e.g., "Implement the next feature in @docs/FUTURE_IDEAS.md"]

   ## Important Instructions
   - You are operating in NON-INTERACTIVE mode
   - Do NOT ask questions or request clarification
   - Do NOT wait for user feedback at any point
   - Make reasonable decisions autonomously and proceed
   - Complete the full implementation without stopping
   - Do NOT create or submit a pull request - just commit your changes

   ## Verification Requirements
   Before marking your work as complete, verify your changes pass all checks:
   1. If package.json contains a "verify" script, run: npm run verify
   2. Otherwise, run available linting/type-checking
   3. Fix any errors before completing
   ```

   **Prompt C: High-Level Enhanced Prompt** (used by 1 agent)
   ```
   [Short descriptive title]

   ## Goal
   [1-2 sentences describing what to achieve - extracted from the plan]

   ## Success Criteria
   [List from the plan]

   ## Important Instructions
   - You are operating in NON-INTERACTIVE mode
   - Do NOT ask questions or request clarification
   - Do NOT wait for user feedback at any point
   - Make reasonable decisions autonomously and proceed
   - If you encounter ambiguity, choose the most sensible option and document your choice
   - Complete the full implementation without stopping
   - Do NOT create or submit a pull request - just commit your changes

   ## Verification Requirements
   Before marking your work as complete, verify your changes pass all checks:
   1. If package.json contains a "verify" script, run: npm run verify
   2. Otherwise, run available linting/type-checking
   3. Fix any errors before completing
   ```

4. Execute session creation for each prompt type (run these sequentially, not in parallel):

   ```bash
   # 2 agents with detailed prompt
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> 2 "<Prompt A>" main "Detailed: <short task description>"

   # 1 agent with original prompt
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> 1 "<Prompt B>" main "Original: <short task description>"

   # 1 agent with high-level prompt
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> 1 "<Prompt C>" main "High-Level: <short task description>"
   ```

   The title prefix (Detailed/Original/High-Level) helps identify which prompt strategy each session used.

   **IMPORTANT:**
   - Do NOT run these commands in the background. You must capture the output synchronously to get the session IDs.
   - Use a longer timeout (e.g., 2-3 minutes) as session creation can take time.

   **If session creation partially fails:**
   - Proceed with however many sessions were successfully created
   - Inform the user which prompt types succeeded/failed
   - If zero sessions were created across all types, wait 30 seconds and retry once

5. Parse the output from each call to extract session IDs and URLs from the JSON output.

6. Update the workflow task with session information, noting which prompt type each session used:
   ```
   TaskUpdate:
     metadata: {
       phase: "polling",
       repo: "<owner/repo>",
       sessions: [
         {id: "<id1>", url: "<url1>", status: "Started", promptType: "detailed"},
         {id: "<id2>", url: "<url2>", status: "Started", promptType: "detailed"},
         {id: "<id3>", url: "<url3>", status: "Started", promptType: "original"},
         {id: "<id4>", url: "<url4>", status: "Started", promptType: "high-level"}
       ]
     }
   ```

7. Inform the user that agents have been dispatched with the prompt strategy:
   - 2 agents with **detailed prompt** (full plan)
   - 1 agent with **original prompt** (user's exact words)
   - 1 agent with **high-level prompt** (goals only)

   Provide links to all sessions, noting which prompt type each received.

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
   - Note which prompt type each session used

2. **Metrics table** (informational, from the report):

| Session | Prompt Type | Lines +/- | Files | Tests |
|---------|-------------|-----------|-------|-------|
| [abc123](url) | detailed | +245/-12 | 5 | 2 |
| [def456](url) | original | +189/-8 | 4 | 1 |

3. **Prompt Strategy Insights**:
   - Did the detailed prompt produce better results?
   - How did the original (unmodified) prompt perform?
   - Did the high-level prompt give the agent more useful flexibility?

4. **Recommendation** with clear reasoning:
   - What made this implementation the best fit for the request
   - Any tradeoffs the user should know about

5. **Next steps**:
   - How to apply locally: `git apply .crown-jules/<run_id>/<session_id>.patch`
   - Link to create PR from Jules interface

Example output format:
```
# Crown Jules Results

## My Evaluation

After reviewing all patches against the original request to "add dark mode toggle":

### #1: Session abc123 (detailed prompt)
**Best implementation** - Correctly adds toggle to settings, persists preference to localStorage, and applies theme immediately on change. Clean implementation that does exactly what was asked.

### #2: Session def456 (high-level prompt)
Good attempt but missing localStorage persistence - theme resets on page reload.

### #3: Session ghi789 (detailed prompt)
Similar to #1 but chose a different CSS approach that's slightly more complex.

### #4: Session jkl012 (original prompt)
Over-engineered - added a full theming system with 5 color schemes when only dark/light was requested. Without the specific guidance, the agent interpreted the request too broadly.

## Metrics (informational)

| Session | Prompt Type | Lines +/- | Files | Tests |
|---------|-------------|-----------|-------|-------|
| [abc123](url) | detailed | +245/-12 | 5 | 2 |
| [def456](url) | high-level | +189/-8 | 4 | 1 |
| [ghi789](url) | detailed | +267/-15 | 5 | 2 |
| [jkl012](url) | original | +512/-45 | 12 | 3 |

## Prompt Strategy Insights

In this run, the **detailed prompts** performed best - the explicit plan helped agents stay focused on exactly what was needed. The **original prompt** led to over-engineering, suggesting that more guidance was beneficial for this task. The **high-level prompt** found a middle ground but missed some details.

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
- **Source not found (400 error on session creation)**: The GitHub repository hasn't been connected to Jules. Direct user to connect it at https://jules.google.com first.
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

/crown-jules Implement user authentication with JWT

/crown-jules
(Then describe your idea when prompted)
```
