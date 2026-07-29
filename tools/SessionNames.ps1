<#
  Persistent session names for Claude Code.

  /rename writes the name into %USERPROFILE%\.claude\sessions\<pid>.json - a file
  keyed by process id that Claude Code deletes when the process exits. Nothing about
  the name ever reaches the transcript, so a closed terminal loses it and --resume
  comes back with a fresh derived name like "simon-1f".

  This keeps a copy keyed by SESSION id instead, so a name survives a close, a
  reboot and a resume. Dot-source it, or run it with -Sync to harvest once.

    . tools\SessionNames.ps1
    Sync-SessionNames                      # copy live /rename names into the store
    Get-SessionName  <session-id>
    Set-SessionName  <session-id> 'name'   # '' clears it
#>
[CmdletBinding()]
param([switch]$Sync, [switch]$List)

$script:NameStorePath = Join-Path $env:USERPROFILE '.claude\session-names.json'
$script:LiveDirPath   = Join-Path $env:USERPROFILE '.claude\sessions'

function Get-ClaudeLiveSessions {
    <# The <pid>.json files Claude Code keeps for every running session. #>
    if (-not (Test-Path -LiteralPath $script:LiveDirPath)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-ChildItem -LiteralPath $script:LiveDirPath -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $o = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if (-not $o.sessionId) { continue }
        $src = if ($o.PSObject.Properties['nameSource']) { [string]$o.nameSource } else { '' }
        $out.Add([pscustomobject]@{
            Pid        = [int]$o.pid
            Id         = [string]$o.sessionId
            Cwd        = [string]$o.cwd
            Name       = [string]$o.name
            NameSource = $src
            # Auto-generated names carry nameSource="derived"; /rename leaves it unset.
            UserNamed  = [bool]($o.name -and $src -ne 'derived')
            Status     = [string]$o.status
        })
    }
    $out.ToArray()
}

function Read-SessionNames {
    $map = @{}
    if (Test-Path -LiteralPath $script:NameStorePath) {
        try {
            $j = Get-Content -LiteralPath $script:NameStorePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $j.PSObject.Properties) { if ($p.Value) { $map[$p.Name] = [string]$p.Value } }
        } catch { }
    }
    $map
}

function Write-SessionNames {
    param([hashtable]$Map)
    $o = [ordered]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $o[$k] = $Map[$k] }
    $json = ([pscustomobject]$o | ConvertTo-Json -Depth 3)
    # The board, the cs launcher and the sync task can all write; a clash here just
    # means one harvest is late, so retry briefly rather than throw.
    for ($i = 0; $i -lt 4; $i++) {
        try { Set-Content -LiteralPath $script:NameStorePath -Value $json -Encoding UTF8 -ErrorAction Stop; return $true }
        catch { Start-Sleep -Milliseconds 60 }
    }
    $false
}

function Sync-SessionNames {
    <# Copy every /rename name off the live pid files into the store. Returns how
       many it learned or changed. #>
    $live = @(Get-ClaudeLiveSessions | Where-Object { $_.UserNamed })
    if (-not $live.Count) { return 0 }
    $map = Read-SessionNames
    $n = 0
    foreach ($s in $live) {
        if ($map[$s.Id] -ne $s.Name) { $map[$s.Id] = $s.Name; $n++ }
    }
    if ($n) { [void](Write-SessionNames $map) }
    $n
}

function Get-SessionName {
    param([Parameter(Mandatory)][string]$Id)
    # A live /rename beats the store - it is the newer of the two by definition.
    foreach ($s in (Get-ClaudeLiveSessions)) {
        if ($s.Id -eq $Id -and $s.UserNamed) { return $s.Name }
    }
    (Read-SessionNames)[$Id]
}

function Set-SessionName {
    param([Parameter(Mandatory)][string]$Id, [string]$Name)
    $map = Read-SessionNames
    $Name = ($Name -replace '\s+', ' ').Trim()
    if ($Name) { $map[$Id] = $Name } else { [void]$map.Remove($Id) }
    [void](Write-SessionNames $map)
    $Name
}

if ($Sync) { "learned $(Sync-SessionNames) name(s) -> $script:NameStorePath" }
if ($List) {
    $map = Read-SessionNames
    $map.Keys | Sort-Object { $map[$_] } | ForEach-Object {
        [pscustomobject]@{ Name = $map[$_]; Session = $_ }
    } | Format-Table -AutoSize
}

# Dot-sourcing runs this in the caller's scope, so the switches above land there
# too - and a leftover [switch]$List is what the Board's own $List (its ListBox)
# then fails to overwrite. Clear them; the functions are the only export.
Remove-Variable -Name Sync, List -Scope 0 -ErrorAction SilentlyContinue
