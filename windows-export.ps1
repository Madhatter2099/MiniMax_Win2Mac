#requires -Version 5.1
<#
.SYNOPSIS
  Export MiniMax Code (MCode) local runtime data from Windows, ready for migration to macOS.

.DESCRIPTION
  Packages the Windows MCode data directory (~%USERPROFILE%\.minimax by default) into a zip
  that the macOS side (mac-import.sh) can import.

  What is packaged  : config.yaml, mcp.json, agents/ (custom agents + agent memory), memory/,
                      skills/, plugins/, channels, v2/sessions/, v2/sqlite/runtime-state.sqlite,
                      background-tasks/, integrations/
  What is NOT packed: auth/ (device bound - re-login on the new machine), .builtin-skills/,
                      bin/, shims/, run/, cache/, v2/plugin-cache/ (platform binaries),
                      v2/plugin-hook-cache/, v2/runtime-owner-leases/, v2/session-handoff/,
                      v2/migration/, v2/observability/, v2/workspaces/, *.log
                      (all of the above are regenerated per device by the app)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\windows-export.ps1
  powershell -ExecutionPolicy Bypass -File .\windows-export.ps1 -DataDir 'D:\mcode-data'
#>
[CmdletBinding()]
param(
    # MCode data directory. Defaults to $env:MINIMAX_DATA_DIR, then %USERPROFILE%\.minimax
    [string]$DataDir,
    # Where the exported zip is written
    [string]$OutDir,
    # Do not prompt for a zip target directory
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Write-Ok($m)   { Write-Host "OK  $m" -ForegroundColor Green }

# ---------------------------------------------------------------- resolve data dir
if (-not $DataDir) {
    if ($env:MINIMAX_DATA_DIR) { $DataDir = $env:MINIMAX_DATA_DIR }
    else { $DataDir = Join-Path $env:USERPROFILE '.minimax' }
}
if (-not (Test-Path -LiteralPath $DataDir)) {
    throw "MCode data directory not found: $DataDir"
}
if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'Desktop' }
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

Write-Info "MCode data dir : $DataDir"

# ---------------------------------------------------------------- make sure the app is closed
function Get-MCodeProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -like '*MiniMax*' -or
            $_.ProcessName -like 'mcode*' -or
            $_.ProcessName -like '*Mavis*'
        }
}

$running = Get-MCodeProcesses
if ($running) {
    Write-Warn "MCode seems to be running: $($running.ProcessName -join ', ')"
    if (-not $Force) {
        Write-Host "    Quit MCode completely (menu bar -> Quit, task tray -> exit), then press Enter."
        [void](Read-Host)
    }
    Start-Sleep -Seconds 2
    $running = Get-MCodeProcesses
    if ($running) {
        throw "MCode is still running ($($running.ProcessName -join ', ')). Close it and re-run this script."
    }
}
Write-Ok "MCode is not running."

# ---------------------------------------------------------------- checkpoint the sqlite WAL
$db = Join-Path $DataDir 'v2\sqlite\runtime-state.sqlite'
$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if ($sqlite -and (Test-Path -LiteralPath $db)) {
    & sqlite3 $db 'PRAGMA wal_checkpoint(TRUNCATE);' | Out-Null
    Write-Ok "SQLite WAL checkpointed."
} elseif (Test-Path -LiteralPath $db) {
    Write-Warn "sqlite3 not found in PATH. The -wal/-shm files will be copied as-is; SQLite recovers them automatically on first open."
}

# ---------------------------------------------------------------- stage the copy
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$stageRoot = Join-Path $env:TEMP "mcode-migration-$stamp"
$payload   = Join-Path $stageRoot 'mcode-migration-export'
New-Item -ItemType Directory -Force -Path $payload | Out-Null

# machine specific / regenerable -> excluded from the export
$excludedDirs = @(
    'auth', '.builtin-skills', 'bin', 'shims', 'run', 'cache',
    'plugin-cache', 'plugin-hook-cache', 'runtime-owner-leases',
    'session-handoff', 'migration', 'observability', 'workspaces', '.builtin'
)
$excludedFiles = @('*.log', '*.log.*', '*.sqlite-shm', '*.db-wal', '*.db-shm')

Write-Info "Staging payload to $payload"
& robocopy $DataDir $payload /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD $excludedDirs /XF $excludedFiles
$rc = $LASTEXITCODE
if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
Write-Ok "Files staged."

# ---------------------------------------------------------------- inventory
$top = Get-ChildItem -LiteralPath $payload -Force | Select-Object -ExpandProperty Name
Write-Host ""
Write-Info "Payload top level:"
foreach ($t in $top) { Write-Host "      $t" }

$windowsPaths = @()
if ($sqlite -and (Test-Path -LiteralPath $db)) {
    $q = @'
select distinct workspace_dir from local_runtime_projects where workspace_dir is not null
union
select distinct project_workspace_dir from local_runtime_sessions where project_workspace_dir is not null
union
select distinct workspace_dir from local_runtime_sessions where workspace_dir is not null;
'@
    $windowsPaths = (& sqlite3 $db $q) | Where-Object { $_ } | Sort-Object -Unique
}

# ---------------------------------------------------------------- manifest
function Get-MCodeVersion {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\MiniMax Code\MiniMax Code.exe'),
        (Join-Path $env:LOCALAPPDATA 'MiniMax Code\MiniMax Code.exe'),
        (Join-Path $env:ProgramFiles 'MiniMax Code\MiniMax Code.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            try {
                $v = (Get-Item -LiteralPath $c).VersionInfo.ProductVersion
                if ($v) { return $v }
            } catch { }
        }
    }
    return $null
}

$files = Get-ChildItem -LiteralPath $payload -Recurse -File -Force |
    ForEach-Object { $_.FullName.Substring($payload.Length + 1) }

$manifest = [ordered]@{
    exportedAt         = (Get-Date).ToString('o')
    windowsDataDir      = $DataDir
    windowsUserProfile  = $env:USERPROFILE
    mcodeAppVersion     = (Get-MCodeVersion)
    topLevelEntries     = @($top)
    windowsPaths        = @($windowsPaths)
    fileCount           = $files.Count
    totalBytes          = (Get-ChildItem -LiteralPath $payload -Recurse -File -Force |
                           Measure-Object -Property Length -Sum).Sum
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $payload 'export-manifest.json') -Encoding UTF8

# ---------------------------------------------------------------- zip
$zip = Join-Path $OutDir "mcode-migration-windows-$stamp.zip"
Write-Info "Compressing to $zip ..."
Compress-Archive -Path $payload -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Ok "Export finished."
Write-Host ""
Write-Host "  zip      : $zip"
Write-Host ("  size     : {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))
Write-Host "  files    : $($files.Count)"
Write-Host "  windows workspace paths detected:"
if ($windowsPaths) { foreach ($p in $windowsPaths) { Write-Host "      $p" } }
else { Write-Host "      (none found)" }
Write-Host ""
Write-Host "Next: copy that zip to the Mac, then run  ./mac-import.sh --zip <zip>"
Write-Host "See README.md for the full checklist and the things that are deliberately NOT migrated."
