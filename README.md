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

| Skill | Description |
|-------|-------------|
| [jules-compare](skills/jules-compare/) | Orchestrate parallel Jules agents to implement a feature, then compare and rank results |

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
ln -s /path/to/adams-claude-skills/skills/jules-compare ~/.claude/skills/jules-compare
```

## Resources

- [Skills Best Practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Skills Overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- [Claude Code Skills Docs](https://code.claude.com/docs/en/skills)
