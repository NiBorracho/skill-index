# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 1.0.x   | ✅        |

## Reporting a Vulnerability

To report a security vulnerability, open an issue at:

```
https://github.com/NiBorracho/skill-index/issues
```

Use the label `security` and prefix the title with `[SECURITY]`.

Expected response time: within 48 hours. Please do not publicly disclose the
vulnerability until a fix has been coordinated and released.

## Security Design

`skill-index` is designed to be auditable and safe by default:

- **Zero network calls** — reads the local filesystem only; no HTTP requests
- **No elevated privileges** — writes only to `~/.claude/skills/skill-index/`
- **No external dependencies** — pure bash + PowerShell built-ins; nothing to supply-chain attack
- **SHA256 content integrity** — every indexed skill carries a checksum in its marker
- **Append-only audit log** — at `~/.claude/skills/skill-index/audit.log`; never modified by the scripts
- **Reproducible output** — same filesystem state always produces the same `INDEX.md`
- **E004 warning** — emitted to stderr when `sha256sum`/`shasum` are unavailable and CRC32 fallback is used

## Generated Files and Privacy

The following files are generated locally and excluded from version control via `.gitignore`:

| File | Contains | Excluded |
|------|----------|----------|
| `INDEX.md` | Skill names and descriptions | ✅ `.gitignore` |
| `audit.log` | Operation timestamps and skill names | ✅ `.gitignore` |
| `.plugins_hash` | SHA256 of `installed_plugins.json` | ✅ `.gitignore` |

No personal data, file paths from your system, or session information is ever
committed to the repository.
