---
name: skill-feedback
description: Analyzes Claude conversation history to find bugs and improvement opportunities for skills. Use when you want to review how a skill performed across multiple conversations, identify failures, user frustrations, or workarounds. Invoke with '/skill-feedback <skill-name>'.
---

# Skill Feedback Analyzer

Analyzes past Claude conversations to identify issues and improvement opportunities for a specific skill.

## Usage

```
/skill-feedback <skill-name> [--project <path>] [--limit <N>]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `<skill-name>` | Yes | Skill to analyze (e.g., `crown-jules`) |
| `--project <path>` | No | Specific project path to search. Omit to search all projects. |
| `--limit <N>` | No | Max conversations to analyze (default: 5) |

## Workflow

### Phase 1: Discovery

1. Parse arguments from the user's invocation
2. Validate the skill exists at `skills/<skill-name>/SKILL.md` in this repository
3. Locate conversation storage at `~/.claude/projects/`
4. If `--project` specified:
   - Encode the path: `/Users/adam/projects/foo` → `-Users-adam-projects-foo`
   - Search only `~/.claude/projects/<encoded>/`
5. Otherwise, search all project directories
6. Read `sessions-index.json` from each project to get session metadata

### Phase 2: Identification

1. Aggregate all session entries from the project index(es) discovered in Phase 1
2. Sort sessions by modified date (most recent first)
3. Take the first N sessions (where N = `--limit`, default 5)
4. For each of these N sessions only, grep the JSONL file for this pattern:
   ```
   <command-name>/skill-name</command-name>
   ```
   For example, to find `crown-jules` invocations: `<command-name>/crown-jules</command-name>`
   This indicates the skill was invoked in that conversation.
5. Return sessions where matches were found (may be fewer than N if skill wasn't used in all sessions)

### Phase 3: Analysis

For each identified conversation JSONL file, search for these issue indicators:

**Error Patterns:**
- `"is_error": true` in tool results
- `ERROR`, `Failed`, `FAILED` keywords
- `Exit code` followed by non-zero numbers
- `Exception`, `Traceback`
- `command not found`, `No such file`

**User Frustration Indicators:**
- `doesn't work`, `broken`, `wrong`
- `bug`, `issue`, `problem`
- `try again`, `redo`, `fix this`

**Workflow Issues:**
- `[Request interrupted by user]` - user cancelled mid-execution
- Multiple retry attempts for same operation
- Claude apologizing and trying alternative approaches

**Script/Tool Failures:**
- Non-zero exit codes from Bash commands
- Tool calls returning errors
- Fallback implementations after script failures

### Phase 4: Report

Present findings in this format:

```markdown
# Skill Feedback Report: <skill-name>

## Summary
- Conversations analyzed: N
- Conversations with issues: N
- Total issues found: N

## High Priority Issues
[Errors, failures, script problems that block functionality]

### Issue 1: [Brief description]
- **Conversation:** [session summary or path]
- **Date:** [timestamp]
- **Details:** [What went wrong]
- **Relevant snippet:** [Quote from conversation]

## Medium Priority Issues
[User complaints, workarounds, interruptions]

## Low Priority Issues
[Minor friction, suggestions for improvement]

## Suggested Improvements
1. [Specific actionable improvement]
2. [Another improvement]
```

### Phase 5: User Decision

After presenting the report, ask the user:

1. **View only** - Just review the findings
2. **Implement fixes** - Have Claude make suggested improvements to the skill
3. **Explore interactively** - Dig deeper into specific issues

## Technical Details

### Path Encoding

Claude stores project conversations with encoded paths:
- `/Users/adam/projects/foo` becomes `-Users-adam-projects-foo`
- The conversations live at `~/.claude/projects/-Users-adam-projects-foo/`

### Session Index Structure

Each project has a `sessions-index.json`:
```json
{
  "entries": [
    {
      "sessionId": "abc123...",
      "fullPath": "/Users/adam/.claude/projects/.../abc123.jsonl",
      "modified": "2026-01-30T10:30:00.000Z",
      "summary": "Working on feature X..."
    }
  ]
}
```

### JSONL Conversation Format

Each line in a `.jsonl` file is a JSON object representing a conversation turn. Look for:
- User messages containing `<command-name>/skill-name</command-name>`
- Assistant tool calls and their results
- Error indicators in tool result content

## Example

```bash
# Analyze crown-jules skill in a specific project
/skill-feedback crown-jules --project /Users/adam/projects/minigame-dreams/main --limit 3

# Analyze across all projects
/skill-feedback crown-jules --limit 10
```

## Error Handling

- If skill doesn't exist: Report "Skill '<name>' not found at skills/<name>/SKILL.md"
- If no conversations found: Report "No conversations found using skill '<name>'"
- If project path doesn't exist: Report "Project path not found: <path>"
