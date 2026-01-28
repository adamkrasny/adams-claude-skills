# Agent Instructions for Skills Development

This file contains instructions for LLMs working on this repository.

## Repository Purpose

This repository contains Claude Skills - reusable instruction sets that extend Claude's capabilities for specific tasks.

## Skill File Structure

Each skill lives in its own directory under `skills/`:

```
skills/
└── skill-name/
    ├── SKILL.md              # Required: Main instructions
    ├── REFERENCE.md          # Optional: Detailed reference docs
    ├── EXAMPLES.md           # Optional: Usage examples
    └── scripts/              # Optional: Utility scripts
        └── helper.py
```

## SKILL.md Requirements

Every skill must have a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: skill-name
description: Third-person description of what skill does. When to use it.
---
```

### Frontmatter Rules

**name field:**
- Max 64 characters
- Lowercase letters, numbers, hyphens only
- No reserved words: "anthropic", "claude"
- Gerund form recommended: `processing-pdfs`, `analyzing-data`

**description field:**
- Max 1024 characters, non-empty
- Must be third person ("Processes files..." not "I can help...")
- Include BOTH what it does AND when to use it
- Include trigger phrases users might say

## Writing Effective Skills

### Be Concise

Claude is already intelligent. Only add context Claude doesn't have:
- Domain-specific knowledge
- Project-specific conventions
- Exact commands or scripts to run
- Workflow sequences that must be followed precisely

**Avoid:**
- Explaining what PDFs are
- Describing how libraries work in general
- Verbose introductions

### Progressive Disclosure

Keep `SKILL.md` under 500 lines. Split content into separate files:

```markdown
## Quick Start
[Essential info here]

## Advanced Features
See [ADVANCED.md](ADVANCED.md) for details.
```

Reference files are loaded only when needed, saving context tokens.

### Keep References One Level Deep

Claude may only partially read deeply nested references.

**Good:**
```markdown
# SKILL.md
See [reference.md](reference.md) for API details.
```

**Bad:**
```markdown
# SKILL.md
See [advanced.md](advanced.md)...
# advanced.md
See [details.md](details.md)...
# details.md
The actual information...
```

### Degrees of Freedom

Match specificity to task fragility:

**High freedom** (multiple valid approaches):
```markdown
1. Analyze the code structure
2. Check for potential bugs
3. Suggest improvements
```

**Low freedom** (fragile operations):
```markdown
Run exactly this command:
```bash
python scripts/migrate.py --verify --backup
```
Do not modify flags.
```

### Workflow Checklists

For complex multi-step tasks, provide checkable progress:

```markdown
## Workflow

Copy this checklist:
- [ ] Step 1: Analyze input
- [ ] Step 2: Validate data
- [ ] Step 3: Process results
- [ ] Step 4: Verify output
```

### Feedback Loops

Include validation steps for quality-critical operations:

```markdown
1. Make changes
2. Run: `python validate.py`
3. If errors, fix and repeat step 2
4. Only proceed when validation passes
```

## Scripts

When including utility scripts:

1. Scripts are executed, not loaded into context
2. Make execution intent clear: "Run `script.py`" vs "See `script.py` for algorithm"
3. Handle errors explicitly - don't punt to Claude
4. Document magic numbers and constants
5. Use forward slashes in paths (Unix-style)

## External CLI Tools

When a skill depends on external CLI tools:

1. **Use `npx -y` for npm packages** - Don't assume global installation
   ```bash
   # Good - guaranteed to work
   npx -y @google/jules@latest new --repo owner/repo "prompt"

   # Bad - may fail with "command not found"
   jules new --repo owner/repo "prompt"
   ```

2. **Pin versions when stability matters** - Use `@latest` for always-current, specific versions for reproducibility

3. **Document authentication requirements** - If the CLI needs auth, include the login command in the skill

## Testing Skills

Before finalizing a skill:

1. Create at least 3 evaluation scenarios
2. Test with different Claude models (Haiku needs more guidance than Opus)
3. Verify Claude can navigate the file structure
4. Check that descriptions trigger skill selection correctly

## Common Anti-Patterns to Avoid

- Time-sensitive information ("After August 2025...")
- Inconsistent terminology (mixing "API endpoint", "URL", "path")
- Too many options without a clear default
- Windows-style paths (`folder\file.md`)
- Vague descriptions ("Helps with documents")
- Over-explaining concepts Claude already knows
- Deeply nested file references

## When Modifying Skills

1. Read the existing skill completely before making changes
2. Maintain the established structure and conventions
3. Keep backward compatibility unless explicitly changing behavior
4. Update the description if functionality changes
5. Test that the skill still triggers correctly
