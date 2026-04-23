#!/usr/bin/env bash
# build-index.sh — Skill Index manager
# Usage: build-index.sh <command> [args]
# Commands: build | update [--quiet] | add <name> <path> | remove <name>
#           deprecate <name> "<reason>" | verify | query "<keywords>" | debug
# Version: 1.0.0

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

CLAUDE_DIR="${HOME}/.claude"
AGENTS_DIR="${HOME}/.agents"
INDEX_DIR="${CLAUDE_DIR}/skills/skill-index"
INDEX_FILE="${INDEX_DIR}/INDEX.md"
AUDIT_LOG="${INDEX_DIR}/audit.log"
PLUGINS_JSON="${CLAUDE_DIR}/plugins/installed_plugins.json"
PLUGINS_HASH_FILE="${INDEX_DIR}/.plugins_hash"
VERSION="1.0.0"

# Skill search paths (glob patterns, evaluated at runtime)
SCAN_PATHS=(
  "${CLAUDE_DIR}/plugins/cache"
  "${CLAUDE_DIR}/skills"
  "${AGENTS_DIR}/skills"
)

# ─── Helpers ──────────────────────────────────────────────────────────────────

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'; }

_SHA256_WARNED=false

sha256_file() {
  local f="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    if [[ "$_SHA256_WARNED" != "true" ]]; then
      _SHA256_WARNED=true
      echo "[E004] sha256sum/shasum not available — using CRC32 fallback (integrity weakened)" >&2
    fi
    cksum "$f" | awk '{print $1}'
  fi
}

sha256_string() {
  local s="$1"
  if command -v sha256sum &>/dev/null; then
    printf '%s' "$s" | sha256sum | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  else
    if [[ "$_SHA256_WARNED" != "true" ]]; then
      _SHA256_WARNED=true
      echo "[E004] sha256sum/shasum not available — using CRC32 fallback (integrity weakened)" >&2
    fi
    printf '%s' "$s" | cksum | awk '{print $1}'
  fi
}

audit() {
  local level="$1"; shift
  printf '%s %-10s %s\n' "$(ts)" "$level" "$*" >> "${AUDIT_LOG}"
}

err() {
  local code="$1"; shift
  audit "ERROR" "${code} $*"
  echo "[${code}] $*" >&2
}

ensure_dirs() {
  mkdir -p "${INDEX_DIR}"
  touch "${AUDIT_LOG}"
}

# Extract frontmatter field from a SKILL.md file
extract_field() {
  local file="$1"
  local field="$2"
  # Matches: field: value OR field: "value" (with optional quotes)
  awk -v f="^${field}:" '
    /^---$/ { fm++; next }
    fm==1 && $0 ~ f {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
    fm==2 { exit }
  ' "$file"
}

# Determine source label from file path
source_label() {
  local path="$1"
  local rel="${path#${CLAUDE_DIR}/plugins/cache/}"
  if [[ "$rel" != "$path" ]]; then
    # Extract: publisher/plugin-name@version
    local publisher plugin version
    publisher=$(echo "$rel" | cut -d'/' -f1)
    plugin=$(echo "$rel" | cut -d'/' -f2)
    version=$(echo "$rel" | cut -d'/' -f3)
    echo "${plugin}@${version}"
  elif [[ "$path" == ${CLAUDE_DIR}/skills/* ]]; then
    echo "local"
  elif [[ "$path" == ${AGENTS_DIR}/skills/* ]]; then
    echo "agents-local"
  else
    echo "unknown"
  fi
}

# Find all SKILL.md files — uses installed_plugins.json for canonical paths
find_all_skills() {
  # Detect Python — test actual execution (Windows Store stubs exist but fail)
  local py_cmd=""
  for cmd in py python3 python; do
    if command -v "$cmd" &>/dev/null && "$cmd" -c "import sys" &>/dev/null 2>&1; then
      py_cmd="$cmd"
      break
    fi
  done

  if [[ -n "$py_cmd" && -f "$PLUGINS_JSON" ]]; then
    # Smart scan: read installed_plugins.json, pick only canonical subdir per plugin
    "$py_cmd" - "$PLUGINS_JSON" <<'PYEOF' | tr -d '\r'
import json, sys, os

plugins_json = sys.argv[1]
CANONICAL = ["skills", ".agents/skills", ".claude/skills"]

def to_bash_path(p):
    """Convert Windows absolute path to MSYS bash path for output."""
    p = p.replace("\\", "/")
    if len(p) >= 2 and p[1] == ":":
        return "/" + p[0].lower() + p[2:]
    return p

with open(plugins_json, "r", encoding="utf-8") as f:
    data = json.load(f)

printed = set()
for _key, entries in data.get("plugins", {}).items():
    if not isinstance(entries, list):
        entries = [entries]
    for entry in entries:
        # Use raw path for os.path (works on both Windows and Unix)
        raw_path = entry.get("installPath", "")
        if not raw_path or not os.path.exists(raw_path):
            continue
        for subdir in CANONICAL:
            skills_dir = os.path.join(raw_path, subdir)
            if os.path.exists(skills_dir):
                for root, _dirs, files in os.walk(skills_dir):
                    for fname in sorted(files):
                        if fname == "SKILL.md":
                            # Output MSYS-style path so bash can use it
                            full = to_bash_path(os.path.join(root, fname))
                            if full not in printed:
                                print(full)
                                printed.add(full)
                break  # Only first canonical dir per plugin
PYEOF
  else
    # Fallback: broad scan when no Python or no installed_plugins.json
    for base in "${SCAN_PATHS[@]}"; do
      [[ -d "$base" ]] || continue
      find "$base" -name "SKILL.md" -type f 2>/dev/null | sort
    done
  fi

  # Always append local (non-plugin) user skills
  for base in "${CLAUDE_DIR}/skills" "${AGENTS_DIR}/skills"; do
    [[ -d "$base" ]] || continue
    find "$base" -maxdepth 3 -name "SKILL.md" -type f 2>/dev/null | sort
  done
}

# ─── Index file operations ────────────────────────────────────────────────────

# Write the index metadata header
write_header() {
  local total="$1"
  local checksum="$2"
  cat <<EOF
<!-- SKILL_INDEX_META
generated: $(ts)
version: ${VERSION}
total: ${total}
checksum: sha256:${checksum}
-->

# Skill Index

<!-- SKILL_INDEX:START -->
EOF
}

# Write the index footer with audit info
write_footer() {
  cat <<EOF

<!-- SKILL_INDEX:END -->

<!-- SKILL_INDEX_AUDIT
last_build: $(ts)
last_change: $(ts)
integrity: valid
-->
EOF
}

# Format a single skill entry block
skill_entry() {
  local name="$1"
  local source="$2"
  local hash="$3"
  local version="$4"
  local description="$5"
  cat <<EOF
<!-- SKILL:${name}:v${version}:sha256:${hash} -->
- **${name}** [${source}] — ${description}
<!-- /SKILL:${name} -->
EOF
}

# Format a deprecated skill entry block
deprecated_entry() {
  local name="$1"
  local source="$2"
  local date="$3"
  local reason="$4"
  cat <<EOF
<!-- SKILL:${name}:deprecated:${date}:reason:${reason} -->
- ~~**${name}**~~ [deprecated:${date}] — ${reason}
<!-- /SKILL:${name} -->
EOF
}

# Update the SKILL_INDEX_AUDIT block at the end of INDEX.md
update_audit_block() {
  local tmpfile
  tmpfile=$(mktemp)
  # Remove old audit block and append new one
  awk '/<!-- SKILL_INDEX_AUDIT/{found=1} !found{print} /-->/{if(found)found=0}' \
    "${INDEX_FILE}" > "$tmpfile" 2>/dev/null || cp "${INDEX_FILE}" "$tmpfile"
  cat <<EOF >> "$tmpfile"

<!-- SKILL_INDEX_AUDIT
last_build: $(grep 'last_build:' "${INDEX_FILE}" 2>/dev/null | head -1 | awk '{print $2}' || ts)
last_change: $(ts)
integrity: valid
-->
EOF
  mv "$tmpfile" "${INDEX_FILE}"
}

# ─── Command: build ───────────────────────────────────────────────────────────

cmd_build() {
  ensure_dirs
  local start_sec=$SECONDS
  echo "Building skill index..."

  local tmpfile
  tmpfile=$(mktemp)

  # Collect all skill data first
  declare -A skill_names=()
  declare -a ordered_skills=()
  declare -A skill_sources=()
  declare -A skill_hashes=()
  declare -A skill_versions=()
  declare -A skill_descs=()
  declare -A skill_groups=()

  local total=0 errors=0

  while IFS= read -r skill_file; do
    local name description source hash version group

    name=$(extract_field "$skill_file" "name")
    description=$(extract_field "$skill_file" "description")

    if [[ -z "$name" ]]; then
      err "E001" "missing 'name' in frontmatter: ${skill_file}"
      ((errors++)) || true
      continue
    fi
    if [[ -z "$description" ]]; then
      err "E001" "missing 'description' in frontmatter: ${skill_file}"
      ((errors++)) || true
      continue
    fi

    # Detect duplicates
    if [[ -n "${skill_names[$name]+x}" ]]; then
      err "E002" "duplicate skill '${name}': ${skill_file} vs ${skill_names[$name]}"
      ((errors++)) || true
      continue
    fi

    hash=$(sha256_file "$skill_file")
    source=$(source_label "$skill_file")
    version=$(echo "$source" | grep -o '@[^@]*$' | tr -d '@' || echo "0.0.0")

    # Group by source plugin (strip version from grouping)
    group=$(echo "$source" | sed 's/@.*//')

    skill_names[$name]="$skill_file"
    skill_sources[$name]="$source"
    skill_hashes[$name]="$hash"
    skill_versions[$name]="$version"
    skill_descs[$name]="$description"
    skill_groups[$name]="$group"
    ordered_skills+=("$name")
    ((total++)) || true
  done < <(find_all_skills)

  # Sort by group then name
  mapfile -t sorted_skills < <(
    for name in "${ordered_skills[@]}"; do
      echo "${skill_groups[$name]}/${name}"
    done | sort | sed 's|.*/||'
  )

  # Write index grouped by source
  {
    # Placeholder header (checksum computed after)
    echo "HEADER_PLACEHOLDER"

    local current_group=""
    for name in "${sorted_skills[@]}"; do
      local g="${skill_groups[$name]}"
      if [[ "$g" != "$current_group" ]]; then
        echo ""
        echo "## ${g}"
        current_group="$g"
      fi
      skill_entry "$name" "${skill_sources[$name]}" "${skill_hashes[$name]}" \
        "${skill_versions[$name]}" "${skill_descs[$name]}"
    done

    write_footer
  } > "$tmpfile"

  # Compute checksum of the content (excluding header)
  local content_hash
  content_hash=$(sha256_file "$tmpfile")

  # Write final file with real header
  {
    write_header "$total" "$content_hash"
    # Skip the placeholder line
    tail -n +2 "$tmpfile"
  } > "${INDEX_FILE}"

  rm -f "$tmpfile"

  # Save plugins hash for update diffing
  if [[ -f "$PLUGINS_JSON" ]]; then
    sha256_file "$PLUGINS_JSON" > "${PLUGINS_HASH_FILE}"
  fi

  local duration=$(( SECONDS - start_sec ))
  audit "BUILD" "full_scan total=${total} errors=${errors} duration=${duration}s"
  echo "Done. Indexed ${total} skills (${errors} errors). See ${INDEX_FILE}"
}

# ─── Command: update ─────────────────────────────────────────────────────────

cmd_update() {
  local quiet=false
  [[ "${1:-}" == "--quiet" ]] && quiet=true

  ensure_dirs

  # Quick diff: if installed_plugins.json hasn't changed, nothing to do
  if [[ -f "${PLUGINS_HASH_FILE}" && -f "${PLUGINS_JSON}" ]]; then
    local current_hash
    current_hash=$(sha256_file "${PLUGINS_JSON}")
    local saved_hash
    saved_hash=$(cat "${PLUGINS_HASH_FILE}" 2>/dev/null || echo "")
    if [[ "$current_hash" == "$saved_hash" && -f "${INDEX_FILE}" ]]; then
      $quiet || echo "No changes detected. Index is up to date."
      audit "UPDATE" "no_changes plugins_hash_unchanged"
      return 0
    fi
  fi

  # If index doesn't exist, do a full build
  if [[ ! -f "${INDEX_FILE}" ]]; then
    $quiet || echo "Index missing — running full build..."
    cmd_build
    return 0
  fi

  $quiet || echo "Changes detected — rebuilding index..."
  cmd_build
}

# ─── Command: add ─────────────────────────────────────────────────────────────

cmd_add() {
  local name="${1:-}"
  local path="${2:-}"

  if [[ -z "$name" || -z "$path" ]]; then
    echo "Usage: build-index.sh add <name> <path-to-SKILL.md>" >&2
    exit 1
  fi
  if [[ ! -f "$path" ]]; then
    err "E005" "SKILL.md not found at: ${path}"
    exit 1
  fi

  ensure_dirs
  [[ -f "${INDEX_FILE}" ]] || cmd_build

  local description hash source version group
  description=$(extract_field "$path" "description")
  if [[ -z "$description" ]]; then
    err "E001" "missing 'description' in: ${path}"
    exit 1
  fi
  hash=$(sha256_file "$path")
  source=$(source_label "$path")
  version=$(echo "$source" | grep -o '@[^@]*$' | tr -d '@' || echo "0.0.0")
  group=$(echo "$source" | sed 's/@.*//')

  # Remove existing entry for this skill if present (idempotent)
  local tmpfile
  tmpfile=$(mktemp)
  awk -v n="$name" '
    /<!-- SKILL:/ && index($0, "<!-- SKILL:" n ":") == 1 { skip=1 }
    !skip { print }
    skip && /<!-- \/SKILL:/ && index($0, "<!-- /SKILL:" n " -->") > 0 { skip=0 }
  ' "${INDEX_FILE}" > "$tmpfile"

  # Insert new entry before <!-- SKILL_INDEX:END -->
  local entry
  entry=$(skill_entry "$name" "$source" "$hash" "$version" "$description")
  awk -v e="$entry" -v g="## $group" '
    /<!-- SKILL_INDEX:END -->/ { print e; print ""; }
    { print }
  ' "$tmpfile" > "${INDEX_FILE}"

  rm -f "$tmpfile"
  update_audit_block
  audit "ADD" "${name} ${source} sha256:${hash}"
  echo "Added: ${name} [${source}]"
}

# ─── Command: remove ─────────────────────────────────────────────────────────

cmd_remove() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: build-index.sh remove <name>" >&2
    exit 1
  fi

  ensure_dirs
  if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "Index not found. Run 'build' first." >&2
    exit 1
  fi

  printf "Remove '%s' from the index? [y/N] " "$name"
  local confirm
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi

  local tmpfile
  tmpfile=$(mktemp)
  local removed=false
  awk -v n="$name" '
    /<!-- SKILL:/ && index($0, "<!-- SKILL:" n ":") == 1 { skip=1; next }
    /<!-- \/SKILL:/ && index($0, "<!-- /SKILL:" n " -->") > 0 { skip=0; next }
    !skip { print }
  ' "${INDEX_FILE}" > "$tmpfile"

  # Check if anything was removed
  if diff -q "${INDEX_FILE}" "$tmpfile" &>/dev/null; then
    echo "Skill '${name}' not found in index." >&2
    rm -f "$tmpfile"
    exit 1
  fi

  mv "$tmpfile" "${INDEX_FILE}"
  update_audit_block
  audit "REMOVE" "${name}"
  echo "Removed: ${name}"
}

# ─── Command: deprecate ───────────────────────────────────────────────────────

cmd_deprecate() {
  local name="${1:-}"
  local reason="${2:-deprecated}"
  if [[ -z "$name" ]]; then
    echo "Usage: build-index.sh deprecate <name> \"<reason>\"" >&2
    exit 1
  fi

  ensure_dirs
  if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "Index not found. Run 'build' first." >&2
    exit 1
  fi

  local date
  date=$(date -u '+%Y-%m-%d')

  # Replace active entry with deprecated entry
  local tmpfile
  tmpfile=$(mktemp)
  local in_block=false found=false
  while IFS= read -r line; do
    if [[ "$line" =~ "<!-- SKILL:${name}:" && ! "$line" =~ "deprecated" ]]; then
      in_block=true
      found=true
      deprecated_entry "$name" "deprecated" "$date" "$reason"
      continue
    fi
    if $in_block && [[ "$line" =~ "<!-- /SKILL:${name}" ]]; then
      in_block=false
      continue
    fi
    $in_block || echo "$line"
  done < "${INDEX_FILE}" > "$tmpfile"

  if ! $found; then
    echo "Skill '${name}' not found in index." >&2
    rm -f "$tmpfile"
    exit 1
  fi

  mv "$tmpfile" "${INDEX_FILE}"
  update_audit_block
  audit "DEPRECATE" "${name} reason=\"${reason}\""
  echo "Deprecated: ${name} — ${reason}"
}

# ─── Command: verify ─────────────────────────────────────────────────────────

cmd_verify() {
  ensure_dirs
  if [[ ! -f "${INDEX_FILE}" ]]; then
    err "E003" "INDEX.md not found"
    exit 1
  fi

  local errors=0 total=0
  local SKILL_REGEX='^<!-- SKILL:([^:]+):[^:]+:sha256:([a-f0-9]+) -->$'

  # Re-read each skill and compare hash
  while IFS= read -r line; do
    if [[ "$line" =~ $SKILL_REGEX ]]; then
      local name="${BASH_REMATCH[1]}"
      local recorded_hash="${BASH_REMATCH[2]}"

      # Find the skill file by scanning
      local found_file
      found_file=$(find_all_skills | xargs grep -lFx "name: ${name}" 2>/dev/null | head -1 || echo "")

      if [[ -z "$found_file" ]]; then
        err "E005" "skill '${name}' no longer found on disk"
        ((errors++)) || true
      else
        local current_hash
        current_hash=$(sha256_file "$found_file")
        if [[ "$current_hash" != "$recorded_hash" ]]; then
          echo "[WARN] '${name}' hash changed (skill updated). Run 'update' to refresh."
        fi
      fi
      ((total++)) || true
    fi
  done < "${INDEX_FILE}"

  if [[ $errors -eq 0 ]]; then
    audit "VERIFY" "integrity=valid total=${total}"
    echo "Integrity: valid (${total} skills checked, 0 errors)"
  else
    audit "VERIFY" "integrity=invalid total=${total} errors=${errors}"
    echo "Integrity: INVALID (${errors} errors out of ${total} skills)" >&2
    exit 1
  fi
}

# ─── Command: query ──────────────────────────────────────────────────────────

cmd_query() {
  local keywords="${1:-}"
  if [[ -z "$keywords" ]]; then
    echo "Usage: build-index.sh query \"<keywords>\"" >&2
    exit 1
  fi
  if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "Index not found. Run 'build' first." >&2
    exit 1
  fi

  echo "Results for: ${keywords}"
  echo "─────────────────────────────"
  grep -i "$keywords" "${INDEX_FILE}" | grep '^- ' || echo "(no matches)"
}

# ─── Command: debug ──────────────────────────────────────────────────────────

cmd_debug() {
  echo "=== Skill Index Debug ==="
  echo "Version:      ${VERSION}"
  echo "CLAUDE_DIR:   ${CLAUDE_DIR}"
  echo "INDEX_FILE:   ${INDEX_FILE}"
  echo "AUDIT_LOG:    ${AUDIT_LOG}"
  echo "PLUGINS_JSON: ${PLUGINS_JSON}"
  echo ""

  echo "=== Scan Paths ==="
  for p in "${SCAN_PATHS[@]}"; do
    if [[ -d "$p" ]]; then
      local count
      count=$(find "$p" -name "SKILL.md" 2>/dev/null | wc -l | tr -d ' ')
      echo "  [OK]   ${p} (${count} skills)"
    else
      echo "  [MISS] ${p}"
    fi
  done
  echo ""

  echo "=== Index Status ==="
  if [[ -f "${INDEX_FILE}" ]]; then
    local lines total_entry
    lines=$(wc -l < "${INDEX_FILE}" | tr -d ' ')
    total_entry=$(grep -c '^- \*\*' "${INDEX_FILE}" 2>/dev/null || echo 0)
    echo "  Exists:  yes (${lines} lines, ${total_entry} entries)"
    echo "  Size:    $(du -h "${INDEX_FILE}" | awk '{print $1}')"
    echo "  Modified: $(stat -c '%y' "${INDEX_FILE}" 2>/dev/null || stat -f '%Sm' "${INDEX_FILE}" 2>/dev/null || echo 'unknown')"
  else
    echo "  Exists:  NO — run 'build' to create"
  fi
  echo ""

  echo "=== Last 5 Audit Entries ==="
  if [[ -f "${AUDIT_LOG}" ]]; then
    tail -5 "${AUDIT_LOG}"
  else
    echo "  (no audit log yet)"
  fi
  echo ""

  echo "=== Errors in Audit Log ==="
  grep "^.*ERROR" "${AUDIT_LOG}" 2>/dev/null | tail -10 || echo "  (no errors)"
}

# ─── Command: install-hooks ──────────────────────────────────────────────────

cmd_install_hooks() {
  local settings_file="${CLAUDE_DIR}/settings.json"
  local hook_cmd="bash ${INDEX_DIR}/scripts/build-index.sh update --quiet"

  ensure_dirs

  # If settings.json doesn't exist, create minimal one
  if [[ ! -f "$settings_file" ]]; then
    cat > "$settings_file" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "command": "${hook_cmd}"
      }
    ]
  }
}
EOF
    echo "Created ${settings_file} with SessionStart hook."
    audit "INSTALL_HOOKS" "created settings.json"
    return 0
  fi

  # Check if hook already present
  if grep -q "build-index.sh" "$settings_file" 2>/dev/null; then
    echo "Hook already present in ${settings_file}."
    return 0
  fi

  # Inject hook using Python — detect consistently with find_all_skills
  local py_cmd=""
  for cmd in py python3 python; do
    if command -v "$cmd" &>/dev/null && "$cmd" -c "import sys" &>/dev/null 2>&1; then
      py_cmd="$cmd"; break
    fi
  done
  if [[ -z "$py_cmd" ]]; then
    echo "[ERROR] Python not found. Add this line manually to SessionStart in ${settings_file}:" >&2
    echo "  ${hook_cmd}" >&2
    exit 1
  fi

  "$py_cmd" - "$settings_file" "$hook_cmd" <<'PYEOF'
import json, sys

settings_file = sys.argv[1]
hook_cmd = sys.argv[2]

with open(settings_file, 'r') as f:
    config = json.load(f)

if 'hooks' not in config:
    config['hooks'] = {}
if 'SessionStart' not in config['hooks']:
    config['hooks']['SessionStart'] = []

config['hooks']['SessionStart'].append({"command": hook_cmd})

with open(settings_file, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print("Hook added to " + settings_file)
PYEOF

  audit "INSTALL_HOOKS" "added SessionStart hook to ${settings_file}"
}

# ─── Main dispatch ────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    build)          cmd_build ;;
    update)         cmd_update "$@" ;;
    add)            cmd_add "$@" ;;
    remove)         cmd_remove "$@" ;;
    deprecate)      cmd_deprecate "$@" ;;
    verify)         cmd_verify ;;
    query)          cmd_query "$@" ;;
    debug)          cmd_debug ;;
    install-hooks)  cmd_install_hooks ;;
    help|--help|-h)
      echo "Usage: build-index.sh <command> [args]"
      echo ""
      echo "Commands:"
      echo "  build                         Full scan and rebuild"
      echo "  update [--quiet]              Diff-based update (used by hook)"
      echo "  add <name> <path>             Register specific skill"
      echo "  remove <name>                 Remove skill from index"
      echo "  deprecate <name> \"<reason>\"   Mark skill as deprecated"
      echo "  verify                        Validate checksums and integrity"
      echo "  query \"<keywords>\"            Search index (debug)"
      echo "  debug                         Full diagnostic output"
      echo "  install-hooks                 Add SessionStart hook to settings.json"
      ;;
    *)
      echo "Unknown command: ${cmd}. Run 'build-index.sh help' for usage." >&2
      exit 1
      ;;
  esac
}

main "$@"
