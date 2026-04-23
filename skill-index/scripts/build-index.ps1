# build-index.ps1 — Skill Index manager (Windows PowerShell)
# Usage: .\build-index.ps1 <command> [args]
# Commands: build | update [-Quiet] | add <name> <path> | remove <name>
#           deprecate <name> <reason> | verify | query <keywords> | debug | install-hooks
# Version: 1.0.0
# Requires: Windows PowerShell 5.1+ or PowerShell 7+

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(Position=1, ValueFromRemainingArguments=$true)]
    [string[]]$Args = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Configuration ────────────────────────────────────────────────────────────

$ClaudeDir    = "$env:USERPROFILE\.claude"
$AgentsDir    = "$env:USERPROFILE\.agents"
$IndexDir     = "$ClaudeDir\skills\skill-index"
$IndexFile    = "$IndexDir\INDEX.md"
$AuditLog     = "$IndexDir\audit.log"
$PluginsJson  = "$ClaudeDir\plugins\installed_plugins.json"
$PluginsHash  = "$IndexDir\.plugins_hash"
$Version      = "1.0.0"

$ScanPaths = @(
    "$ClaudeDir\plugins\cache",
    "$ClaudeDir\skills",
    "$AgentsDir\skills"
)

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Get-Timestamp {
    (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-FileHash256 {
    param([string]$Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-StringHash256 {
    param([string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)
    ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Write-Audit {
    param([string]$Level, [string]$Message)
    $entry = "{0} {1,-10} {2}" -f (Get-Timestamp), $Level, $Message
    Add-Content -Path $AuditLog -Value $entry -Encoding UTF8
}

function Write-Error-Code {
    param([string]$Code, [string]$Message)
    Write-Audit "ERROR" "$Code $Message"
    Write-Host "[$Code] $Message" -ForegroundColor Red
}

function Ensure-Dirs {
    New-Item -ItemType Directory -Force -Path $IndexDir | Out-Null
    if (-not (Test-Path $AuditLog)) { New-Item -ItemType File -Path $AuditLog | Out-Null }
}

function Extract-FrontmatterField {
    param([string]$FilePath, [string]$Field)
    $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
    $inFrontmatter = 0
    foreach ($line in $content -split "`n") {
        $line = $line.TrimEnd("`r")
        if ($line -eq "---") {
            $inFrontmatter++
            if ($inFrontmatter -ge 2) { break }
            continue
        }
        if ($inFrontmatter -eq 1 -and $line -match "^${Field}:\s*(.+)$") {
            return $Matches[1].Trim().Trim('"')
        }
    }
    return ""
}

function Get-SourceLabel {
    param([string]$Path)
    $cachePrefix = "$ClaudeDir\plugins\cache\"
    if ($Path.StartsWith($cachePrefix)) {
        $rel = $Path.Substring($cachePrefix.Length)
        $parts = $rel -split '\\'
        if ($parts.Count -ge 3) {
            return "$($parts[1])@$($parts[2])"
        }
    }
    if ($Path.StartsWith("$ClaudeDir\skills\")) { return "local" }
    if ($Path.StartsWith("$AgentsDir\skills\")) { return "agents-local" }
    return "unknown"
}

function Find-AllSkills {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($base in $ScanPaths) {
        if (Test-Path $base) {
            Get-ChildItem -Recurse -Filter "SKILL.md" -Path $base -ErrorAction SilentlyContinue |
                ForEach-Object { $found.Add($_.FullName) }
        }
    }
    return ($found | Sort-Object)
}

function New-SkillEntry {
    param([string]$Name, [string]$Source, [string]$Hash, [string]$SkillVersion, [string]$Description)
    return @"
<!-- SKILL:${Name}:v${SkillVersion}:sha256:${Hash} -->
- **${Name}** [${Source}] — ${Description}
<!-- /SKILL:${Name} -->
"@
}

function New-DeprecatedEntry {
    param([string]$Name, [string]$Date, [string]$Reason)
    return @"
<!-- SKILL:${Name}:deprecated:${Date}:reason:${Reason} -->
- ~~**${Name}**~~ [deprecated:${Date}] — ${Reason}
<!-- /SKILL:${Name} -->
"@
}

function Update-AuditBlock {
    if (-not (Test-Path $IndexFile)) { return }
    $content = Get-Content -Path $IndexFile -Raw -Encoding UTF8
    # Remove existing audit block
    $content = $content -replace "(?s)\n<!-- SKILL_INDEX_AUDIT.*?-->", ""
    $lastBuild = if ($content -match "last_build:\s*(\S+)") { $Matches[1] } else { Get-Timestamp }
    $auditBlock = @"

<!-- SKILL_INDEX_AUDIT
last_build: $lastBuild
last_change: $(Get-Timestamp)
integrity: valid
-->
"@
    $content + $auditBlock | Set-Content -Path $IndexFile -Encoding UTF8 -NoNewline
}

# ─── Command: build ───────────────────────────────────────────────────────────

function Invoke-Build {
    Ensure-Dirs
    Write-Host "Building skill index..."

    $skillData = [ordered]@{}
    $total = 0; $errors = 0

    foreach ($skillFile in Find-AllSkills) {
        $name = Extract-FrontmatterField -FilePath $skillFile -Field "name"
        $desc = Extract-FrontmatterField -FilePath $skillFile -Field "description"

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Error-Code "E001" "missing 'name' in frontmatter: $skillFile"
            $errors++; continue
        }
        if ([string]::IsNullOrWhiteSpace($desc)) {
            Write-Error-Code "E001" "missing 'description' in frontmatter: $skillFile"
            $errors++; continue
        }
        if ($skillData.Contains($name)) {
            Write-Error-Code "E002" "duplicate skill '$name': $skillFile vs $($skillData[$name].Path)"
            $errors++; continue
        }

        $hash = Get-FileHash256 -Path $skillFile
        $source = Get-SourceLabel -Path $skillFile
        $ver = if ($source -match "@(.+)$") { $Matches[1] } else { "0.0.0" }
        $group = $source -replace "@.*", ""

        $skillData[$name] = @{
            Path        = $skillFile
            Source      = $source
            Hash        = $hash
            Version     = $ver
            Description = $desc
            Group       = $group
        }
        $total++
    }

    # Sort by group then name
    $sorted = $skillData.Keys | Sort-Object {
        "$($skillData[$_].Group)/$_"
    }

    # Build content
    $sb = [System.Text.StringBuilder]::new()
    $currentGroup = ""
    foreach ($name in $sorted) {
        $s = $skillData[$name]
        if ($s.Group -ne $currentGroup) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("## $($s.Group)")
            $currentGroup = $s.Group
        }
        [void]$sb.AppendLine((New-SkillEntry $name $s.Source $s.Hash $s.Version $s.Description))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("<!-- SKILL_INDEX:END -->")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("<!-- SKILL_INDEX_AUDIT")
    [void]$sb.AppendLine("last_build: $(Get-Timestamp)")
    [void]$sb.AppendLine("last_change: $(Get-Timestamp)")
    [void]$sb.AppendLine("integrity: valid")
    [void]$sb.AppendLine("-->")

    $bodyContent = $sb.ToString()
    $contentHash = Get-StringHash256 -Value $bodyContent

    $header = @"
<!-- SKILL_INDEX_META
generated: $(Get-Timestamp)
version: $Version
total: $total
checksum: sha256:$contentHash
-->

# Skill Index

<!-- SKILL_INDEX:START -->
"@

    ($header + $bodyContent) | Set-Content -Path $IndexFile -Encoding UTF8

    # Save plugins hash for future diffs
    if (Test-Path $PluginsJson) {
        Get-FileHash256 -Path $PluginsJson | Set-Content -Path $PluginsHash -Encoding UTF8
    }

    Write-Audit "BUILD" "full_scan total=$total errors=$errors"
    Write-Host "Done. Indexed $total skills ($errors errors). See $IndexFile"
}

# ─── Command: update ─────────────────────────────────────────────────────────

function Invoke-Update {
    param([switch]$Quiet)
    Ensure-Dirs

    if ((Test-Path $PluginsHash) -and (Test-Path $PluginsJson) -and (Test-Path $IndexFile)) {
        $currentHash = Get-FileHash256 -Path $PluginsJson
        $savedHash   = (Get-Content -Path $PluginsHash -Raw -Encoding UTF8).Trim()
        if ($currentHash -eq $savedHash) {
            if (-not $Quiet) { Write-Host "No changes detected. Index is up to date." }
            Write-Audit "UPDATE" "no_changes plugins_hash_unchanged"
            return
        }
    }

    if (-not (Test-Path $IndexFile)) {
        if (-not $Quiet) { Write-Host "Index missing — running full build..." }
        Invoke-Build; return
    }

    if (-not $Quiet) { Write-Host "Changes detected — rebuilding index..." }
    Invoke-Build
}

# ─── Command: add ─────────────────────────────────────────────────────────────

function Invoke-Add {
    param([string]$Name, [string]$Path)
    if (-not $Name -or -not $Path) {
        Write-Host "Usage: build-index.ps1 add <name> <path-to-SKILL.md>"; return
    }
    if (-not (Test-Path $Path)) {
        Write-Error-Code "E005" "SKILL.md not found at: $Path"; return
    }

    Ensure-Dirs
    if (-not (Test-Path $IndexFile)) { Invoke-Build }

    $desc    = Extract-FrontmatterField -FilePath $Path -Field "description"
    if (-not $desc) { Write-Error-Code "E001" "missing 'description' in: $Path"; return }
    $hash    = Get-FileHash256 -Path $Path
    $source  = Get-SourceLabel -Path $Path
    $ver     = if ($source -match "@(.+)$") { $Matches[1] } else { "0.0.0" }
    $entry   = New-SkillEntry $Name $source $hash $ver $desc

    # Remove existing entry (idempotent), then insert before END marker
    $content = Get-Content -Path $IndexFile -Raw -Encoding UTF8
    $escapedName = [regex]::Escape($Name)
    $content = $content -replace "(?s)<!-- SKILL:${escapedName}:.*?<!-- /SKILL:${escapedName} -->(\r?\n)?", ""
    $content = $content -replace "(<!-- SKILL_INDEX:END -->)", "$entry`n`$1"
    $content | Set-Content -Path $IndexFile -Encoding UTF8 -NoNewline

    Update-AuditBlock
    Write-Audit "ADD" "$Name $source sha256:$hash"
    Write-Host "Added: $Name [$source]"
}

# ─── Command: remove ─────────────────────────────────────────────────────────

function Invoke-Remove {
    param([string]$Name)
    if (-not $Name) { Write-Host "Usage: build-index.ps1 remove <name>"; return }
    if (-not (Test-Path $IndexFile)) { Write-Host "Index not found. Run 'build' first."; return }

    $confirm = Read-Host "Remove '$Name' from the index? [y/N]"
    if ($confirm -notmatch '^[yY]$') { Write-Host "Aborted."; return }

    $content = Get-Content -Path $IndexFile -Raw -Encoding UTF8
    $escapedName = [regex]::Escape($Name)
    $newContent = $content -replace "(?s)<!-- SKILL:${escapedName}:.*?<!-- /SKILL:${escapedName} -->(\r?\n)?", ""

    if ($newContent -eq $content) {
        Write-Host "Skill '$Name' not found in index."
        return
    }

    $newContent | Set-Content -Path $IndexFile -Encoding UTF8 -NoNewline
    Update-AuditBlock
    Write-Audit "REMOVE" $Name
    Write-Host "Removed: $Name"
}

# ─── Command: deprecate ───────────────────────────────────────────────────────

function Invoke-Deprecate {
    param([string]$Name, [string]$Reason = "deprecated")
    if (-not $Name) { Write-Host "Usage: build-index.ps1 deprecate <name> <reason>"; return }
    if (-not (Test-Path $IndexFile)) { Write-Host "Index not found. Run 'build' first."; return }

    $date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    $entry = New-DeprecatedEntry $Name $date $Reason

    $content = Get-Content -Path $IndexFile -Raw -Encoding UTF8
    $escapedName = [regex]::Escape($Name)
    # Replace active entry (not already deprecated)
    $newContent = $content -replace "(?s)<!-- SKILL:${escapedName}:v[^:]+:.*?<!-- /SKILL:${escapedName} -->", $entry.TrimEnd()

    if ($newContent -eq $content) {
        Write-Host "Skill '$Name' not found or already deprecated."
        return
    }

    $newContent | Set-Content -Path $IndexFile -Encoding UTF8 -NoNewline
    Update-AuditBlock
    Write-Audit "DEPRECATE" "$Name reason=`"$Reason`""
    Write-Host "Deprecated: $Name — $Reason"
}

# ─── Command: verify ─────────────────────────────────────────────────────────

function Invoke-Verify {
    Ensure-Dirs
    if (-not (Test-Path $IndexFile)) {
        Write-Error-Code "E003" "INDEX.md not found"
        return
    }

    $errors = 0; $total = 0
    $content = Get-Content -Path $IndexFile -Encoding UTF8

    foreach ($line in $content) {
        if ($line -match "^<!-- SKILL:([^:]+):[^:]+:sha256:([a-f0-9]+) -->$") {
            $name = $Matches[1]
            $recordedHash = $Matches[2]
            $total++

            # Find skill on disk
            $foundFile = Find-AllSkills | Where-Object {
                $n = Extract-FrontmatterField -FilePath $_ -Field "name"
                $n -eq $name
            } | Select-Object -First 1

            if (-not $foundFile) {
                Write-Error-Code "E005" "skill '$name' no longer found on disk"
                $errors++
            } else {
                $currentHash = Get-FileHash256 -Path $foundFile
                if ($currentHash -ne $recordedHash) {
                    Write-Host "[WARN] '$name' hash changed (skill updated). Run 'update' to refresh." -ForegroundColor Yellow
                }
            }
        }
    }

    if ($errors -eq 0) {
        Write-Audit "VERIFY" "integrity=valid total=$total"
        Write-Host "Integrity: valid ($total skills checked, 0 errors)" -ForegroundColor Green
    } else {
        Write-Audit "VERIFY" "integrity=invalid total=$total errors=$errors"
        Write-Host "Integrity: INVALID ($errors errors out of $total skills)" -ForegroundColor Red
    }
}

# ─── Command: query ──────────────────────────────────────────────────────────

function Invoke-Query {
    param([string]$Keywords)
    if (-not $Keywords) { Write-Host "Usage: build-index.ps1 query <keywords>"; return }
    if (-not (Test-Path $IndexFile)) { Write-Host "Index not found. Run 'build' first."; return }

    Write-Host "Results for: $Keywords"
    Write-Host "─────────────────────────────"
    $matches = Get-Content -Path $IndexFile -Encoding UTF8 |
        Where-Object { $_ -match "^- " -and $_ -imatch [regex]::Escape($Keywords) }
    if ($matches) { $matches } else { Write-Host "(no matches)" }
}

# ─── Command: debug ──────────────────────────────────────────────────────────

function Invoke-Debug {
    Write-Host "=== Skill Index Debug ==="
    Write-Host "Version:      $Version"
    Write-Host "ClaudeDir:    $ClaudeDir"
    Write-Host "IndexFile:    $IndexFile"
    Write-Host "AuditLog:     $AuditLog"
    Write-Host "PluginsJson:  $PluginsJson"
    Write-Host ""

    Write-Host "=== Scan Paths ==="
    foreach ($p in $ScanPaths) {
        if (Test-Path $p) {
            $count = (Get-ChildItem -Recurse -Filter "SKILL.md" -Path $p -ErrorAction SilentlyContinue).Count
            Write-Host "  [OK]   $p ($count skills)" -ForegroundColor Green
        } else {
            Write-Host "  [MISS] $p" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    Write-Host "=== Index Status ==="
    if (Test-Path $IndexFile) {
        $lines = (Get-Content -Path $IndexFile).Count
        $entries = (Select-String -Path $IndexFile -Pattern "^- \*\*").Count
        $size = (Get-Item $IndexFile).Length
        Write-Host "  Exists:   yes ($lines lines, $entries entries, $size bytes)" -ForegroundColor Green
        Write-Host "  Modified: $((Get-Item $IndexFile).LastWriteTime)"
    } else {
        Write-Host "  Exists:   NO — run 'build' to create" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host "=== Last 5 Audit Entries ==="
    if (Test-Path $AuditLog) {
        Get-Content -Path $AuditLog -Tail 5 | Write-Host
    } else {
        Write-Host "  (no audit log yet)"
    }
    Write-Host ""

    Write-Host "=== Errors in Audit Log ==="
    if (Test-Path $AuditLog) {
        $errs = Select-String -Path $AuditLog -Pattern "ERROR" | Select-Object -Last 10
        if ($errs) { $errs | ForEach-Object { Write-Host $_.Line -ForegroundColor Red } }
        else { Write-Host "  (no errors)" -ForegroundColor Green }
    } else {
        Write-Host "  (no audit log yet)"
    }
}

# ─── Command: install-hooks ──────────────────────────────────────────────────

function Invoke-InstallHooks {
    $settingsFile = "$ClaudeDir\settings.json"
    $hookCmd = "powershell -ExecutionPolicy Bypass -File `"$IndexDir\scripts\build-index.ps1`" update -Quiet"

    Ensure-Dirs

    if (-not (Test-Path $settingsFile)) {
        $config = @{
            hooks = @{
                SessionStart = @(@{ command = $hookCmd })
            }
        }
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsFile -Encoding UTF8
        Write-Host "Created $settingsFile with SessionStart hook."
        Write-Audit "INSTALL_HOOKS" "created settings.json"
        return
    }

    $content = Get-Content -Path $settingsFile -Raw -Encoding UTF8
    if ($content -match "build-index") {
        Write-Host "Hook already present in $settingsFile."
        return
    }

    try {
        $config = $content | ConvertFrom-Json
        # ConvertFrom-Json returns PSCustomObject — convert to hashtable for editing
        $configHash = @{}
        $config.PSObject.Properties | ForEach-Object { $configHash[$_.Name] = $_.Value }

        if (-not $configHash.ContainsKey("hooks")) { $configHash["hooks"] = @{} }
        $hooks = $configHash["hooks"]
        $hooksHash = @{}
        if ($hooks -is [PSCustomObject]) {
            $hooks.PSObject.Properties | ForEach-Object { $hooksHash[$_.Name] = @($_.Value) }
        } else {
            $hooksHash = $hooks
        }
        if (-not $hooksHash.ContainsKey("SessionStart")) { $hooksHash["SessionStart"] = @() }
        $hooksHash["SessionStart"] += @{ command = $hookCmd }
        $configHash["hooks"] = $hooksHash

        $configHash | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsFile -Encoding UTF8
        Write-Host "Hook added to $settingsFile."
        Write-Audit "INSTALL_HOOKS" "added SessionStart hook to $settingsFile"
    } catch {
        Write-Host "Could not parse $settingsFile. Add manually:" -ForegroundColor Yellow
        Write-Host "  hooks.SessionStart: [{command: `"$hookCmd`"}]"
    }
}

# ─── Main dispatch ────────────────────────────────────────────────────────────

switch ($Command.ToLower()) {
    "build"         { Invoke-Build }
    "update"        { Invoke-Update -Quiet:($Args -contains "-Quiet" -or $Args -contains "--quiet") }
    "add"           { Invoke-Add -Name ($Args[0] ?? "") -Path ($Args[1] ?? "") }
    "remove"        { Invoke-Remove -Name ($Args[0] ?? "") }
    "deprecate"     { Invoke-Deprecate -Name ($Args[0] ?? "") -Reason ($Args[1] ?? "deprecated") }
    "verify"        { Invoke-Verify }
    "query"         { Invoke-Query -Keywords ($Args[0] ?? "") }
    "debug"         { Invoke-Debug }
    "install-hooks" { Invoke-InstallHooks }
    default {
        Write-Host "Usage: build-index.ps1 <command> [args]"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  build                          Full scan and rebuild"
        Write-Host "  update [-Quiet]                Diff-based update (used by hook)"
        Write-Host "  add <name> <path>              Register specific skill"
        Write-Host "  remove <name>                  Remove skill from index"
        Write-Host "  deprecate <name> <reason>      Mark skill as deprecated"
        Write-Host "  verify                         Validate checksums and integrity"
        Write-Host "  query <keywords>               Search index (debug)"
        Write-Host "  debug                          Full diagnostic output"
        Write-Host "  install-hooks                  Add SessionStart hook to settings.json"
    }
}
