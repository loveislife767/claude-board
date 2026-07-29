<#
.SYNOPSIS
  Claude Board - a dockable sidebar showing every Claude Code session by title.

.DESCRIPTION
  Replaces squinting at Windows Terminal tabs. One tall panel lists every
  session on disk, newest first, with the real title Claude gave it.

    - Green dot  = session is open right now in a terminal
    - Click it   = jumps Windows Terminal straight to that tab
    - Dbl-click  = resumes a closed session in a new tab
    - Type       = filters instantly

  Sessions live at %USERPROFILE%\.claude\projects\<encoded-cwd>\<id>.jsonl.
  Titles come from the "ai-title" records Claude writes into those files -
  the same string it puts in the terminal tab, which is how tabs get matched
  back to sessions.

.EXAMPLE
  .\ClaudeBoard.ps1            # open the board
  .\ClaudeBoard.ps1 -DockLeft  # open it already snapped to the left edge
#>
[CmdletBinding()]
param(
    [switch]$DockLeft,
    [switch]$DockRight,

    # Print what the board sees (sessions, tabs, and how they match) and exit.
    [switch]$Diagnose
)

$ErrorActionPreference = 'Stop'

# WPF needs a single-threaded apartment; pwsh defaults to MTA.
if (-not $Diagnose -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    $a = @('-sta', '-NoProfile', '-File', $PSCommandPath)
    if ($DockLeft)  { $a += '-DockLeft' }
    if ($DockRight) { $a += '-DockRight' }
    Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$Root      = Join-Path $env:USERPROFILE '.claude\projects'
$StatePath = Join-Path $PSScriptRoot 'board-state.json'

# ---- persistent /rename names ----------------------------------------------
# Claude Code keeps the name from /rename in .claude\sessions\<pid>.json and
# deletes that file on exit, so the name never reaches the transcript and never
# survives a resume. SessionNames.ps1 mirrors it into a store keyed by session id.
$script:NamesOk = $false
try {
    $sn = Join-Path $PSScriptRoot 'tools\SessionNames.ps1'
    if (Test-Path -LiteralPath $sn) { . $sn; $script:NamesOk = $true }
} catch { $script:NamesOk = $false }
if (-not $script:NamesOk) {
    function Get-ClaudeLiveSessions { @() }
    function Sync-SessionNames { 0 }
    function Read-SessionNames { @{} }
    function Set-SessionName { param([string]$Id, [string]$Name) $Name }
}

# ---- laptop<->desktop bridge (companion "Desktop" panel) -------------------
# Cross-machine logic lives in Downloads\desktop-claude-bridge; dot-source its
# helper so Invoke-Bridge / Resolve-DesktopSession / Assert-ClaudeTarget are
# available. If that folder isn't present the Board just runs local-only.
$script:BridgeDir = if ($env:DESKTOP_BRIDGE_DIR) { $env:DESKTOP_BRIDGE_DIR }
                    else { Join-Path $env:USERPROFILE 'Downloads\desktop-claude-bridge' }
$script:BridgeOk = $false
try {
    $bc = Join-Path $script:BridgeDir '_Bridge.Common.ps1'
    if (Test-Path -LiteralPath $bc) { . $bc; $script:BridgeOk = $true }
} catch { $script:BridgeOk = $false }

# ---------------------------------------------------------------- native bits

$script:Helpers = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeBoard {

public static class Native {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    // Every ConPTY shell owns a hidden-but-"visible" PseudoConsoleWindow.
    // Focusing one does nothing, so they must never be returned.
    public static IntPtr[] WindowsOfPids(uint[] pids) {
        var wanted = new HashSet<uint>(pids);
        var found  = new List<IntPtr>();
        EnumWindows((h, p) => {
            if (IsWindowVisible(h)) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (wanted.Contains(pid)) {
                    var cls = new StringBuilder(128);
                    GetClassName(h, cls, cls.Capacity);
                    if (cls.ToString() != "PseudoConsoleWindow") found.Add(h);
                }
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // Cross-process focus needs the input-queue attach dance or Windows just flashes the taskbar.
    public static void Focus(IntPtr h) {
        ShowWindow(h, IsIconic(h) ? 9 : 5);
        uint pid;
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint me = GetCurrentThreadId();
        if (fg != me) AttachThreadInput(fg, me, true);
        SetForegroundWindow(h);
        if (fg != me) AttachThreadInput(fg, me, false);
    }
}

public class SessionItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void N(string p) {
        var h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(p));
    }

    public string Id      { get; set; }
    public string Cwd     { get; set; }
    public string Path    { get; set; }
    public string Project { get; set; }
    public string Prompt  { get; set; }
    public string AiTitle { get; set; }
    public string Name    { get; set; }   // from /rename - beats AiTitle
    public int    ShellPid { get; set; }
    public int    ClaudePid { get; set; }

    string _title;
    public string Title { get { return _title; } set { if (_title != value) { _title = value; N("Title"); } } }

    string _sub;
    public string Sub { get { return _sub; } set { if (_sub != value) { _sub = value; N("Sub"); } } }

    DateTime _mod;
    public DateTime Modified { get { return _mod; } set { if (_mod != value) { _mod = value; N("Modified"); } } }

    bool _live;
    public bool IsLive {
        get { return _live; }
        set { if (_live != value) { _live = value; N("IsLive"); N("Dot"); N("Group"); N("GroupRank"); } }
    }

    bool _pinned;
    public bool Pinned {
        get { return _pinned; }
        set { if (_pinned != value) { _pinned = value; N("Pinned"); N("Star"); N("Group"); N("GroupRank"); } }
    }

    bool _hidden;
    public bool Hidden {
        get { return _hidden; }
        set { if (_hidden != value) { _hidden = value; N("Hidden"); N("Dot"); N("Group"); N("GroupRank"); } }
    }

    // A tab was found for this session, so clicking it can actually go somewhere.
    bool _linked;
    public bool Linked { get { return _linked; } set { if (_linked != value) { _linked = value; N("Linked"); } } }

    public string Star  { get { return _pinned ? "*" : ""; } }
    public string Dot   { get { return _hidden ? "#3A3733" : (_live ? "#5FD68A" : "#4C4945"); } }
    public string Group {
        get { return _hidden ? "HIDDEN" : (_pinned ? "PINNED" : (_live ? "OPEN NOW" : "NOT OPEN")); }
    }
    public int GroupRank { get { return _hidden ? 3 : (_pinned ? 0 : (_live ? 1 : 2)); } }
}

}
'@

# Compiling this C# at every launch cost ~4 seconds, which made the desktop
# icon feel dead. Build it once to a DLL and just load it after that.
if (-not ('ClaudeBoard.SessionItem' -as [type])) {
    $dll = Join-Path $PSScriptRoot 'ClaudeBoard.Types.dll'
    $stale = -not (Test-Path -LiteralPath $dll) -or
             (Get-Item -LiteralPath $dll).LastWriteTimeUtc -lt (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc
    if ($stale) {
        # Another running board may hold the old DLL open; fall back to memory.
        try { Add-Type -TypeDefinition $script:Helpers -OutputAssembly $dll -OutputType Library -ErrorAction Stop }
        catch { }
    }
    try { Add-Type -Path $dll -ErrorAction Stop }
    catch { Add-Type -TypeDefinition $script:Helpers -ErrorAction Stop }
}

# ---------------------------------------------------------------- single instance

# Clicking the desktop icon twice should raise the board, not start a second
# copy of it. The mutex settles the race between two fast double-clicks; the
# window hunt handles the ordinary "it's already open" case.
if (-not $Diagnose) {
    $isNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeBoardSingleInstance', [ref]$isNew)
    if (-not $isNew) {
        $deadline = (Get-Date).AddSeconds(12)
        do {
            $other = Get-Process -ErrorAction SilentlyContinue |
                     Where-Object { $_.MainWindowTitle -eq 'Claude Board' -and $_.Id -ne $PID } |
                     Select-Object -First 1
            if ($other) { [ClaudeBoard.Native]::Focus($other.MainWindowHandle); return }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        return   # already starting somewhere; don't add a duplicate
    }
}

# ---------------------------------------------------------------- session store

$script:Meta  = @{}  # jsonl path -> parsed metadata, keyed by last-write stamp
$script:Links = @{}  # session id -> tab name the user linked by hand

function Read-Chunk {
    param([string]$Path, [int]$Bytes, [switch]$FromEnd)
    # Claude holds these files open, so share read+write or every live session throws.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $len  = $fs.Length
        $take = [int][Math]::Min([long]$Bytes, $len)
        if ($FromEnd) { [void]$fs.Seek($len - $take, [IO.SeekOrigin]::Begin) }
        $buf  = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $n = $fs.Read($buf, $read, $take - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Dispose() }
}

function Read-SessionMeta {
    param([IO.FileInfo]$File)

    $cwd = $null; $prompt = $null; $ai = $null

    try { $head = Read-Chunk -Path $File.FullName -Bytes 262144 } catch { return $null }

    foreach ($line in ($head -split "`n")) {
        if ($line.Length -lt 2) { continue }
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }

        if (-not $cwd -and $o.cwd) { $cwd = [string]$o.cwd }

        if (-not $prompt -and $o.type -eq 'user') {
            $c = $o.message.content
            $txt = $null
            if ($c -is [string]) { $txt = $c }
            elseif ($c) { foreach ($p in @($c)) { if ($p.type -eq 'text' -and $p.text) { $txt = [string]$p.text; break } } }
            if ($txt) {
                $txt = ($txt -replace '\s+', ' ').Trim()
                $junk = $txt.StartsWith('<') -or $txt -like 'Caveat:*' -or
                        $txt -like '*system-reminder*' -or $txt -like '*<command-name>*'
                if (-not $junk -and $txt.Length -gt 0) { $prompt = $txt }
            }
        }
        if ($cwd -and $prompt) { break }
    }

    # The newest ai-title wins; it lives anywhere in the file, so sweep the tail too.
    $rx = [regex]'"aiTitle"\s*:\s*"((?:[^"\\]|\\.)*)"'
    $scan = $head
    if ($File.Length -gt 262144) {
        try { $scan = $head + (Read-Chunk -Path $File.FullName -Bytes 524288 -FromEnd) } catch { }
    }
    $m = $rx.Matches($scan)
    if ($m.Count -gt 0) {
        try { $ai = ('"' + $m[$m.Count - 1].Groups[1].Value + '"' | ConvertFrom-Json) } catch { $ai = $null }
    }

    [pscustomobject]@{
        Cwd     = if ($cwd) { $cwd } else { $env:USERPROFILE }
        Prompt  = if ($prompt) { $prompt } else { '(no opening prompt)' }
        AiTitle = $ai
    }
}

function Get-Sessions {
    if (-not (Test-Path $Root)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    # Harvest first: a name the user just typed into /rename is only on disk in a
    # pid file that vanishes the moment that terminal closes.
    [void](Sync-SessionNames)
    $names = Read-SessionNames

    foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        # Top-level *.jsonl only - the <id>\ subfolders are subagent transcripts,
        # not independently resumable sessions.
        foreach ($f in (Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue)) {
            if ($f.Length -le 0) { continue }
            $stamp = $f.LastWriteTimeUtc.Ticks
            $c = $script:Meta[$f.FullName]
            if (-not $c -or $c.Stamp -ne $stamp) {
                $meta = Read-SessionMeta $f
                if (-not $meta) { continue }
                $c = @{ Stamp = $stamp; Meta = $meta }
                $script:Meta[$f.FullName] = $c
            }
            $out.Add([pscustomobject]@{
                Id       = $f.BaseName
                Path     = $f.FullName
                Cwd      = $c.Meta.Cwd
                Prompt   = $c.Meta.Prompt
                AiTitle  = $c.Meta.AiTitle
                Name     = $names[$f.BaseName]
                Modified = $f.LastWriteTime
                SizeKB   = [int][math]::Round($f.Length / 1KB)
            })
        }
    }
    $out | Sort-Object Modified -Descending
}

function Get-LiveMap {
    # Two signals. The command line only names a session that was --resume'd, so it
    # misses every plain `claude`; the .claude\sessions\<pid>.json files name all of
    # them and are what Claude Code itself uses. Take both - the pid files win.
    $map = @{}
    $parent = @{}
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        $parent[[int]$p.ProcessId] = [int]$p.ParentProcessId
        if ($p.CommandLine -and $p.CommandLine -match '--resume\s+"?([0-9a-fA-F-]{36})') {
            $map[$Matches[1]] = @{ ClaudePid = [int]$p.ProcessId; ShellPid = [int]$p.ParentProcessId }
        }
    }
    foreach ($s in (Get-ClaudeLiveSessions)) {
        # A stale pid file (crash, not a clean exit) must not mark a dead session live.
        if (-not $parent.ContainsKey($s.Pid)) { continue }
        $map[$s.Id] = @{ ClaudePid = $s.Pid; ShellPid = $parent[$s.Pid] }
    }
    $map
}

# ---------------------------------------------------------------- terminal tabs

$script:TabCache = @{ At = [datetime]::MinValue; Tabs = @() }

function Get-TerminalTabs {
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:TabCache.At).TotalSeconds -lt 3) { return $script:TabCache.Tabs }

    $tabs = New-Object System.Collections.Generic.List[object]
    [uint32[]]$pids = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    if ($pids.Count) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem)
        foreach ($h in [ClaudeBoard.Native]::WindowsOfPids($pids)) {
            try {
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
                if (-not $root) { continue }
                foreach ($t in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
                    $tabs.Add([pscustomobject]@{ Hwnd = $h; Element = $t; Name = $t.Current.Name })
                }
            } catch { }
        }
    }
    # .ToArray(), not @(): PowerShell's array binder chokes on a List holding
    # PSCustomObjects that carry an AutomationElement.
    $script:TabCache = @{ At = (Get-Date); Tabs = $tabs.ToArray() }
    $script:TabCache.Tabs
}

function Normalize-TabName {
    param([string]$Name)
    if (-not $Name) { return '' }
    # Claude prefixes the tab with a spinner/status glyph while it works.
    ($Name -replace '^[^\p{L}\p{N}]+', '').Trim()
}

$script:Stop = @('the','and','for','with','an','to','of','in','on','my','me','it','is','are',
                 'set','up','new','out','how','can','get','run','from','into','that','this',
                 'claude','code','session','sessions','project','projects','chat','chats',
                 'build','building','make','making','create','creating','design','designing',
                 'fix','fixing','help','using','use','add','adding','pwsh','powershell',
                 'windows','terminal','file','files','test','testing')

function Split-Tokens {
    param([string]$Text)
    if (-not $Text) { return @() }
    # Split camelCase first so "discBOT" -> disc, bot and "imageGEN" -> image, gen.
    $t = [regex]::Replace($Text, '(?<=[a-z0-9])(?=[A-Z])', ' ')
    $t = [regex]::Replace($t, '(?<=[A-Z])(?=[A-Z][a-z])', ' ')
    @([regex]::Split($t.ToLowerInvariant(), '[^a-z0-9]+') |
      Where-Object { $_.Length -ge 2 -and $script:Stop -notcontains $_ })
}

function Get-StemOverlap {
    # "landscape" and "landscaping" share a stem but neither is a prefix of
    # the other, so plain StartsWith misses the pair entirely.
    param([string]$A, [string]$B)
    $n = [Math]::Min($A.Length, $B.Length)
    $i = 0
    while ($i -lt $n -and $A[$i] -eq $B[$i]) { $i++ }
    $i
}

function Get-MatchScore {
    param([string[]]$TabTokens, [string[]]$SessTokens)
    if (-not $TabTokens.Count -or -not $SessTokens.Count) { return 0.0 }
    $sum = 0.0
    $strong = $false
    foreach ($tt in $TabTokens) {
        $best = 0.0
        foreach ($st in $SessTokens) {
            $s = 0.0
            if     ($st -eq $tt)                               { $s = 2.0 }
            elseif ($tt.Length -ge 3 -and $st.StartsWith($tt)) { $s = 1.6 }
            elseif ($st.Length -ge 3 -and $tt.StartsWith($st)) { $s = 1.4 }
            else {
                $cp = Get-StemOverlap $tt $st
                if ($cp -ge 5 -and $cp -ge (0.6 * [Math]::Min($tt.Length, $st.Length))) { $s = 1.3 }
                elseif ($tt.Length -ge 4 -and $st.Contains($tt)) { $s = 1.0 }
            }
            if ($s -gt $best) { $best = $s }
            # "pcb" is short but exact, and that is plenty of evidence.
            if (($s -eq 2.0 -and $tt.Length -ge 3) -or ($s -ge 1.3 -and $tt.Length -ge 4)) { $strong = $true }
        }
        $sum += $best
    }
    # One solid word has to line up; loose partials alone are not evidence.
    if (-not $strong) { return 0.0 }
    $sum / $TabTokens.Count
}

function Get-SessionTokens {
    param($Item)
    $toks = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Item.Name, $Item.AiTitle, (Split-Path $Item.Cwd -Leaf))) {
        foreach ($t in (Split-Tokens $x)) { $toks.Add($t) }
    }
    # The opening prompt drifts off-topic fast, so only sample its head.
    $p = @(Split-Tokens $Item.Prompt) | Select-Object -First 12
    foreach ($t in $p) { $toks.Add($t) }
    @($toks | Select-Object -Unique)
}

$script:LinkCache = @{ At = [datetime]::MinValue; Map = @{}; Exact = @{} }

function Resolve-TabLinks {
    <#
      Tabs the user renamed by hand ("landscape", "discBOT") exist nowhere in
      Claude's session store, so identity has to be inferred.

        1. links the user set by hand always win
        2. a tab whose title IS the session's ai-title is certain - and also
           proves that session is open, which is the only way to spot a
           session started as plain `claude` rather than `claude --resume`
        3. everything else is scored token-wise and assigned best-first, 1:1,
           and only for sessions already known to be running

      Returns @{ Map = sessionId -> tab; Exact = sessionId -> $true }.
    #>
    param($Items, $ProcLive, [switch]$Force, [double]$MaxAge = 3)

    # Walking the UI Automation tree of every terminal window costs a few
    # hundred ms, so routine refreshes reuse the last result.
    if (-not $Force -and ((Get-Date) - $script:LinkCache.At).TotalSeconds -lt $MaxAge) {
        return $script:LinkCache
    }

    $tabs   = @(Get-TerminalTabs -Force:$Force)
    $result = @{ At = (Get-Date); Map = @{}; Exact = @{} }
    if (-not $tabs.Count) { $script:LinkCache = $result; return $result }

    $tabInfo = @(foreach ($t in $tabs) {
        $clean = Normalize-TabName $t.Name
        [pscustomobject]@{ Tab = $t; Clean = $clean; Tokens = Split-Tokens $clean }
    })
    $taken = @{}

    # 1. explicit links
    foreach ($it in $Items) {
        $want = $script:Links[$it.Id]
        if (-not $want) { continue }
        for ($i = 0; $i -lt $tabInfo.Count; $i++) {
            if ($taken[$i]) { continue }
            if ($tabInfo[$i].Clean -eq $want) {
                $result.Map[$it.Id] = $tabInfo[$i].Tab; $taken[$i] = $true; break
            }
        }
    }

    # 2. exact title match - the name from /rename, else the ai-title
    foreach ($it in $Items) {
        if ($result.Map.ContainsKey($it.Id)) { continue }
        $want2 = if ($it.Name) { $it.Name } else { $it.AiTitle }
        if (-not $want2) { continue }
        for ($i = 0; $i -lt $tabInfo.Count; $i++) {
            if ($taken[$i]) { continue }
            if ($tabInfo[$i].Clean -ieq $want2.Trim()) {
                $result.Map[$it.Id] = $tabInfo[$i].Tab
                $result.Exact[$it.Id] = $true
                $taken[$i] = $true
                break
            }
        }
    }

    # 3. fuzzy, running sessions only - never guess a link for a closed one
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Items) {
        if ($result.Map.ContainsKey($it.Id)) { continue }
        if ($ProcLive -and -not $ProcLive.ContainsKey($it.Id)) { continue }
        $st = Get-SessionTokens $it
        for ($i = 0; $i -lt $tabInfo.Count; $i++) {
            if ($taken[$i]) { continue }
            $sc = Get-MatchScore -TabTokens $tabInfo[$i].Tokens -SessTokens $st
            if ($sc -ge 1.2) { $pairs.Add([pscustomobject]@{ Id = $it.Id; Idx = $i; Score = $sc }) }
        }
    }
    foreach ($p in ($pairs.ToArray() | Sort-Object Score -Descending)) {
        if ($result.Map.ContainsKey($p.Id) -or $taken[$p.Idx]) { continue }
        $result.Map[$p.Id] = $tabInfo[$p.Idx].Tab
        $taken[$p.Idx] = $true
    }

    $script:LinkCache = $result
    $result
}

function Find-TabFor {
    param($Item, $Items, $ProcLive, [switch]$Force)
    if (-not $Items) { $Items = @($Item) }
    (Resolve-TabLinks -Items $Items -ProcLive $ProcLive -Force:$Force).Map[$Item.Id]
}

function Focus-Session {
    param($Item, $LiveItems)

    # A session in its own console window maps exactly via its shell pid.
    # Under Windows Terminal the shell has no real window, so this finds
    # nothing and we fall through to matching tabs by title.
    if ($Item.ShellPid -gt 0) {
        [uint32[]]$sp = @([uint32]$Item.ShellPid)
        $own = @([ClaudeBoard.Native]::WindowsOfPids($sp))
        if ($own.Count) { [ClaudeBoard.Native]::Focus($own[0]); return 'raised its window' }
    }

    $tab = Find-TabFor -Item $Item -Items $LiveItems -Force
    if ($tab) {
        try {
            $sel = $tab.Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $sel.Select()
            [ClaudeBoard.Native]::Focus($tab.Hwnd)
            return "jumped to tab: $($tab.Name)"
        } catch { return "found the tab but couldn't select it" }
    }
    # Live but unmatched - at least surface the terminal window.
    [uint32[]]$pids = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    $wins = @([ClaudeBoard.Native]::WindowsOfPids($pids))
    if ($wins.Count) { [ClaudeBoard.Native]::Focus($wins[0]); return 'no matching tab - raised the terminal' }
    'session is running but no terminal window found'
}

function Open-Session {
    param($Item, [switch]$NewWindow)
    $sh  = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $wt  = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    $cwd = if (Test-Path -LiteralPath $Item.Cwd) { $Item.Cwd } else { $env:USERPROFILE }
    $ttl = ConvertTo-TabTitle ($(if ($Item.Name) { $Item.Name } elseif ($Item.AiTitle) { $Item.AiTitle } else { $Item.Prompt }))

    # --resume alone comes back named "simon-1f"; hand the saved name back so the
    # prompt box, the /resume picker and the tab all agree with the board.
    $cmd = "claude --resume $($Item.Id)"
    if ($Item.Name) { $cmd += " --name `"$($Item.Name -replace '"', '')`"" }

    if ($wt) {
        $target = if ($NewWindow) { 'new' } else { '0' }
        & $wt -w $target new-tab --title $ttl -d $cwd -- $sh -NoExit -Command $cmd
    } else {
        Start-Process $sh -ArgumentList @('-NoExit', '-Command',
            "Set-Location -LiteralPath '$cwd'; $cmd")
    }
    "resumed: $ttl"
}

function New-Session {
    param([string]$Cwd)
    $sh = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    if (-not (Test-Path -LiteralPath $Cwd)) { $Cwd = $env:USERPROFILE }
    if ($wt) { & $wt -w 0 new-tab -d $Cwd -- $sh -NoExit -Command 'claude' }
    else { Start-Process $sh -ArgumentList @('-NoExit', '-Command', "Set-Location -LiteralPath '$Cwd'; claude") }
    "new session in $(Split-Path $Cwd -Leaf)"
}

function ConvertTo-TabTitle {
    param([string]$Text)
    $t = ($Text -replace '[^\x20-\x7E]', '') -replace '"', "'"
    if ($t.Length -gt 34) { $t = $t.Substring(0, 34) }
    if ([string]::IsNullOrWhiteSpace($t)) { $t = 'claude' }
    $t.Trim()
}

function Format-Project {
    param([string]$Cwd)
    if (-not $Cwd) { return '~' }
    $c = $Cwd.TrimEnd('\')
    if ($c -ieq $env:USERPROFILE.TrimEnd('\')) { return '~' }
    $leaf = Split-Path $c -Leaf
    # "Downloads" and friends say nothing on their own; borrow the parent,
    # unless the parent is just the home folder.
    if ($leaf -in @('Downloads','Documents','Desktop','src','app','source')) {
        $up = Split-Path (Split-Path $c -Parent) -Leaf
        if ($up -and $up -ne (Split-Path $env:USERPROFILE -Leaf)) { return "$up\$leaf" }
    }
    $leaf
}

function Format-Size {
    param([int]$KB)
    if ($KB -lt 1000) { "$KB KB" } else { "{0:0.#} MB" -f ($KB / 1024) }
}

function Format-Ago {
    param([datetime]$T)
    $s = ((Get-Date) - $T).TotalSeconds
    if ($s -lt 90)     { return 'just now' }
    if ($s -lt 5400)   { return "$([int]($s / 60))m ago" }
    if ($s -lt 172800) { return "$([int]($s / 3600))h ago" }
    "$([int]($s / 86400))d ago"
}

# ---------------------------------------------------------------- diagnose

if ($Diagnose) {
    $sessions = @(Get-Sessions)
    $live     = Get-LiveMap
    $tabs     = @(Get-TerminalTabs -Force)

    Write-Host "`nsessions on disk : $($sessions.Count)"
    Write-Host "running (--resume): $($live.Count)"
    Write-Host "terminal tabs     : $($tabs.Count)`n"

    Write-Host 'TABS' -ForegroundColor Cyan
    foreach ($t in $tabs) { Write-Host ("  hwnd {0,-8} '{1}'" -f $t.Hwnd, $t.Name) }

    $cand = @($sessions | Select-Object -First 40)
    $res  = Resolve-TabLinks -Items $cand -ProcLive $live -Force
    $open = @($cand | Where-Object { $live.ContainsKey($_.Id) -or $res.Exact[$_.Id] })

    Write-Host "`nOPEN SESSION -> TAB" -ForegroundColor Cyan
    $hit = 0
    foreach ($s in $open) {
        $tab = $res.Map[$s.Id]
        if ($tab) { $hit++ }
        $how = if ($res.Exact[$s.Id]) { 'EXACT' } elseif ($tab) { 'fuzzy' } else { 'MISS ' }
        $name = if ($s.AiTitle) { $s.AiTitle } else { $s.Prompt }
        if ($name.Length -gt 46) { $name = $name.Substring(0, 46) }
        Write-Host ("  {0} {1,-48} -> {2}" -f $how, $name, $(if ($tab) { $tab.Name } else { '(no tab)' }))
    }
    Write-Host "`nmatched $hit of $($open.Count) open sessions to a tab."

    $claimed = @{}
    foreach ($t in $res.Map.Values) { $claimed[$t.Name] = $true }
    $free = @($tabs | Where-Object { -not $claimed[$_.Name] })
    Write-Host "unclaimed tabs: $(($free | ForEach-Object { Normalize-TabName $_.Name }) -join ' | ')"

    Write-Host "`nWHY THE MISSES (best free tab per unmatched session)" -ForegroundColor Cyan
    foreach ($s in $open) {
        if ($res.Map[$s.Id]) { continue }
        $st = Get-SessionTokens $s
        $scored = foreach ($t in $free) {
            $clean = Normalize-TabName $t.Name
            [pscustomobject]@{ Tab = $clean; Score = Get-MatchScore -TabTokens (Split-Tokens $clean) -SessTokens $st }
        }
        $top = @($scored | Sort-Object Score -Descending | Select-Object -First 3 |
                 ForEach-Object { '{0}={1:0.00}' -f $_.Tab, $_.Score })
        $name = if ($s.AiTitle) { $s.AiTitle } else { $s.Prompt }
        if ($name.Length -gt 44) { $name = $name.Substring(0, 44) }
        Write-Host ("  {0,-46} {1}" -f $name, ($top -join '  '))
    }
    Write-Host ''
    return
}

# ---------------------------------------------------------------- state

function Load-State {
    if (Test-Path -LiteralPath $StatePath) {
        try { return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { }
    }
    [pscustomobject]@{ Pinned = @(); Hidden = @(); Links = $null; Left = $null; Top = $null
                       Width = 400; Height = 900; Topmost = $false }
}

function Save-State {
    $links = @{}
    foreach ($k in $script:Links.Keys) { $links[$k] = $script:Links[$k] }
    $s = [pscustomobject]@{
        Pinned  = @($script:Items | Where-Object { $_.Pinned } | ForEach-Object { $_.Id })
        Hidden  = @($script:HiddenIds.Keys)
        Links   = $links
        Left    = $win.Left; Top = $win.Top
        Width   = $win.Width; Height = $win.Height
        Topmost = $win.Topmost
    }
    try { $s | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8 } catch { }
}

$state  = Load-State
$pinned = @{}
foreach ($p in @($state.Pinned)) { if ($p) { $pinned[$p] = $true } }
$script:HiddenIds  = @{}
$script:ShowHidden = $false
foreach ($h in @($state.Hidden)) { if ($h) { $script:HiddenIds[$h] = $true } }
if ($state.Links) {
    foreach ($p in $state.Links.PSObject.Properties) { $script:Links[$p.Name] = [string]$p.Value }
}

# ---------------------------------------------------------------- ui

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Board" Width="400" Height="900"
        Background="#16150F" Foreground="#F0EEE6"
        WindowStartupLocation="Manual" ShowInTaskbar="True"
        FontFamily="Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Chip" TargetType="Button">
      <Setter Property="Background" Value="#221F1A"/>
      <Setter Property="Foreground" Value="#B8B4AC"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#322E27"/>
                <Setter Property="Foreground" Value="#F0EEE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#3B3630" CornerRadius="4" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Border Grid.Row="0" Background="#1C1A15" Padding="10,10,10,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#221F1A" CornerRadius="6" Height="28">
          <Grid>
            <TextBox x:Name="Search" Background="Transparent" Foreground="#F0EEE6" BorderThickness="0"
                     VerticalContentAlignment="Center" Padding="9,0" CaretBrush="#D97757" FontSize="12"/>
            <TextBlock x:Name="Hint" Text="filter sessions..." Foreground="#6E6A63" FontSize="12"
                       IsHitTestVisible="False" VerticalAlignment="Center" Margin="10,0,0,0"/>
          </Grid>
        </Border>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnNew"   Style="{StaticResource Chip}" Content="+"  ToolTip="Start a new session (pick a folder)"/>
          <Button x:Name="BtnDesk"  Style="{StaticResource Chip}" Content="&#x1F5A5;" ToolTip="Desktop sessions (laptop&#8596;desktop bridge)"/>
          <Button x:Name="BtnRef"   Style="{StaticResource Chip}" Content="&#x21bb;" ToolTip="Refresh"/>
          <Button x:Name="BtnEye"   Style="{StaticResource Chip}" Content="&#x2298;" ToolTip="Show hidden sessions"/>
          <Button x:Name="BtnPin"   Style="{StaticResource Chip}" Content="&#x25ce;" ToolTip="Always on top"/>
          <Button x:Name="BtnLeft"  Style="{StaticResource Chip}" Content="&#x25e7;" ToolTip="Dock left"/>
          <Button x:Name="BtnRight" Style="{StaticResource Chip}" Content="&#x25e8;" ToolTip="Dock right"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- list -->
    <ListBox x:Name="List" Grid.Row="1" Background="Transparent" BorderThickness="0"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled"
             VirtualizingPanel.IsVirtualizing="True">
      <ListBox.ItemContainerStyle>
        <Style TargetType="ListBoxItem">
          <Setter Property="Padding" Value="0"/>
          <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ListBoxItem">
                <Border x:Name="row" Background="Transparent" BorderThickness="3,0,0,0" BorderBrush="Transparent">
                  <ContentPresenter/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="row" Property="Background" Value="#211E19"/>
                  </Trigger>
                  <Trigger Property="IsSelected" Value="True">
                    <Setter TargetName="row" Property="Background" Value="#2A2620"/>
                    <Setter TargetName="row" Property="BorderBrush" Value="#D97757"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </ListBox.ItemContainerStyle>

      <ListBox.ItemTemplate>
        <DataTemplate>
          <Grid Margin="9,7,10,7">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Ellipse Grid.Column="0" Width="7" Height="7" Fill="{Binding Dot}"
                     VerticalAlignment="Top" Margin="0,6,9,0"/>
            <StackPanel Grid.Column="1">
              <TextBlock Text="{Binding Title}" Foreground="#EDEBE4" FontSize="12.5"
                         TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
              <TextBlock Text="{Binding Sub}" Foreground="#7E7A72" FontSize="10.5" Margin="0,3,0,0"
                         TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Grid>
        </DataTemplate>
      </ListBox.ItemTemplate>

      <ListBox.GroupStyle>
        <GroupStyle>
          <GroupStyle.HeaderTemplate>
            <DataTemplate>
              <Border Padding="12,14,10,5">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="{Binding Name}" Foreground="#8C8880" FontSize="10"
                             FontWeight="SemiBold"/>
                  <TextBlock Text="{Binding ItemCount, StringFormat=' {0}'}" Foreground="#57534C" FontSize="10"
                             FontWeight="SemiBold"/>
                </StackPanel>
              </Border>
            </DataTemplate>
          </GroupStyle.HeaderTemplate>
        </GroupStyle>
      </ListBox.GroupStyle>

      <ListBox.ContextMenu>
        <ContextMenu Background="#221F1A" Foreground="#EDEBE4" BorderBrush="#35312A">
          <MenuItem x:Name="MnuFocus"  Header="Jump to its tab"/>
          <MenuItem x:Name="MnuTab"    Header="Resume in a new tab"/>
          <MenuItem x:Name="MnuWin"    Header="Resume in a new window"/>
          <Separator/>
          <MenuItem x:Name="MnuLink"   Header="Link to a tab..."/>
          <MenuItem x:Name="MnuRename" Header="Rename (sticks)..."/>
          <MenuItem x:Name="MnuPin"    Header="Pin / unpin"/>
          <MenuItem x:Name="MnuFolder" Header="Open its folder"/>
          <MenuItem x:Name="MnuCopy"   Header="Copy resume command"/>
          <Separator/>
          <MenuItem x:Name="MnuHide"   Header="Remove from the board"/>
          <MenuItem x:Name="MnuKill"   Header="Close this session"/>
          <MenuItem x:Name="MnuDelete" Header="Delete this chat forever..."/>
        </ContextMenu>
      </ListBox.ContextMenu>
    </ListBox>

    <!-- status -->
    <Border Grid.Row="2" Background="#1C1A15" Padding="12,7">
      <TextBlock x:Name="Status" Foreground="#7E7A72" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
    </Border>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'Search','Hint','List','Status','BtnNew','BtnDesk','BtnRef','BtnEye','BtnPin','BtnLeft','BtnRight',
                'MnuFocus','MnuTab','MnuWin','MnuLink','MnuRename','MnuPin','MnuFolder','MnuCopy',
                'MnuHide','MnuKill','MnuDelete') {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

$script:Items = New-Object System.Collections.ObjectModel.ObservableCollection[ClaudeBoard.SessionItem]
$view = [System.Windows.Data.ListCollectionView]::new($script:Items)
$view.SortDescriptions.Add([ComponentModel.SortDescription]::new('GroupRank', 'Ascending'))
$view.SortDescriptions.Add([ComponentModel.SortDescription]::new('Modified', 'Descending'))
$view.GroupDescriptions.Add([System.Windows.Data.PropertyGroupDescription]::new('Group'))
$List.ItemsSource = $view

$script:Filter = ''
$view.Filter = [Predicate[object]]{
    param($o)
    if ($o.Hidden -and -not $script:ShowHidden) { return $false }
    if (-not $script:Filter) { return $true }
    $f = $script:Filter
    ($o.Title -and $o.Title.ToLowerInvariant().Contains($f)) -or
    ($o.AiTitle -and $o.AiTitle.ToLowerInvariant().Contains($f)) -or
    ($o.Project -and $o.Project.ToLowerInvariant().Contains($f)) -or
    ($o.Prompt -and $o.Prompt.ToLowerInvariant().Contains($f))
}

function Set-Status { param([string]$Text) $Status.Text = $Text }

function Update-Board {
    param([switch]$Deep)

    $sessions = @(Get-Sessions)
    $live     = Get-LiveMap
    # Only recent sessions can plausibly own a tab; scoring all 60 is enough.
    $cand     = @($sessions | Select-Object -First 60)
    $res      = Resolve-TabLinks -Items $cand -ProcLive $live -Force:$Deep -MaxAge 3600

    $byId    = @{}
    foreach ($i in $script:Items) { $byId[$i.Id] = $i }
    $seen    = @{}
    $regroup = $false
    $unlinked = 0

    foreach ($s in $sessions) {
        $seen[$s.Id] = $true
        # A tab titled exactly like the session proves it is open, which is the
        # only way to see a session started as plain `claude`.
        $isLive = $live.ContainsKey($s.Id) -or [bool]$res.Exact[$s.Id]
        # A name he chose outranks the ai-title, which Claude rewrites constantly.
        $title  = if ($s.Name) { $s.Name } elseif ($s.AiTitle) { $s.AiTitle } else { $s.Prompt }
        $proj   = Format-Project $s.Cwd
        # Most sessions run from the home folder; printing "~" 50 times is noise.
        $sub    = "$(Format-Ago $s.Modified)  ·  $(Format-Size $s.SizeKB)"
        if ($proj -ne '~') { $sub = "$proj  ·  $sub" }
        # With his own name on the row, the ai-title is what still says what it's about.
        if ($s.Name -and $s.AiTitle -and $s.AiTitle -ne $s.Name) { $sub = "$($s.AiTitle)  ·  $sub" }

        $isHidden = $script:HiddenIds.ContainsKey($s.Id)
        $tab = $res.Map[$s.Id]
        if ($isLive -and -not $isHidden) {
            if ($tab) {
                # Surfacing the tab name makes a wrong guess obvious at a glance.
                $tn = Normalize-TabName $tab.Name
                if ($tn -and $tn -ne $title) { $sub = "[$tn]  ·  $sub" }
            } else {
                $unlinked++
                $sub = "[click to link its tab]  ·  $sub"
            }
        }

        $it = $byId[$s.Id]
        if (-not $it) {
            $it = New-Object ClaudeBoard.SessionItem
            $it.Id = $s.Id
            $it.Pinned = $pinned.ContainsKey($s.Id)
            $script:Items.Add($it)
            $regroup = $true
        }
        $it.Cwd = $s.Cwd; $it.Path = $s.Path; $it.Project = $proj
        $it.Prompt = $s.Prompt; $it.AiTitle = $s.AiTitle; $it.Name = $s.Name
        $it.Title = $title; $it.Sub = $sub; $it.Modified = $s.Modified
        $it.Linked = [bool]$tab
        if ($it.IsLive -ne $isLive -or $it.Hidden -ne $isHidden) { $regroup = $true }
        $it.Hidden = $isHidden
        $it.IsLive = $isLive
        if ($live.ContainsKey($s.Id)) { $it.ClaudePid = $live[$s.Id].ClaudePid; $it.ShellPid = $live[$s.Id].ShellPid }
        else { $it.ClaudePid = 0; $it.ShellPid = 0 }
    }

    foreach ($gone in @($script:Items | Where-Object { -not $seen.ContainsKey($_.Id) })) {
        [void]$script:Items.Remove($gone); $regroup = $true
    }

    if ($regroup) { $view.Refresh() }

    $shown = @($script:Items | Where-Object { -not $_.Hidden })
    $n = $shown.Count
    $l = @($shown | Where-Object { $_.IsLive }).Count
    $h = $script:Items.Count - $n
    $msg = "$n sessions  ·  $l open"
    if ($unlinked) { $msg += "  ·  $unlinked need linking (just click one)" }
    if ($h)        { $msg += "  ·  $h hidden" }
    Set-Status $msg
}

function Get-Selected { $List.SelectedItem }

function Activate-Item {
    param($Item, [switch]$Resume)
    if (-not $Item) { return }
    if ($Item.IsLive -and -not $Resume) {
        # A running session with no tab match would otherwise raise some random
        # window and look broken. Ask which tab it is instead - once.
        if (-not $Item.Linked) { Show-TabPicker $Item; return }
        Set-Status (Focus-Session $Item -LiveItems @($script:Items))
    }
    else { Set-Status (Open-Session $Item) }
}

function Show-TabPicker {
    <#
      Small modal listing the terminal tabs open right now, so a session whose
      tab was renamed to something unguessable can be linked by hand.
    #>
    param($Item)

    $tabs = @(Get-TerminalTabs -Force)
    if (-not $tabs.Count) { Set-Status 'no terminal tabs found'; return }

    # Tabs already spoken for are still listed, just marked, so a bad auto-match
    # can be corrected without hunting for what stole the tab.
    $claimed = @{}
    foreach ($kv in $script:LinkCache.Map.GetEnumerator()) {
        if ($kv.Key -ne $Item.Id) { $claimed[(Normalize-TabName $kv.Value.Name)] = $true }
    }
    $free = @($tabs | ForEach-Object { Normalize-TabName $_.Name } |
              Where-Object { $_ } | Select-Object -Unique | Sort-Object { [bool]$claimed[$_] })
    $names = @('(clear link)') + @($free | ForEach-Object {
        if ($claimed[$_]) { "$_   - already linked" } else { $_ }
    })

    $px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Link to tab" Width="380" Height="440" Background="#16150F"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI" ResizeMode="NoResize">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#EDEBE4"/>
      <Setter Property="Background" Value="#2A2620"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#D97757"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="Cap" Grid.Row="0" Foreground="#B8B4AC" FontSize="11.5"
               TextWrapping="Wrap" Margin="0,0,0,10"/>
    <ListBox x:Name="Tabs" Grid.Row="1" Background="#1C1A15" Foreground="#EDEBE4"
             BorderBrush="#35312A" FontSize="12"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Ok" Content="Link" Width="80" Height="28" Margin="0,0,8,0"/>
      <Button x:Name="No" Content="Cancel" Width="80" Height="28"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Parse($px)
    $lst = $dlg.FindName('Tabs')
    $dlg.FindName('Cap').Text = "Which tab is `"$($Item.Title)`" running in?"
    foreach ($n in $names) { [void]$lst.Items.Add($n) }
    $cur = $script:Links[$Item.Id]
    $lst.SelectedIndex = if ($cur -and $names -contains $cur) { [array]::IndexOf($names, $cur) } else { 0 }

    $picked = $null
    $dlg.FindName('Ok').Add_Click({ $script:PickResult = $lst.SelectedItem; $dlg.DialogResult = $true })
    $dlg.FindName('No').Add_Click({ $dlg.DialogResult = $false })
    $lst.Add_MouseDoubleClick({ $script:PickResult = $lst.SelectedItem; $dlg.DialogResult = $true })
    $dlg.Owner = $win
    $script:PickResult = $null
    if (-not $dlg.ShowDialog()) { return }
    $picked = $script:PickResult
    if (-not $picked) { return }
    $picked = ($picked -replace '\s+- already linked$', '')

    if ($picked -eq '(clear link)') {
        $script:Links.Remove($Item.Id)
        Set-Status 'link cleared'
    } else {
        # One tab per session: drop any other session claiming this tab.
        foreach ($k in @($script:Links.Keys)) { if ($script:Links[$k] -eq $picked) { $script:Links.Remove($k) } }
        $script:Links[$Item.Id] = $picked
        Set-Status "linked to tab '$picked'"
    }
    Save-State
    Update-Board -Deep
}

# --- events

$Search.Add_TextChanged({
    $script:Filter = $Search.Text.Trim().ToLowerInvariant()
    $Hint.Visibility = if ($Search.Text) { 'Collapsed' } else { 'Visible' }
    $view.Refresh()
})

$Search.Add_KeyDown({
    if ($_.Key -eq 'Escape') { $Search.Text = ''; $_.Handled = $true }
    elseif ($_.Key -eq 'Return') {
        $first = @($view) | Select-Object -First 1
        if ($first) { $List.SelectedItem = $first; Activate-Item $first }
        $_.Handled = $true
    }
    elseif ($_.Key -eq 'Down') { $List.Focus(); if (-not $List.SelectedItem) { $List.SelectedIndex = 0 }; $_.Handled = $true }
})

# Single click jumps to a running tab; only a double-click spends RAM on a resume.
$List.Add_PreviewMouseLeftButtonUp({
    try {
        $src = $_.OriginalSource
        while ($src -and ($src -is [System.Windows.DependencyObject]) -and
               -not ($src -is [System.Windows.Controls.ListBoxItem])) {
            $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src)
        }
        if (($src -is [System.Windows.Controls.ListBoxItem]) -and $src.DataContext -and $src.DataContext.IsLive) {
            Activate-Item $src.DataContext
        }
    } catch { }
})

$List.Add_MouseDoubleClick({ $s = Get-Selected; if ($s) { Activate-Item $s -Resume:(-not $s.IsLive) } })

$List.Add_KeyDown({
    $s = Get-Selected
    if ($_.Key -eq 'Return') { Activate-Item $s -Resume:($s -and -not $s.IsLive); $_.Handled = $true }
    elseif ($_.Key -eq 'Escape') { $Search.Focus(); $_.Handled = $true }
    elseif ($_.Key -eq 'Delete' -and $s) { $MnuHide.RaiseEvent(
        (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent))) ; $_.Handled = $true }
})

$List.Add_ContextMenuOpening({
    $s = Get-Selected
    if ($s) { $MnuHide.Header = if ($s.Hidden) { 'Put back on the board' } else { 'Remove from the board' } }
})

$BtnRef.Add_Click({ Update-Board -Deep; Set-Status 'refreshed' })

function New-MenuItem {
    param([string]$Header, [scriptblock]$OnClick)
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $Header
    $mi.Add_Click($OnClick)
    $mi
}

# The + button drops a menu of places to start in: the selected session's folder,
# home, whatever folders recent sessions ran in, or anything you browse to.
$BtnNew.Add_Click({
    $menu = New-Object System.Windows.Controls.ContextMenu
    $menu.Background = '#221F1A'
    $menu.Foreground = '#EDEBE4'

    $sel = Get-Selected
    if ($sel -and $sel.Cwd) {
        $c = $sel.Cwd
        [void]$menu.Items.Add((New-MenuItem "New session in  $(Format-Project $c)" { Set-Status (New-Session $c) }.GetNewClosure()))
    }
    [void]$menu.Items.Add((New-MenuItem 'New session in  ~' { Set-Status (New-Session $env:USERPROFILE) }))
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $recent = @($script:Items | Where-Object { -not $_.Hidden } | Sort-Object Modified -Descending |
                ForEach-Object { $_.Cwd } | Where-Object { $_ -and $_ -ne $env:USERPROFILE } |
                Select-Object -Unique -First 8)
    foreach ($r in $recent) {
        $path = $r
        [void]$menu.Items.Add((New-MenuItem (Format-Project $path) { Set-Status (New-Session $path) }.GetNewClosure()))
    }
    if ($recent.Count) { [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator)) }

    [void]$menu.Items.Add((New-MenuItem 'Browse for a folder...' {
        Add-Type -AssemblyName System.Windows.Forms
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Start a Claude session in which folder?'
        $fb.SelectedPath = $env:USERPROFILE
        if ($fb.ShowDialog() -eq 'OK') { Set-Status (New-Session $fb.SelectedPath) }
    }))

    $menu.PlacementTarget = $BtnNew
    $menu.Placement = 'Bottom'
    $menu.IsOpen = $true
})
$BtnPin.Add_Click({
    $win.Topmost = -not $win.Topmost
    $BtnPin.Foreground = if ($win.Topmost) { '#D97757' } else { '#B8B4AC' }
    Set-Status $(if ($win.Topmost) { 'pinned on top' } else { 'not on top' })
})

function Dock-Window {
    param([switch]$Right)
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Top = $wa.Top
    $win.Height = $wa.Height
    $win.Left = if ($Right) { $wa.Right - $win.Width } else { $wa.Left }
}
$BtnLeft.Add_Click({ Dock-Window })
$BtnRight.Add_Click({ Dock-Window -Right })

$MnuFocus.Add_Click({ $s = Get-Selected; if ($s) { Set-Status (Focus-Session $s -LiveItems @($script:Items)) } })
$MnuLink.Add_Click({ $s = Get-Selected; if ($s) { Show-TabPicker $s } })
$MnuTab.Add_Click({   $s = Get-Selected; if ($s) { Set-Status (Open-Session $s) } })
$MnuWin.Add_Click({   $s = Get-Selected; if ($s) { Set-Status (Open-Session $s -NewWindow) } })
$MnuPin.Add_Click({
    $s = Get-Selected
    if ($s) {
        $s.Pinned = -not $s.Pinned
        if ($s.Pinned) { $pinned[$s.Id] = $true } else { $pinned.Remove($s.Id) }
        $view.Refresh()
    }
})
$MnuFolder.Add_Click({ $s = Get-Selected; if ($s -and (Test-Path -LiteralPath $s.Cwd)) { Start-Process explorer.exe $s.Cwd } })
$MnuCopy.Add_Click({
    $s = Get-Selected
    if ($s) {
        $c = "cd '$($s.Cwd)'; claude --resume $($s.Id)"
        if ($s.Name) { $c += " --name `"$($s.Name -replace '"', '')`"" }
        Set-Clipboard $c; Set-Status 'resume command copied'
    }
})
$MnuRename.Add_Click({
    $s = Get-Selected
    if (-not $s) { return }
    $new = Show-InputDialog "Rename `"$($s.Title)`"" `
        "Sticks to this chat for good - through closing the tab, a reboot and every resume. Leave it empty to go back to the title Claude picks." `
        -Text $s.Name -Ok 'Rename' -SingleLine
    if ($null -eq $new) { return }
    [void](Set-SessionName -Id $s.Id -Name $new)
    Update-Board
    Set-Status $(if ($new.Trim()) {
        if ($s.IsLive) { "named `"$($new.Trim())`" - run /rename in its tab to change it there too" }
        else { "named `"$($new.Trim())`"" }
    } else { 'name cleared' })
})
$BtnEye.Add_Click({
    $script:ShowHidden = -not $script:ShowHidden
    $BtnEye.Foreground = if ($script:ShowHidden) { '#D97757' } else { '#B8B4AC' }
    $view.Refresh()
    Set-Status $(if ($script:ShowHidden) { 'showing hidden sessions' } else { 'hidden sessions tucked away' })
})

$MnuHide.Add_Click({
    $s = Get-Selected
    if (-not $s) { return }
    if ($s.Hidden) {
        $script:HiddenIds.Remove($s.Id); $s.Hidden = $false
        Set-Status 'back on the board'
    } else {
        $script:HiddenIds[$s.Id] = $true; $s.Hidden = $true
        Set-Status "removed from the board - the chat itself is untouched (the $([char]0x2298) button shows hidden ones)"
    }
    $view.Refresh()
    Save-State
})

$MnuDelete.Add_Click({
    $s = Get-Selected
    if (-not $s) { return }
    if ($s.IsLive) { Set-Status 'close the session first, then delete it'; return }
    $r = [System.Windows.MessageBox]::Show(
        "Permanently delete this chat and its whole transcript?`n`n$($s.Title)`n`nThis cannot be undone.",
        'Claude Board', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try {
        Remove-Item -LiteralPath $s.Path -Force -ErrorAction Stop
        # Subagent transcripts live in a folder named after the session.
        $side = Join-Path (Split-Path $s.Path -Parent) $s.Id
        if (Test-Path -LiteralPath $side) { Remove-Item -LiteralPath $side -Recurse -Force -ErrorAction SilentlyContinue }
        $script:HiddenIds.Remove($s.Id)
        [void]$script:Items.Remove($s)
        $view.Refresh()
        Save-State
        Set-Status 'chat deleted'
    } catch { Set-Status "could not delete: $($_.Exception.Message)" }
})

$MnuKill.Add_Click({
    $s = Get-Selected
    if (-not $s -or -not $s.IsLive) { Set-Status 'that session is not running'; return }
    $r = [System.Windows.MessageBox]::Show("Close this session's terminal?`n`n$($s.Title)", 'Claude Board', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    foreach ($p in @($s.ShellPid, $s.ClaudePid)) {
        if ($p -gt 0) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
    Update-Board
    Set-Status 'session closed'
})

# refresh loop
# Rescanning tabs is the expensive half, so most ticks only recheck processes
# and file timestamps; the full tab sweep runs about every half minute.
$script:Tick = 0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(6)
$timer.Add_Tick({
    try {
        $script:Tick++
        Update-Board -Deep:($script:Tick % 5 -eq 0)
    } catch { Set-Status "refresh error: $($_.Exception.Message)" }
})

$win.Add_SourceInitialized({
    if ($state.Width)  { $win.Width  = [double]$state.Width }
    if ($state.Height) { $win.Height = [double]$state.Height }
    if ($null -ne $state.Left -and $null -ne $state.Top) {
        $win.Left = [double]$state.Left; $win.Top = [double]$state.Top
    } else { Dock-Window }
    if ($state.Topmost) { $win.Topmost = $true; $BtnPin.Foreground = '#D97757' }
    if ($DockLeft)  { Dock-Window }
    if ($DockRight) { Dock-Window -Right }
})

$win.Add_Loaded({
    $Search.Focus()
    Set-Status 'reading your sessions...'
    # Paint the window first. The opening scan reads every transcript and walks
    # each terminal's automation tree, and doing that inline made the board look
    # like it had failed to start.
    [void]$win.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{
            try { Update-Board -Deep } catch { Set-Status "startup error: $($_.Exception.Message)" }
            $timer.Start()
        })
})

$win.Add_Closing({ $timer.Stop(); Save-State })

# Ctrl+F from anywhere in the window lands in the filter box.
$win.Add_PreviewKeyDown({
    if ($_.Key -eq 'F' -and [System.Windows.Input.Keyboard]::Modifiers -band 'Control') {
        $Search.Focus(); $Search.SelectAll(); $_.Handled = $true
    }
})

# ============================================================
# DESKTOP BRIDGE PANEL  -  laptop <-> desktop Claude sessions
# A companion window over Downloads\desktop-claude-bridge: list the desktop's
# Claude sessions and read / talk to / attach any of them. Self-contained;
# touches none of the local-board data model above.
# ============================================================

$script:PopupBtnStyle = @'
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#EDEBE4"/>
      <Setter Property="Background" Value="#2A2620"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#D97757"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#6E6A63"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

function Show-TextPopup {
    param([string]$Title, [string]$Text)
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([Security.SecurityElement]::Escape($Title))" Width="860" Height="640"
        Background="#16150F" Foreground="#EDEBE4" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
  <Window.Resources>$script:PopupBtnStyle</Window.Resources>
  <Grid Margin="10">
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#12110C" BorderBrush="#2A2620" BorderThickness="1" CornerRadius="6">
      <TextBox x:Name="T" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
               VerticalScrollBarVisibility="Auto" Background="Transparent" Foreground="#D7D3CA"
               BorderThickness="0" Padding="12" FontFamily="Cascadia Mono, Consolas" FontSize="12.5"/>
    </Border>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Copy" Content="Copy all" Width="100" Height="30" Margin="0,0,8,0"/>
      <Button x:Name="Close" Content="Close" Width="100" Height="30"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $d = [Windows.Markup.XamlReader]::Parse($x)
    $tb = $d.FindName('T'); $tb.Text = $Text
    $d.FindName('Copy').Add_Click({ try { Set-Clipboard $Text } catch { } }.GetNewClosure())
    $d.FindName('Close').Add_Click({ $d.Close() }.GetNewClosure())
    $d.Owner = $win
    [void]$d.ShowDialog()
}

function Show-InputDialog {
    param([string]$Title, [string]$Prompt, [string]$Text, [string]$Ok = 'Send', [switch]$SingleLine)
    # A one-line answer wants Enter to mean OK; a message to a session wants Enter
    # to mean newline, so the box only swallows it in the multi-line case.
    $multi = if ($SingleLine) { 'False' } else { 'True' }
    $h     = if ($SingleLine) { '210' } else { '250' }
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([Security.SecurityElement]::Escape($Title))" Width="640" Height="$h"
        Background="#16150F" Foreground="#EDEBE4" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" ResizeMode="NoResize">
  <Window.Resources>$script:PopupBtnStyle</Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="$([Security.SecurityElement]::Escape($Prompt))" Foreground="#B8B4AC" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <TextBox x:Name="In" Grid.Row="1" Background="#12110C" Foreground="#EDEBE4" CaretBrush="#D97757"
             BorderBrush="#2A2620" BorderThickness="1" Padding="8" TextWrapping="Wrap" AcceptsReturn="$multi"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="Ok" Content="$([Security.SecurityElement]::Escape($Ok))" Width="100" Height="30" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="No" Content="Cancel" Width="100" Height="30"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $d = [Windows.Markup.XamlReader]::Parse($x)
    $in = $d.FindName('In')
    if ($Text) { $in.Text = $Text; $in.SelectAll() }
    $script:InputResult = $null
    $d.FindName('Ok').Add_Click({ $script:InputResult = $in.Text; $d.DialogResult = $true }.GetNewClosure())
    $d.FindName('No').Add_Click({ $d.DialogResult = $false }.GetNewClosure())
    $d.Owner = $win
    $in.Focus()
    if ($d.ShowDialog()) { return $script:InputResult }
    return $null
}

$script:DeskWin = $null
function Show-DesktopPanel {
    if (-not $script:BridgeOk) {
        [System.Windows.MessageBox]::Show(
            "Desktop bridge not found.`n`nExpected _Bridge.Common.ps1 in:`n$script:BridgeDir`n`nSet `$env:DESKTOP_BRIDGE_DIR if it lives elsewhere.",
            'Desktop bridge', 'OK', 'Warning') | Out-Null
        return
    }
    if ($script:DeskWin) { try { $script:DeskWin.Activate(); return } catch { $script:DeskWin = $null } }

    $xaml2 = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desktop sessions" Width="560" Height="720" Background="#16150F" Foreground="#EDEBE4"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
  <Window.Resources>
    $script:PopupBtnStyle
    <Style TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="r" Background="Transparent" BorderThickness="3,0,0,0" BorderBrush="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="r" Property="Background" Value="#211E19"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="r" Property="Background" Value="#2A2620"/>
                <Setter TargetName="r" Property="BorderBrush" Value="#D97757"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#1C1A15" Padding="12,10">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Desktop" Foreground="#EDEBE4" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="Host" Foreground="#7E7A72" FontSize="11" Margin="8,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="Refresh" Content="&#x21bb; refresh" Height="26" Margin="14,0,0,0"/>
      </StackPanel>
    </Border>
    <ListBox x:Name="Lst" Grid.Row="1" Background="Transparent" BorderThickness="0"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <Grid Margin="10,7,10,7">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Ellipse Grid.Column="0" Width="7" Height="7" Fill="{Binding Dot}" VerticalAlignment="Top" Margin="0,5,9,0"/>
            <StackPanel Grid.Column="1">
              <TextBlock Text="{Binding Line1}" Foreground="#EDEBE4" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
              <TextBlock Text="{Binding Line2}" Foreground="#7E7A72" FontSize="10.5" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Grid>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
    <WrapPanel Grid.Row="2" Margin="10,8,10,4">
      <Button x:Name="BRead"   Content="Read"        Height="30" Width="92"  Margin="0,0,6,6"/>
      <Button x:Name="BSend"   Content="Send msg..." Height="30" Width="104" Margin="0,0,6,6"/>
      <Button x:Name="BAttach" Content="Attach"      Height="30" Width="92"  Margin="0,0,6,6"/>
      <Button x:Name="BCopy"   Content="Copy cmd"    Height="30" Width="100" Margin="0,0,6,6"/>
    </WrapPanel>
    <Border Grid.Row="3" Background="#1C1A15" Padding="12,7">
      <TextBlock x:Name="St" Foreground="#7E7A72" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
    </Border>
  </Grid>
</Window>
"@
    $dw = [Windows.Markup.XamlReader]::Parse($xaml2)
    $Lst = $dw.FindName('Lst'); $St = $dw.FindName('St'); $HostT = $dw.FindName('Host')
    $HostT.Text = $script:DesktopHost
    $script:DeskWin = $dw

    $selRow = { $Lst.SelectedItem }
    $setSt  = { param($m) $St.Text = $m }

    $reload = {
        & $setSt 'loading desktop sessions...'
        try {
            $raw  = Invoke-Bridge 'list'
            $rows = @($raw | ConvertFrom-Json)
            $Lst.Items.Clear()
            foreach ($r in $rows) {
                $dot = if ($r.live) { '#6EA8FE' } else { '#4A5568' }
                $l1  = (($(if ($r.target) { $r.target + '  ' } else { '' })) + $r.title)
                $l2parts = @()
                if ($r.project -and $r.project -ne '~') { $l2parts += $r.project }
                $l2parts += $r.ago
                if ($r.live) { $l2parts += 'live' } elseif ($r.size_kb) { $l2parts += "$($r.size_kb) KB" }
                $Lst.Items.Add([pscustomobject]@{
                    Dot = $dot; Line1 = $l1; Line2 = ($l2parts -join ('  ' + [char]0x00b7 + '  '))
                    _t = $r.target; _id = $r.id; _live = [bool]$r.live; _title = $r.title
                }) | Out-Null
            }
            $live = @($rows | Where-Object { $_.live }).Count
            & $setSt "$($rows.Count) sessions  ·  $live live   (double-click = read)"
        } catch {
            & $setSt "error: $($_.Exception.Message.Split([char]10)[0])"
            Show-TextPopup 'Desktop bridge error' $_.Exception.Message
        }
    }

    $doRead = {
        $s = & $selRow; if (-not $s) { & $setSt 'pick a session first'; return }
        & $setSt "reading $($s._title)..."
        try {
            if ($s._live -and $s._t) { $txt = Invoke-Bridge "capture --target $(Q $s._t) --lines 140" }
            elseif ($s._id)          { $txt = Invoke-Bridge "read --id $($s._id) --tail 30" }
            else { & $setSt 'nothing to read for that row'; return }
            Show-TextPopup "read: $($s._title)" $txt
            & $setSt 'ready'
        } catch { Show-TextPopup 'read failed' $_.Exception.Message; & $setSt 'read failed' }
    }

    $doSend = {
        $s = & $selRow; if (-not $s) { & $setSt 'pick a session first'; return }
        if (-not $s._live -or -not $s._t) { & $setSt "'$($s._title)' isn't live - can't type into a saved transcript"; return }
        $msg = Show-InputDialog "Send to $($s._title)  ($($s._t))" "Types this straight into that live desktop session, as if you keyed it in. It will run."
        if (-not $msg) { return }
        try {
            Assert-ClaudeTarget $s._t | Out-Null
            Invoke-Desktop "tmux send-keys -t $(Q $s._t) -l -- $(Q $msg)" | Out-Null
            Start-Sleep -Milliseconds 250
            Invoke-Desktop "tmux send-keys -t $(Q $s._t) Enter" | Out-Null
            & $setSt "sent to $($s._t) - waiting 13s for a reply..."
            Start-Sleep -Seconds 13
            $reply = Invoke-Bridge "capture --target $(Q $s._t) --lines 55"
            Show-TextPopup "reply from $($s._title)  ($($s._t))" $reply
            & $setSt 'ready'
        } catch { Show-TextPopup 'send failed' $_.Exception.Message; & $setSt 'send failed' }
    }

    $doAttach = {
        $s = & $selRow; if (-not $s) { & $setSt 'pick a session first'; return }
        if (-not $s._live -or -not $s._t) { & $setSt "'$($s._title)' isn't live - nothing to attach to"; return }
        $sess = ($s._t -split ':')[0]
        $remote = "tmux select-window -t $($s._t) 2>/dev/null; exec tmux attach -t $sess"
        $wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
        try {
            if ($wt) { & $wt -w 0 new-tab --title "dt:$($s._title)" -- ssh -t $script:DesktopHost $remote }
            else { Start-Process 'ssh' -ArgumentList @('-t', $script:DesktopHost, $remote) }
            & $setSt "attaching to $($s._t) in a terminal (Ctrl-b d to detach)"
        } catch { & $setSt "attach failed: $($_.Exception.Message)" }
    }

    $doCopy = {
        $s = & $selRow; if (-not $s) { & $setSt 'pick a session first'; return }
        if ($s._live -and $s._t)   { $arg = "-Target $($s._t)" }
        elseif ($s._id)            { $arg = "-Id $($s._id)" }
        else                       { $arg = "-Query `"$($s._title)`"" }
        $cmd = "pwsh -NoProfile -File `"$script:BridgeDir\Read-DesktopChat.ps1`" $arg -Screen"
        try { Set-Clipboard $cmd; & $setSt 'copied a read-command - paste it into any laptop Claude chat and say "run this"' } catch { }
    }

    $dw.FindName('Refresh').Add_Click($reload)
    $dw.FindName('BRead').Add_Click($doRead)
    $dw.FindName('BSend').Add_Click($doSend)
    $dw.FindName('BAttach').Add_Click($doAttach)
    $dw.FindName('BCopy').Add_Click($doCopy)
    $Lst.Add_MouseDoubleClick($doRead)
    $dw.Add_Closed({ $script:DeskWin = $null })
    $dw.Owner = $win
    $dw.Add_ContentRendered($reload)
    [void]$dw.Show()
}

$BtnDesk.Add_Click({ Show-DesktopPanel })

[void]$win.ShowDialog()
