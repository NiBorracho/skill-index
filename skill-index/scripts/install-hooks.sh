#!/usr/bin/env bash
# install-hooks.sh — One-time setup for passive skill-index maintenance
# Adds a SessionStart hook to ~/.claude/settings.json that auto-updates
# the skill index on every Claude Code session start.
# Version: 1.0.0

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/build-index.sh"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
AUDIT_LOG="${CLAUDE_DIR}/skills/skill-index/audit.log"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

audit() {
  mkdir -p "$(dirname "${AUDIT_LOG}")"
  touch "${AUDIT_LOG}"
  printf '%s %-10s %s\n' "$(ts)" "$1" "$2" >> "${AUDIT_LOG}"
}

# Detect Python — test actual execution (Windows Store stubs exist but fail)
PY_CMD=""
for cmd in py python3 python; do
  if command -v "$cmd" &>/dev/null && "$cmd" -c "import sys" &>/dev/null 2>&1; then
    PY_CMD="$cmd"
    break
  fi
done

if [[ -z "$PY_CMD" ]]; then
  echo "ERROR: Python not found. Install Python 3 and try again."
  exit 1
fi

echo "=== Skill Index Hook Installer ==="
echo "Python: ${PY_CMD}"
echo ""

# Verify build script exists and is executable
if [[ ! -f "${BUILD_SCRIPT}" ]]; then
  echo "ERROR: build-index.sh not found at: ${BUILD_SCRIPT}"
  echo "Make sure the skill-index package is properly installed."
  exit 1
fi
chmod +x "${BUILD_SCRIPT}"

HOOK_CMD="bash \"${BUILD_SCRIPT}\" update --quiet"

echo "Hook command: ${HOOK_CMD}"
echo "Settings file: ${SETTINGS_FILE}"
echo ""

# Ensure ~/.claude directory exists
mkdir -p "${CLAUDE_DIR}"

# Use Python to safely inject/create the hook (handles JSON correctly)
"${PY_CMD}" - "${SETTINGS_FILE}" "${HOOK_CMD}" <<'PYEOF'
import json, sys, os

settings_file = sys.argv[1]
hook_cmd      = sys.argv[2]

# Settings file doesn't exist yet
if not os.path.exists(settings_file):
    config = {"hooks": {"SessionStart": [{"command": hook_cmd}]}}
    with open(settings_file, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"Created {settings_file} with SessionStart hook.")
    sys.exit(0)

# Load existing settings
try:
    with open(settings_file, "r", encoding="utf-8") as f:
        config = json.load(f)
except json.JSONDecodeError as e:
    print(f"ERROR: Could not parse {settings_file}: {e}", file=sys.stderr)
    print(f"Please add manually: hooks.SessionStart: [{{\"command\": \"{hook_cmd}\"}}]", file=sys.stderr)
    sys.exit(1)

# Check if already present
hooks = config.setdefault("hooks", {})
session_start = hooks.setdefault("SessionStart", [])
if any("build-index" in h.get("command", "") for h in session_start):
    print(f"Hook already present in {settings_file}.")
    sys.exit(0)

session_start.append({"command": hook_cmd})
with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print(f"Hook added to {settings_file}")
PYEOF

audit "INSTALL_HOOKS" "settings.json updated"

echo ""
echo "Running initial build..."
bash "${BUILD_SCRIPT}" build

echo ""
echo "=== Setup complete ==="
echo "The skill index will auto-update at the start of every Claude Code session."
echo ""
echo "Manual commands available:"
echo "  bash ${BUILD_SCRIPT} build       # Full rebuild"
echo "  bash ${BUILD_SCRIPT} verify      # Check integrity"
echo "  bash ${BUILD_SCRIPT} debug       # Diagnostics"
echo "  bash ${BUILD_SCRIPT} query <kw>  # Search the index"
