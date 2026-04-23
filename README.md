# skill-index

> Auto-maintained index of all installed Claude Code / agent skills.  
> Reduces skill discovery from **~12.5 minutes → ~15 seconds** for 150+ skills.

---

## The Problem

When 150+ skills are installed, finding the right one is expensive:

- Each `Skill` tool invocation loads the **full content** of a skill (~5 seconds)
- 150 skills × 5s = **12.5 minutes** just in invocations
- No centralized catalog exists — discovery is blind guessing

## The Solution

`skill-index` maintains a compact `INDEX.md` (~15KB for 150 skills) with **one line per skill**. Claude reads it in a single `Read` tool call, identifies **all** relevant skills, and invokes only those.

```
Before: invoke skill1? → invoke skill2? → invoke skill3? → ... (12.5 min)
After:  Read INDEX.md → find matches → invoke all relevant (15 sec)
```

---

## Installation

### Step 1 — Install the skill

**Recommended (via `skills` CLI):**

```bash
# GitHub shorthand
npx skills add NiBorracho/skill-index

# Full URL
npx skills add https://github.com/NiBorracho/skill-index

# Any git URL
npx skills add git@github.com:NiBorracho/skill-index.git
```

**Manual install (git clone):**

```bash
# Linux / Mac / WSL
git clone https://github.com/NiBorracho/skill-index.git ~/.claude/skills/skill-index

# Windows PowerShell
git clone https://github.com/NiBorracho/skill-index.git "$env:USERPROFILE\.claude\skills\skill-index"
```

### Step 2 — Run the one-time setup

```bash
# Linux / Mac / WSL
bash ~/.claude/skills/skill-index/scripts/install-hooks.sh

# Windows PowerShell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\skill-index\scripts\build-index.ps1" install-hooks
```

This adds a `SessionStart` hook that auto-updates the index on every session start.  
**No manual maintenance needed after this.**

---

## How It Works

```
Session Start
     │
     ▼
build-index.sh update --quiet
     │
     ├── installed_plugins.json unchanged? → exit (< 1s)
     │
     └── changed? → scan all SKILL.md files → update INDEX.md → write audit.log
```

Every SKILL.md across all plugin locations is scanned:

```
~/.claude/plugins/cache/*/[plugin]/[version]/skills/*/SKILL.md
~/.claude/plugins/cache/*/[plugin]/[version]/.agents/skills/*/SKILL.md
~/.claude/skills/*/SKILL.md
~/.agents/skills/*/SKILL.md
```

---

## Manual Commands

```bash
build-index.sh build                    # Full rebuild from scratch
build-index.sh update [--quiet]         # Diff-based update (used by hook)
build-index.sh add <name> <path>        # Register a specific skill
build-index.sh remove <name>            # Remove from index
build-index.sh deprecate <name> "why"   # Mark as deprecated
build-index.sh verify                   # Validate checksums and integrity
build-index.sh query "keywords"         # Search the index (debug)
build-index.sh debug                    # Full diagnostic output
```

PowerShell: same interface via `build-index.ps1`.

---

## Index Format

`~/.claude/skills/skill-index/INDEX.md`

```markdown
<!-- SKILL_INDEX_META
generated: 2026-04-23T14:00:00Z
version: 1.0.0
total: 152
checksum: sha256:abc123...
-->

# Skill Index

<!-- SKILL_INDEX:START -->

## superpowers
<!-- SKILL:brainstorming:v5.0.7:sha256:abc123 -->
- **brainstorming** [superpowers@5.0.7] — Use before creative/feature work
<!-- /SKILL:brainstorming -->

## DEPRECATED
<!-- SKILL:old-skill:deprecated:2026-04-20:reason:replaced -->
- ~~**old-skill**~~ [deprecated:2026-04-20] — replaced by new-skill
<!-- /SKILL:old-skill -->

<!-- SKILL_INDEX:END -->
```

HTML comment markers guarantee reliable, idempotent updates and external auditability.

---

## Audit Log

All operations are appended to `~/.claude/skills/skill-index/audit.log`:

```
2026-04-23T14:00:00Z BUILD      full_scan total=152 duration=4.2s
2026-04-23T14:05:00Z ADD        brainstorming v5.0.7 sha256:abc123
2026-04-23T14:06:00Z REMOVE     old-skill v1.0.0
2026-04-23T15:01:00Z DEPRECATE  legacy-skill reason="replaced"
2026-04-23T15:02:00Z VERIFY     integrity=valid total=153 changed=1
2026-04-23T16:00:00Z ERROR      E001 missing=description path=...
```

---

## Error Codes

| Code | Cause | Fix |
|------|-------|-----|
| `E001` | SKILL.md missing `name` or `description` | Fix the skill's frontmatter |
| `E002` | Duplicate skill name, different paths | Check for conflicting plugins |
| `E003` | INDEX.md not found | Run `build` to create it |
| `E004` | SHA256 not available — CRC32 fallback active | Install `sha256sum` or `shasum` |
| `E005` | Plugin path not found on disk | Reinstall the plugin |

---

## Security

- **Zero dependencies** — pure bash + PowerShell built-ins
- **No network calls** — filesystem only
- **No elevated privileges** — writes only to `~/.claude/skills/skill-index/`
- **Reproducible** — same filesystem → same INDEX.md
- **Auditable** — plain markdown + HTML comments readable by any tool
- **socket.dev / Snyk compatible** — nothing to scan

---

## Compatibility

| Platform | Script | Status |
|----------|--------|--------|
| Linux / Mac | `build-index.sh` | ✅ Full support |
| WSL (Windows) | `build-index.sh` | ✅ Full support |
| Windows PowerShell 5.1+ | `build-index.ps1` | ✅ Full support |
| PowerShell 7+ | `build-index.ps1` | ✅ Full support |
| Any agent with skills filesystem | Either script | ✅ Compatible |

---

## Contributing

PRs welcome for:
- New skill scan paths (new agent platforms)
- Additional shell support (fish, zsh wrappers)
- Bug fixes with test cases

---

## Author

**Gabriel D. DG** — [@NiBorracho](https://github.com/NiBorracho) — `gabrieldesiog@gmail.com`

---

## License

MIT — Copyright © 2026 Gabriel D. DG — see [LICENSE](LICENSE)
