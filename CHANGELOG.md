# Changelog

All notable changes to `skill-index` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `remove` command now requires interactive confirmation (`[y/N]`) before deleting a skill from the index — accidental deletions prevented

## [1.0.0] — 2026-04-23

### Added

- `INDEX.md` format: one line per skill with HTML comment markers for reliable, idempotent parsing
- SHA256 integrity checksum per skill entry (`<!-- SKILL:name:vX.Y.Z:sha256:hash -->`)
- Passive auto-update via `SessionStart` hook — zero manual commands after one-time setup
- Smart scan using `installed_plugins.json` as source of truth (no false duplicates)
- Full lifecycle commands: `build`, `update`, `add`, `remove`, `deprecate`, `verify`, `query`, `debug`, `install-hooks`
- Error codes E001–E005 with structured audit log entries (ISO8601 timestamps)
- Diff-based update: only re-scans when `installed_plugins.json` changes (< 1s when unchanged)
- Bash script (`build-index.sh`) for Linux / Mac / WSL / Git Bash on Windows
- PowerShell script (`build-index.ps1`) for Windows PowerShell 5.1+
- One-time setup script (`install-hooks.sh`) with multi-Python detection for Windows compatibility
- Grouped index output by source plugin for readability
- `SKILL_INDEX_AUDIT` block in `INDEX.md` tracking last build and last change timestamps

### Security

- Regex injection hardening: `add`, `remove`, `deprecate` use `awk index()` (exact string match) instead of regex; `verify` uses `grep -Fx` (fixed string, whole-line match)
- PowerShell: `[regex]::Escape($Name)` applied before all `-replace` operations
- E004 warning emitted to stderr when `sha256sum`/`shasum` unavailable and CRC32 fallback is active
- Python hook injection uses `sys.argv` instead of bash string interpolation into heredoc
- Generated files (`INDEX.md`, `audit.log`, `.plugins_hash`) excluded from version control via `.gitignore`
