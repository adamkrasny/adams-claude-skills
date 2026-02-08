---
name: crown-jules
description: "Orchestrate parallel Jules agents to implement a feature, then compare and rank results. Use when user says: 'crown jules', 'compare jules implementations', 'jules compare', 'parallel jules', 'have multiple agents try this', 'let jules compete'."
argument-hint: "[idea or prompt] [--quick]"
---

# Crown Jules Skill

Orchestrate multiple Jules AI agents working in parallel on the same task, then compare their implementations to find the best solution.

---

## Prerequisites

Before using this skill, ensure the following are set up:

1. **Set `JULES_API_KEY` environment variable**:
   ```bash
   export JULES_API_KEY='your-api-key'
   ```

2. **Connect your GitHub repo to Jules**: Visit [jules.google.com](https://jules.google.com) and connect the repository you want to work with. The API can only use sources that have already been connected.

3. **Install dependencies**: `curl` and `jq` must be installed (standard on most systems).

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

# Generate patch files from completed sessions (auto-fallback to git if API fails)
~/.claude/skills/crown-jules/generate-patches.sh <run_id> <session_id1> <session_id2> ...

# Analyze patches and generate comparison report
~/.claude/skills/crown-jules/compare-sessions.sh <run_id> [base_branch]

# Clean up patch files and reports
~/.claude/skills/crown-jules/cleanup.sh <run_id>

# Create PR from winning session
~/.claude/skills/crown-jules/create-pr.sh <session_id>
```

The `run_id` is a unique identifier for each Crown Jules workflow run. This allows multiple Crown Jules sessions to run in parallel on the same repository without conflicts.

---

## Workflow Overview

This skill executes a 5-phase workflow:

1. **Prompt Crafting** - Research the codebase, then enhance the user's prompt with useful context
2. **Dispatch** - Send the same enhanced prompt to 3 parallel Jules agents
3. **Polling** - Monitor progress until all agents complete
4. **Evaluation** - Generate patches, perform deep analysis, rank results
5. **Cleanup** - Remove patch files and reports

### Quick Mode

Use `--quick` to skip clarification questions and proceed directly:

```
/crown-jules --quick Add dark mode toggle to settings page
```

Quick mode is useful when:
- You have a clear, well-defined task
- You've already thought through the implementation
- You want to minimize back-and-forth

In quick mode:
- The Explore agent still researches the codebase for context
- But no clarifying questions are asked
- Dispatch begins immediately after prompt crafting

## State Management

Use Claude's task system to track workflow state. Create a parent task for the workflow and child tasks for each phase. Store critical state in task metadata so the workflow can resume if interrupted.

**Required metadata to track:**
- `phase`: Current workflow phase
- `runId`: Unique identifier for this workflow run (use a short random string, e.g., first 8 chars of a UUID)
- `repo`: GitHub repository (owner/repo format)
- `originalPrompt`: The user's original prompt, verbatim
- `enhancedPrompt`: The crafted prompt from Phase 1
- `sessions`: Array of `{id, url, status}` for each Jules session

When resuming, read the parent task metadata to determine current state and continue from where you left off.

---

## Phase 1: Prompt Crafting

**Goal:** Research the codebase, then enhance the user's prompt with useful context — while keeping it as a natural, high-level prompt that gives Jules creative freedom.

**Your role:** Act as a prompt engineer and codebase researcher. Your job is to make the prompt *smarter*, not more *specific*. Jules does its own planning, code review, and decision-making — don't take that away from it.

**Steps:**

1. Parse arguments from the skill invocation:
   - Check for `--quick` flag - if present, enable quick mode
   - Everything else is the initial idea/prompt

2. **Save the user's exact input as `originalPrompt`** - If the user didn't provide an idea, ask them to describe what they want to build.

3. **Gather brief clarifications if needed** (skip in quick mode):

   **Auto-detect detailed prompts:** If the prompt already contains specific details (file references, clear requirements, technical specifics), skip clarifications.

   **For vague prompts:** Ask 1-2 focused questions to understand what they actually want. Don't over-interrogate.

4. **Use the Explore agent** to research the codebase:

   ```
   Task:
     subagent_type: "Explore"
     prompt: |
       I need to understand this codebase well enough to give context to an AI coding
       agent that will implement the following task:

       "[User's idea/request]"

       Research and return:
       1. Tech stack and key frameworks/libraries
       2. Project structure conventions (where do components/modules/tests live?)
       3. Relevant patterns the codebase already uses (state management, API patterns,
          styling approach, etc.)
       4. Any existing code that's closely related to this task

       Keep it concise — just the facts an implementer would need to make good decisions.
   ```

5. **Craft the enhanced prompt.** This is the critical step. The output should read like a well-written prompt from a knowledgeable developer — NOT like a spec, plan, or instruction set.

   **Prompt crafting principles:**
   - Keep it in plain English, conversational tone
   - State the GOAL clearly — what the user wants to achieve and how they'll know it's working
   - Include codebase context as background info ("This project uses X, components live in Y")
   - Do mention relevant architectural details Jules should be aware of
   - Do mention any constraints or preferences the user expressed
   - Don't prescribe HOW to solve the problem — that's Jules's job
   - Don't list specific files to edit
   - Don't diagnose specific bottlenecks or bugs — let Jules investigate
   - Don't suggest specific solutions or technologies to use
   - Don't include step-by-step implementation instructions
   - Don't include commands to run

   **The key test:** If your prompt reads like an answer to the problem, it's too prescriptive. The prompt should be the *question*, not the *answer*. Jules is a capable agent that can read code, profile performance, identify issues, and design solutions. Let it.

   **Enhanced prompt structure:**
   ```
   [Clear statement of what to build/change and the success criteria — 1-3 sentences]

   [Codebase context paragraph — tech stack, architecture, relevant patterns.
   Written as background info, not instructions.]

   [Any constraints or requirements the user cares about]

   Important:
   - Do NOT ask questions or request clarification — make reasonable decisions and proceed
   - Do NOT wait for user feedback at any point
   - Clean up any dead code your changes create
   - Before finishing, verify your changes: if a "verify" script exists (npm run verify,
     ./verify, etc.), run it. Otherwise run available linting/type-checking. Fix any errors.
   ```

   **Example 1 — simple feature:**

   Bad (too prescriptive):
   ```
   ## Task
   Add dark mode toggle to settings page

   ## Plan
   1. Create ThemeContext in src/contexts/ThemeContext.tsx
   2. Modify src/components/Settings.tsx to add toggle
   3. Update src/styles/globals.css with dark theme variables

   ## Files to modify
   - src/contexts/ThemeContext.tsx (create)
   - src/components/Settings.tsx (modify)
   - src/styles/globals.css (modify)
   ```

   Good (states goal, gives context, lets Jules decide how):
   ```
   Add a dark mode toggle to the settings page. The toggle should persist the
   user's preference and apply the theme immediately when changed.

   This is a Next.js app using Tailwind CSS. The app currently has no theming
   system. State management uses React context — see src/contexts/ for existing
   examples of how contexts are structured in this project.
   ```

   **Example 2 — complex optimization (notice: NO diagnoses, NO prescribed solutions):**

   Bad (does Jules's job — diagnoses every issue and prescribes solutions):
   ```
   Optimize to support 50k particles at 60 FPS. The main bottlenecks are:
   1. RENDERING (~8-15ms): 50k individual ctx.drawImage() calls. Switch to
      WebGL instanced rendering — data is already in typed arrays.
   2. SYNC OVERHEAD (~2-3ms): syncAliveCount() iterates all 150k slots.
      Eliminate by having the worker maintain its own free list.
   3. COLLISION (~4-8ms): Spatial hash cell size is 20px, too fine. Increase
      to 40-60px. Reduce particleSolverIterations adaptively.
   4. STATIC BODIES (~1-2ms): Vertices serialized every frame via postMessage.
      Add a dirty flag and only re-send when modified.
   Key files: src/renderer.js, src/particles.js, src/particle-worker.js...
   ```

   Good (states the goal and context, lets Jules profile and decide):
   ```
   Optimize the physics and rendering systems to comfortably support 50,000
   particles at 60 FPS. Currently at 50k the frame rate drops noticeably.

   This is a vanilla JS ES module project with no build system — just ES
   modules served via a Python HTTP server. It uses Matter.js (from CDN) for
   rigid bodies and a custom SoA Verlet particle system for high-volume
   particles. Rendering is Canvas 2D with a sprite cache. A Web Worker with
   SharedArrayBuffer handles particle physics off-thread when available.

   Note: the particle physics code exists in two files that must stay in
   sync — one for the main thread and one for the worker.

   Keep Canvas 2D rendering as a fallback if you introduce an alternative.
   ```

6. **Present the enhanced prompt to the user** for approval. Show them exactly what will be sent to Jules so they can adjust if needed.

7. Generate a unique run ID (first 8 characters of a UUID or similar short random string).

8. Create the workflow tracking task:
   ```
   TaskCreate:
     subject: "Crown Jules: [brief description]"
     description: "Parallel Jules workflow for: [idea summary]"
     metadata: {
       phase: "prompt-crafting",
       runId: "[unique run ID]",
       originalPrompt: "[the user's original prompt, verbatim]",
       enhancedPrompt: "[the crafted prompt]",
       sessions: []
     }
   ```

---

## Phase 2: Dispatch

**Goal:** Send the enhanced prompt to 3 Jules agents in parallel.

**Strategy:**
Each agent receives a **slightly rephrased version** of the same prompt. The meaning and requirements stay identical, but the wording varies — reordering sentences, using synonyms, restructuring paragraphs. This nudges Jules's non-deterministic problem-solving so each agent is more likely to explore a genuinely different path.

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

3. **Create 3 variations of the enhanced prompt.** Take the prompt from Phase 1 and rephrase it twice to create 3 total versions. Each variation must:
   - Preserve the exact same requirements, constraints, and codebase context
   - Change the wording: reorder sentences, use synonyms, restructure paragraphs
   - Keep the same "Important" operational instructions section at the end (don't rephrase the "Do NOT ask questions" etc. — those should stay exact)

   The goal is surface-level variation only — like three different developers describing the same task. Do NOT change what's being asked for, add new requirements, or remove any.

4. Execute session creation (run these sequentially, not in parallel):

   ```bash
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> 1 "<variation 1>" main "Crown Jules #1: <short task description>"
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> 1 "<variation 2>" main "Crown Jules #2: <short task description>"
   ~/.claude/skills/crown-jules/create-sessions.sh <owner/repo> 1 "<variation 3>" main "Crown Jules #3: <short task description>"
   ```

   **IMPORTANT:**
   - Do NOT run these commands in the background. You must capture the output synchronously to get the session IDs.
   - Use a longer timeout (e.g., 2-3 minutes) as session creation can take time.

   **If session creation partially fails:**
   - Proceed with however many sessions were successfully created
   - Inform the user which sessions succeeded/failed
   - If zero sessions were created, wait 30 seconds and retry once

5. Parse the output from each call to extract session IDs and URLs from the JSON output.

6. Update the workflow task with session information:
   ```
   TaskUpdate:
     metadata: {
       phase: "polling",
       repo: "<owner/repo>",
       sessions: [
         {id: "<id1>", url: "<url1>", status: "Started"},
         {id: "<id2>", url: "<url2>", status: "Started"},
         {id: "<id3>", url: "<url3>", status: "Started"}
       ]
     }
   ```

7. Inform the user that 3 agents have been dispatched with the same prompt. Provide links to all sessions.

---

## Phase 3: Polling

**Goal:** Monitor all Jules sessions until they reach a terminal state.

**CRITICAL:** This phase is fully autonomous. Do NOT ask the user for input or approval. Just run the polling script and wait for it to complete.

**Steps:**

1. Run the polling script with all session IDs:
   ```bash
   ~/.claude/skills/crown-jules/poll-sessions.sh <session_id_1> <session_id_2> <session_id_3>
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
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Poll #3 - Waiting 30s... (Ctrl+C to stop)
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
   - First try to fetch patches via the Jules API (`activities` endpoint)
   - If API fails, automatically fall back to git-based patch generation:
     - Fetches the session details to get the working branch name
     - Uses `git fetch` + `git diff` to generate the patch locally
   - Save patches to `.crown-jules/<run_id>/<session_id>.patch`
   - Report success/failure and which method was used for each session

3. Verify patches were created:
   ```bash
   ls -la .crown-jules/<run_id>/*.patch
   ```

4. **Handle patch generation results:**

   **If some patches succeeded but others failed:**
   - Inform the user which sessions have patches and which don't
   - Ask: "Continue evaluation with N available patches, or would you like to investigate the failed sessions first?"
   - If a session shows "completed but made no changes", explain that Jules may have interpreted the task differently or decided no changes were needed
   - Provide links to failed sessions so user can review in the Jules web UI

   **If ALL sessions failed:**
   - The script will output helpful error messages and session URLs
   - Inform the user which sessions failed and why
   - Provide the Jules web URLs so they can manually review implementations
   - Ask if they want to continue with manual evaluation or abort

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
   - Does it address the core requirements from the original prompt?
   - Does it actually work as expected?
   - Are there bugs, missing pieces, or misunderstandings?

2. **Completeness**: Did it implement everything asked for?
   - All features from the prompt included?
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

2. **Compare each implementation** against the original prompt and the user's requirements.

3. **Rank the implementations** based primarily on correctness and completeness.

### 4d. Present Results

After your evaluation, present results to the user:

1. **Your rankings** with justification for each:
   - Why #1 is best (what it got right)
   - What each implementation did differently (architecture, patterns, trade-offs)
   - Any issues or gaps you noticed

2. **Metrics table** (informational, from the report):

| Session | Lines +/- | Files | Tests |
|---------|-----------|-------|-------|
| [abc123](url) | +89/-12 | 3 | 1 |
| [def456](url) | +245/-18 | 5 | 4 |
| [ghi789](url) | +156/-15 | 4 | 2 |

3. **How the solutions diverged**: Since all agents received the same prompt, highlight the interesting ways they chose different paths — different architectures, different libraries, different trade-offs. This is the value of running multiple agents.

4. **Recommendation** with clear reasoning:
   - What made this implementation the best fit for the request
   - Any tradeoffs the user should know about

5. **Next steps**:
   - **Winner URL**: Direct link to the winning Jules session (always include this prominently)
   - How to apply locally: `git apply .crown-jules/<run_id>/<session_id>.patch`

Example output format:
```
# Crown Jules Results

## My Evaluation

After reviewing all 3 patches against the original request to "add dark mode toggle":

### #1: Session abc123
**Best implementation** - Correctly adds toggle to settings, persists preference to localStorage, and applies theme immediately on change. Clean, focused implementation that does exactly what was asked.

### #2: Session def456
Good implementation with clear code organization. Took a different approach — created a dedicated `useTheme` hook and CSS custom properties instead of Tailwind's dark mode. Well-structured but slightly more complex than needed.

### #3: Session ghi789
Interesting approach using system preference detection as the default, with the manual toggle as an override. However, missed persisting the preference across sessions — a significant gap.

## Metrics (informational)

| Session | Lines +/- | Files | Tests |
|---------|-----------|-------|-------|
| [abc123](url) | +89/-12 | 3 | 1 |
| [def456](url) | +156/-15 | 4 | 2 |
| [ghi789](url) | +245/-18 | 5 | 4 |

## How They Diverged

All three agents received the same prompt but made different choices:
- **abc123** used Tailwind's built-in dark mode with a simple context provider
- **def456** built a custom CSS variable system, more flexible but more code
- **ghi789** prioritized system preference detection, focusing on OS integration

## Recommendation

**Session abc123** is the best fit — it delivers the feature correctly with the least complexity, using patterns already in the codebase.

**Winner:** https://jules.google.com/session/abc123

**To apply locally:** `git apply .crown-jules/<run_id>/abc123.patch`
```

### 4e. Create PR (Optional)

After presenting your recommendation, ask the user:
> "Would you like me to create a PR from the winning implementation?"

If yes:
1. Run the PR creation script:
   ```bash
   ~/.claude/skills/crown-jules/create-pr.sh <winning_session_id>
   ```

2. The script will:
   - Send a message to the Jules session requesting PR creation
   - Poll until the PR is created (up to 2 minutes)
   - Output the PR URL

3. Present the PR URL to the user:
   > "PR created: https://github.com/owner/repo/pull/123"

**If the script fails:**
- Inform the user that automatic PR creation failed
- Provide the manual fallback: Jules web UI link
- Do NOT attempt to create the PR manually or try workarounds

---

## Phase 5: Cleanup

**Goal:** Clean up patch files and reports.

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
   - **Always include the winning session URL**: `https://jules.google.com/session/<winning_session_id>`
   - If a PR was created in Phase 4e, also include the PR URL

---

## Resumption Logic

If the skill is invoked and an existing incomplete workflow task exists:

1. Read the task metadata to determine current phase and run ID
2. Resume from that phase using the stored run ID:
   - **prompt-crafting**: Continue crafting the enhanced prompt
   - **polling**: Resume status polling with stored session IDs
   - **evaluation**: Continue evaluation with stored session data and run ID
   - **pr-creation**: Offer PR creation again
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
- **No patch in activities**: Script automatically tries git fallback; if that also fails, check the Jules web UI
- **Network issues during polling**: Retry with backoff, inform user if persistent
- **Rate limiting (429 errors)**: Scripts handle this automatically with exponential backoff
- **Session stuck in Awaiting User Feedback for 5+ poll cycles**: Notify user they may need to check the Jules web UI

## Troubleshooting

**If session creation seems slow:**
- API calls can take 10-30 seconds per session
- Creating multiple sessions in parallel helps
- Check your network connection

**If no patches are found:**
- The script automatically tries a git-based fallback when the API fails
- If both methods fail, verify the session completed successfully (not failed)
- Check the Jules web UI to see if the agent made changes
- Some sessions may complete without making changes if the task was unclear

**If you see "used git fallback" in patch generation:**
- This is normal - the Jules API activities endpoint sometimes doesn't return patches
- The script successfully fetched the branch and generated patches via `git diff`
- These patches are equivalent to what the API would have returned

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

# Quick mode - skip planning clarifications
/crown-jules --quick Fix the login button styling on mobile

# Detailed prompt - auto-detected, minimal clarifications
/crown-jules
* Fix bug in user authentication flow
* Add error handling for network failures
* Update the login form validation
* Ensure logout clears all session data
```
