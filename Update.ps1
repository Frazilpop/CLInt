# Update.ps1 - fetch the latest CLInt from GitHub.
# Works two ways: a git clone updates via git (private repos included, if
# git has credentials); a plain download compares version.txt on GitHub
# and pulls the branch ZIP - no git or account needed on a public repo.
# User data (settings.json, tdp-settings.json, menu-key.txt, recent.json)
# is never in the download, so it survives updates untouched.
#
# -CheckOnly: compare versions without changing anything; leaves
# update-available.txt (read by the app's SETTINGS row) when the remote
# is newer, and removes it when up to date.
#
# Exit codes: 0 = updated / update available, 3 = already current, 1 = failed.

param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = 'Frazilpop/CLInt'
$marker = Join-Path $here 'update-available.txt'

function Get-LocalVersion {
    try { (Get-Content (Join-Path $here 'version.txt') -TotalCount 1).Trim() } catch { '0.0.0' }
}
$localVer = Get-LocalVersion

# --- Git clone: let git do the work -----------------------------------
$git = Get-Command git -ErrorAction SilentlyContinue
if ((Test-Path (Join-Path $here '.git')) -and $git) {
    & git -C $here fetch --quiet 2>$null
    if ($LASTEXITCODE) {
        Write-Host "  Could not reach GitHub (offline?)." -ForegroundColor Yellow
        exit 1
    }
    $local  = (& git -C $here rev-parse HEAD).Trim()
    $remote = (& git -C $here rev-parse '@{u}').Trim()
    if ($local -eq $remote) {
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
        Write-Host "  v$localVer - already the latest." -ForegroundColor Green
        exit 3
    }
    if ($CheckOnly) {
        $rv = ''
        try { $rv = ([string](& git -C $here show 'origin/main:version.txt' 2>$null | Select-Object -First 1)).Trim() } catch {}
        Set-Content $marker $(if ($rv) { $rv } else { 'new' }) -Encoding Ascii
        exit 0
    }
    & git -C $here pull --ff-only --quiet 2>$null
    if ($LASTEXITCODE) {
        Write-Host "  Update failed - local changes in the way? Run 'git pull' by hand." -ForegroundColor Yellow
        exit 1
    }
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Write-Host "  Updated: v$localVer -> v$(Get-LocalVersion)" -ForegroundColor Green
    exit 0
}

# --- Plain download: compare versions, fetch the branch ZIP -----------
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    $remoteVer = (Invoke-WebRequest "https://raw.githubusercontent.com/$repo/main/version.txt" `
        -UseBasicParsing -Headers @{ 'User-Agent' = 'CLInt-updater' }).Content.Trim()
} catch {
    Write-Host "  Could not check GitHub (offline, or the repo isn't public)." -ForegroundColor Yellow
    exit 1
}
if ($remoteVer -eq $localVer) {
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Write-Host "  v$localVer - already the latest." -ForegroundColor Green
    exit 3
}
if ($CheckOnly) {
    Set-Content $marker $remoteVer -Encoding Ascii
    exit 0
}

Write-Host "  v$localVer -> v$remoteVer - downloading..."
$tmp = Join-Path $env:TEMP "CLInt-update-$PID"
$zip = "$tmp.zip"
try {
    Invoke-WebRequest "https://codeload.github.com/$repo/zip/refs/heads/main" `
        -UseBasicParsing -Headers @{ 'User-Agent' = 'CLInt-updater' } -OutFile $zip
    Expand-Archive $zip $tmp -Force
    # The ZIP root folder is <reponame>-main; copy its contents over ours.
    $root = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Copy-Item (Join-Path $root.FullName '*') $here -Recurse -Force
    # A ZIP overlay only adds files; sweep ones old versions shipped under
    # names that have since been renamed away.
    foreach ($legacy in @('SteamMenu.ps1', 'SteamMenuKey.ahk', 'Backdrop.ps1')) {
        Remove-Item (Join-Path $here $legacy) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Write-Host "  Updated: v$localVer -> v$remoteVer" -ForegroundColor Green
    exit 0
} catch {
    Write-Host "  Update failed: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 1
} finally {
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
