<#
.SYNOPSIS
  Install Claude Board: copy it into place, add a `cb` command, make shortcuts.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Startup          # also launch it at login
  .\install.ps1 -Dest D:\tools\cb
#>
[CmdletBinding()]
param(
    [string]$Dest = (Join-Path $env:USERPROFILE 'claude-board'),
    [string]$BinDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [switch]$Startup
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
    throw 'PowerShell 7 (pwsh.exe) is required. Install it, then run this again.'
}
if (-not (Test-Path (Join-Path $env:USERPROFILE '.claude\projects'))) {
    Write-Warning 'No Claude Code session store found at ~\.claude\projects - the board will be empty until you run Claude Code.'
}

New-Item -ItemType Directory -Force -Path $Dest, $BinDir | Out-Null
foreach ($f in 'ClaudeBoard.ps1', 'ClaudeBoard.vbs') {
    Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $Dest $f) -Force
}
Write-Host "installed to $Dest" -ForegroundColor Green

# `cb` launches detached so the terminal you typed it in stays usable.
$cmd = @"
@echo off
rem Claude Board - session sidebar
if /i "%~1"=="-diagnose" (
    pwsh.exe -sta -NoProfile -File "$Dest\ClaudeBoard.ps1" -Diagnose
    goto :eof
)
start "" wscript.exe "$Dest\ClaudeBoard.vbs"
"@
Set-Content -LiteralPath (Join-Path $BinDir 'cb.cmd') -Value $cmd -Encoding ASCII
Write-Host "created $BinDir\cb.cmd" -ForegroundColor Green

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$BinDir", 'User')
    Write-Host "added $BinDir to your PATH - open a new terminal for `cb` to work" -ForegroundColor Yellow
}

$ws = New-Object -ComObject WScript.Shell
$links = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Board.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Board.lnk')
)
if ($Startup) { $links += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Claude Board.lnk') }

foreach ($l in $links) {
    $sc = $ws.CreateShortcut($l)
    $sc.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $sc.Arguments = """$Dest\ClaudeBoard.vbs"""
    $sc.WorkingDirectory = $Dest
    $sc.Description = 'Sidebar listing every Claude Code session'
    $claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $claude) { $sc.IconLocation = "$claude,0" }
    $sc.Save()
    Write-Host "shortcut: $l" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. Run  cb  (or use the Desktop shortcut).' -ForegroundColor Cyan
