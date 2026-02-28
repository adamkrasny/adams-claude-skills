---
name: doc-gardening
description: "Audit and update project documentation against the actual codebase. Detects drift, fixes errors, removes duplication, and tracks runs in docs/.doc-gardening.json. Use after code changes or periodically."
tools: Read, Glob, Grep, Bash, Edit, Write
---

# Doc Gardening

Audit project documentation against the actual codebase, fix drift, and keep docs accurate and concise.

## Philosophy

- **Code is the source of truth** — when docs and code disagree, update the docs
- **AGENTS.md stays minimal** — an index with commands, routing table, conventions, and pointers to `docs/`. `CLAUDE.md` should be a symlink to `AGENTS.md`
- **README.md is for humans** — quick-start guide, not agent documentation
- **Progressive disclosure** — AGENTS.md is read first; detailed docs are followed on demand
- **Tables over prose** — scannable formats are better for humans and agents
- **No stale docs** — wrong documentation is worse than no documentation
- **"Why" over "what"** — focus documentation on architectural boundaries, invariants, business logic, and decisions. Let the code explain the "what". LLMs waste context tokens reading summaries of code they can grep themselves
- **Concise over complete** — if it's obvious from the code, skip documenting it

## Artifact

This skill tracks its state in `docs/.doc-gardening.json`:

```json
{
  "lastRun": "2026-01-15T12:00:00Z",
  "lastCommit": "<full SHA>",
  "dirty": false,
  "documentsAudited": ["AGENTS.md", "docs/architecture.md"],
  "issuesFound": 3,
  "issuesFixed": 3,
  "findings": {
    "errors": ["description"],
    "warnings": ["description"],
    "suggestions": ["description"]
  },
  "blindSpots": ["src/complex-module/ — no documentation coverage"],
  "outcome": "all fixed"
}
```

Commit this file alongside documentation changes so future runs can diff against it.

## Procedure

### Phase 0: Load Prior State

Read `docs/.doc-gardening.json`. If it exists and `lastCommit` is set:

1. Verify the commit exists: `git cat-file -t <lastCommit> 2>/dev/null`
2. Check working tree state: `git status --porcelain`
   - If the working tree is dirty (uncommitted changes), log a warning and set `dirty: true` in the artifact. This forces a **full audit** on the next run to ensure nothing is missed.
   - If the previous run recorded `dirty: true`, run a **full audit** regardless of the commit diff.
3. If HEAD equals `lastCommit` and not dirty, report **"No changes since last audit on [lastRun]"** and stop
4. Get changed files: `git diff --name-only <lastCommit>..HEAD`
5. Enter **incremental mode** — focus drift detection on areas affected by changed files, but still validate all docs for consistency
6. Report scope: "Incremental audit: N files changed since last run on [date]"

If the file doesn't exist, `lastCommit` is null, or the commit is unreachable (e.g. after force-push/rebase) — run a **full audit**.

### Phase 1: Inventory the Project

**Documentation** — Read every documentation file:
- `AGENTS.md` (root) — also check if `CLAUDE.md` is a symlink to it
- `README.md` (root)
- All files in `docs/` (glob `docs/**/*`)
- Skill files in `.claude/skills/` (for cross-references only)

For each doc, note what source files, commands, configs, and metrics it references.

**Source code** — Discover all source files:
- Identify source directories (`src/`, `lib/`, `app/`, or language-specific layouts)
- Glob source files by language (`.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.rs`, `.go`, etc.)
- In incremental mode, highlight which files changed since last audit

**Configuration** — Read build and config files:
- Package manager manifest (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`)
- Build configs (`tsconfig.json`, `vite.config.ts`, `webpack.config.js`, etc.)
- Any project-specific config files referenced in documentation

### Phase 2: Detect Drift

Compare every claim in the docs against actual code. Check these categories:

| Category | What to Verify |
|----------|----------------|
| **Accuracy** | File paths exist. Commands work (match scripts in package.json). Config values match actual config files. Behavior descriptions match implementations. |
| **Code snippets** | Inline code snippets in markdown match the actual source. Check function signatures, variable names, parameter types, and return types against real code. Code examples that have drifted are the fastest way to break an LLM's understanding. |
| **Completeness** | New source modules are mentioned somewhere in docs. New scripts are listed. New features are described. New config files are noted. New dependencies are listed. |
| **Consistency** | Same entity described the same way everywhere. No contradictions between docs. Terminology is uniform across all files. |
| **Duplication** | Information isn't needlessly repeated across docs. Details in AGENTS.md that belong in `docs/`. Redundant descriptions across files. |
| **Freshness** | Metrics match reality — test counts, file counts, dependency versions. Dates are current. Status descriptions reflect current state. |
| **AGENTS.md shape** | Minimal index, not a reference manual. Routing table lists all `docs/` files. Verify command is correct. No bloat (detailed content should be in `docs/`). `CLAUDE.md` is a symlink to `AGENTS.md` (not a separate file with divergent content). |
| **Orphaned docs** | Every markdown file in `docs/` is reachable from the root manifest (`AGENTS.md`). If an LLM cannot discover a doc file from the root manifest, that document effectively doesn't exist to the agent. Flag unreachable files. |

**Command verification**: For commands documented in markdown (build, test, deploy, etc.):
1. Verify they match entries in the package manifest (`package.json` scripts, `Makefile` targets, etc.)
2. For custom CLI commands or scripts, check they exist on disk and are executable
3. When feasible, run `<command> --help` or a dry-run to confirm the command still works

To verify metrics concretely:
- Run test suite with verbose output and compare documented counts
- Glob and count source files vs documented counts
- Read package manifest for actual dependency versions
- Compare actual directory structure against documented structure

### Phase 3: Report Findings

Present a structured report **before making any changes**:

```
## Doc Gardening Report

### Scope
- Mode: [Full audit | Incremental since <date> (<N> files changed)]
- Documents audited: N
- Source files checked: N
- Working tree: [clean | dirty — will force full audit next run]

### Errors (facts wrong or missing — will fix)
- [file:section] What's wrong → what it should say

### Warnings (staleness, duplication — will fix unless judgement needed)
- [file:section] Description

### Suggestions (improvements — only with user approval)
- [file:section] What could be better

### Orphaned Files (docs not linked from root manifest)
- [file] — not reachable from AGENTS.md

### Blind Spots (complex areas with no documentation)
- [directory/module] — description of what it does, why it should be documented

### Clean
- Files with no issues: [list]
```

### Phase 4: Apply Fixes

1. **Errors** — Fix all: wrong facts, missing items, broken paths, incorrect commands, drifted code snippets
2. **Warnings** — Fix straightforward ones. Ask user about ambiguous cases
3. **Orphaned files** — Add missing links to the routing table in AGENTS.md, or ask user if the file should be removed
4. **Suggestions** — Only if user explicitly approves
5. **Deletions** — Never delete docs or remove sections without user confirmation

Use the Edit tool for targeted changes. Preserve existing structure, formatting, and tone.

### Phase 5: Validate AGENTS.md Shape

After all edits, confirm AGENTS.md is a minimal index:
- Project name + one-line description
- Commands / verification block
- Context routing table (one row per `docs/` file — every file in `docs/` must be listed)
- Key files or source layout summary
- Key conventions (brief)
- Skills table (if applicable)

Anything more detailed belongs in `docs/`.

Also verify `CLAUDE.md` is a symlink to `AGENTS.md`. If it's a separate file, flag this for consolidation.

### Phase 6: Update Artifact

```bash
git rev-parse HEAD
git status --porcelain
```

Write `docs/.doc-gardening.json`:

```json
{
  "lastRun": "<current ISO 8601 UTC timestamp>",
  "lastCommit": "<full SHA from git rev-parse HEAD>",
  "dirty": <true if git status --porcelain shows changes, false otherwise>,
  "documentsAudited": ["<every doc file checked>"],
  "issuesFound": <total errors + warnings + suggestions>,
  "issuesFixed": <total fixed>,
  "findings": {
    "errors": ["<brief description of each>"],
    "warnings": ["<brief description of each>"],
    "suggestions": ["<brief description of each>"]
  },
  "blindSpots": ["<dir/module — brief description of undocumented complex area>"],
  "outcome": "<clean | all fixed | partial>"
}
```

Outcome values:
- `"clean"` — no drift found
- `"all fixed"` — all issues resolved
- `"partial"` — some issues need user decision

**Blind spots**: During the audit, if you notice complex source directories or modules (multiple files, non-trivial logic) with zero documentation coverage, add them to `blindSpots`. This creates a backlog of areas where LLM context is known to be weak. Only include genuinely complex areas, not simple utility files.

### Phase 7: Verify

Run the project's verification command to confirm nothing broke:
1. Check for a `verify` script (`npm run verify`, `make verify`, `cargo check`, etc.)
2. If found, run it
3. If not, run available lint / typecheck / build commands
4. Fix any issues before finishing
