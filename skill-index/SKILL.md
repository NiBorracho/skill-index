---
name: skill-index
description: Use when deciding which of 50+ installed skills to invoke. Reads a compact one-line-per-skill index to identify ALL relevant skills in one operation instead of invoking each individually.
version: 1.0.0
author: Gabriel D. DG <gabrieldesiog@gmail.com>
license: MIT
repository: https://github.com/NiBorracho/skill-index
---

# Skill Index

## Overview

**Problem:** With 150+ installed skills, finding the right one by invoking each individually takes ~12.5 minutes (150 × 5s/call). The `Skill` tool loads full content even when you only need the 1-2 line description.

**Solution:** A compact `INDEX.md` file (~15KB for 150 skills) that Claude reads in one `Read` tool call, then identifies and invokes **all** relevant skills — no limit.

**Impact:** ~12.5 min → ~15 seconds to identify and load the right skills.

---

## When to Use

| Situation | Action |
|-----------|--------|
| Choosing which skills to invoke (50+ installed) | Read INDEX.md first |
| After installing a new skill | Run `build-index.sh update` |
| After removing a skill | Run `build-index.sh remove <name>` |
| Index missing or corrupted | Run `build-index.sh build` |
| Debugging skill discovery | Run `build-index.sh debug` |

**Do NOT** invoke skills blindly before reading the index when you have 50+ skills available.

---

## Querying the Index

```
1. Read("~/.claude/skills/skill-index/INDEX.md")
2. Scan for entries matching keywords from the current task
3. Identify ALL relevant skills (no maximum — invoke every one that applies)
4. Skip entries marked as ~~deprecated~~
5. Invoke identified skills with the Skill tool
```

Reading the index costs 1 `Read` operation. Invoke as many skills as the task requires.

---

## Index File Format

Location: `~/.claude/skills/skill-index/INDEX.md`

Each skill entry uses HTML comment markers for reliable, auditable parsing:

```markdown
<!-- SKILL:skill-name:vX.Y.Z:sha256:abc123 -->
- **skill-name** [source@version] — description from frontmatter
<!-- /SKILL:skill-name -->
```

- **Markers** guarantee idempotent updates (each `add`/`remove` targets exactly one block)
- **SHA256** detects when a skill file changes between sessions
- **Deprecated entries** use strikethrough: `~~**skill-name**~~`
- **Sections** group skills by source plugin for readability

The file also contains metadata blocks:
```markdown
<!-- SKILL_INDEX_META
generated: ISO8601
version: 1.0.0
total: 152
checksum: sha256:...
-->
```
and an audit block at the end:
```markdown
<!-- SKILL_INDEX_AUDIT
last_build: ISO8601
last_change: ISO8601
integrity: valid
-->
```

---

## Installation & Passive Setup

Run once after installing this skill:

```bash
# Linux / Mac / WSL
bash ~/.claude/skills/skill-index/scripts/install-hooks.sh

# Windows PowerShell
& "$env:USERPROFILE\.claude\skills\skill-index\scripts\install-hooks.sh"
# or use the PowerShell installer:
powershell -File "$env:USERPROFILE\.claude\skills\skill-index\scripts\build-index.ps1" install-hooks
```

This adds a `SessionStart` hook to `~/.claude/settings.json` that runs `build-index.sh update --quiet` on every session start. The update operation:
- Compares `installed_plugins.json` hash against the last recorded hash
- Only re-scans if plugins changed (< 1s when nothing changed)
- Adds new skills, removes uninstalled ones, updates changed descriptions

**No manual commands needed after this one-time setup.**

---

## Operations Reference

| Command | Description |
|---------|-------------|
| `build-index.sh build` | Full scan, rebuild INDEX.md from scratch |
| `build-index.sh update [--quiet]` | Diff-based update (fast, used by hook) |
| `build-index.sh add <name> <path>` | Register a specific skill by path |
| `build-index.sh remove <name>` | Remove skill from index |
| `build-index.sh deprecate <name> "<reason>"` | Mark skill as deprecated |
| `build-index.sh verify` | Validate checksums and integrity |
| `build-index.sh query "<keywords>"` | Search index (outputs matches to stdout) |
| `build-index.sh debug` | Full diagnostic: paths scanned, errors, stats |

PowerShell equivalent: `build-index.ps1 <command> [args]` — identical interface.

---

## Scanned Locations

The scripts search for `SKILL.md` files in:

```
~/.claude/plugins/cache/*/[plugin]/[version]/skills/*/SKILL.md
~/.claude/plugins/cache/*/[plugin]/[version]/.agents/skills/*/SKILL.md
~/.claude/skills/*/SKILL.md
~/.agents/skills/*/SKILL.md
```

Skills missing a valid `name` or `description` in frontmatter are logged as `E001` errors and skipped.

---

## Error Codes

| Code | Cause | Remedy |
|------|-------|--------|
| `E001` | SKILL.md missing `name` or `description` in frontmatter | Fix the skill's frontmatter |
| `E002` | Duplicate skill name, different paths | Check for conflicting plugins |
| `E003` | INDEX.md not found | Run `build` to create it |
| `E004` | SHA256 not available — CRC32 fallback active (integrity weakened) | Install `sha256sum` or `shasum` |
| `E005` | Plugin path in `installed_plugins.json` not found on disk | Reinstall the plugin |

All errors are written to `~/.claude/skills/skill-index/audit.log` with timestamp and error code.

---

## Audit Log

Every operation appends to `audit.log`:

```
2026-04-23T14:00:00Z BUILD  full_scan        total=152  duration=4.2s
2026-04-23T14:05:00Z ADD    brainstorming    v5.0.7     sha256:abc123
2026-04-23T14:06:00Z REMOVE old-skill        v1.0.0
2026-04-23T15:00:00Z UPDATE api-design       v1.9.0→v2.0.0
2026-04-23T15:01:00Z DEPRECATE legacy-skill  reason="replaced by new-skill"
2026-04-23T15:02:00Z VERIFY  integrity=valid total=153  changed=1
2026-04-23T16:00:00Z ERROR   E001            path=...   missing=description
```

The audit log is append-only and never modified by the scripts — safe for external monitoring (socket.dev, Snyk, CI pipelines).

---

## Security & Auditability

- **No external dependencies** — pure bash + PowerShell built-ins only
- **No network calls** — filesystem operations only
- **No elevated privileges** — writes only to `~/.claude/skills/skill-index/`
- **Reproducible** — same filesystem state always produces the same INDEX.md
- **Auditable format** — plain markdown + HTML comments readable by any tool
- **socket.dev / Snyk compatible** — nothing to scan (zero package dependencies)

---

## Common Mistakes

| Mistake | Correct behavior |
|---------|-----------------|
| Invoking skills without reading the index first | Always `Read(INDEX.md)` before invoking |
| Stopping after finding 1 relevant skill | Invoke ALL skills that match the task |
| Using deprecated entries | Skip `~~strikethrough~~` entries |
| Forgetting to run `install-hooks.sh` | The passive hook only works after setup |
| Manually editing INDEX.md | Always use the scripts — manual edits break checksums |
