# Adam's Claude Skills

A collection of custom skills for Claude Code and the Claude Agent SDK.

## Structure

```
skills/
├── skill-name/
│   ├── SKILL.md          # Main skill file (required)
│   ├── reference.md      # Additional docs (loaded on-demand)
│   └── scripts/          # Utility scripts (executed, not loaded)
│       └── helper.py
```

## Skills

### [crown-jules](skills/crown-jules/)

Orchestrate multiple Jules AI agents working in parallel on the same task, then compare their implementations to find the best solution.

**Trigger phrases:** `crown jules`, `compare jules implementations`, `jules compare`, `parallel jules`, `have multiple agents try this`, `let jules compete`

**Prerequisites:**
- `JULES_API_KEY` environment variable set
- GitHub repository connected to Jules via [jules.google.com](https://jules.google.com)
- `curl` and `jq` installed

**Workflow:**
1. **Planning** - Collaborate to refine idea into actionable plan
2. **Dispatch** - Send task to 4 parallel Jules agents with different prompt strategies
3. **Polling** - Monitor progress until all agents complete
4. **Evaluation** - Generate patches, analyze, and rank results
5. **Cleanup** - Remove temporary files

**Prompt Strategy:**
- 2 agents with **detailed prompt** (full plan with step-by-step guidance)
- 1 agent with **original prompt** (user's exact words, unmodified)
- 1 agent with **high-level prompt** (goals and success criteria only)

**Example usage:**
```
/crown-jules Add a dark mode toggle to the settings page
/crown-jules Implement user authentication with JWT
```

## Creating a New Skill

1. Create a directory under `skills/` with a descriptive name (kebab-case)
2. Add a `SKILL.md` file with required frontmatter:

```yaml
---
name: your-skill-name
description: What the skill does. When to use it.
---
```

3. Keep `SKILL.md` under 500 lines; split into reference files as needed

## Skill Naming Conventions

- Use lowercase letters, numbers, and hyphens only
- Max 64 characters
- Gerund form recommended: `processing-pdfs`, `reviewing-code`
- Avoid: `anthropic`, `claude`, generic names like `helper` or `utils`

## Installation

To use these skills with Claude Code, symlink or copy the skills directory:

```bash
# Symlink entire skills directory
ln -s /path/to/adams-claude-skills/skills ~/.claude/skills

# Or symlink individual skills
ln -s /path/to/adams-claude-skills/skills/crown-jules ~/.claude/skills/crown-jules
```

## Resources

- [Skills Best Practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Skills Overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- [Claude Code Skills Docs](https://code.claude.com/docs/en/skills)
