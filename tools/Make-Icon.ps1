<#
.SYNOPSIS
  Draw claude-board.ico - a dark panel with an accent rail and list rows.

.DESCRIPTION
  Renders the mark at several sizes and packs them into one .ico. Windows picks
  the size it needs, so the desktop, taskbar and Start search all stay sharp.
  Sizes above 48 are stored as PNG (supported since Vista), which keeps the file small.
#>
[CmdletBinding()]
param([string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'claude-board.ico'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$SIZES = 16, 24, 32, 48, 64, 128, 256

function New-Rounded {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    if ($d -le 0) { $p.AddRectangle((New-Object Drawing.RectangleF($X, $Y, $W, $H))); return $p }
    $p.AddArc($X,          $Y,          $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y,          $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
    $p.AddArc($X,          $Y + $H - $d, $d, $d,  90, 90)
    $p.CloseFigure()
    $p
}

function New-Frame {
    param([int]$S)
    $bmp = New-Object Drawing.Bitmap($S, $S, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)

    # panel
    $panel = New-Rounded 0 0 $S $S ($S * 0.22)
    $bg = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 28, 26, 21))
    $g.FillPath($bg, $panel)

    # accent rail down the left - the sidebar itself
    $railW = [Math]::Max(2.0, $S * 0.11)
    $rail = New-Rounded ($S * 0.17) ($S * 0.20) $railW ($S * 0.60) ($railW / 2)
    $accent = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 217, 119, 87))
    $g.FillPath($accent, $rail)

    # three list rows, the top one "live" and brighter
    $rowX = $S * 0.40
    $rowW = $S * 0.43
    $rowH = [Math]::Max(2.0, $S * 0.10)
    # Parens are required: in PowerShell "," binds tighter than "*".
    $ys = @(($S * 0.24), ($S * 0.45), ($S * 0.66))
    $cols = @(
        [Drawing.Color]::FromArgb(255, 237, 235, 228),
        [Drawing.Color]::FromArgb(255, 140, 136, 128),
        [Drawing.Color]::FromArgb(255, 105, 101, 94)
    )
    for ($i = 0; $i -lt 3; $i++) {
        $b = New-Object Drawing.SolidBrush $cols[$i]
        $w = if ($i -eq 2) { $rowW * 0.66 } else { $rowW }
        $g.FillPath($b, (New-Rounded $rowX $ys[$i] $w $rowH ($rowH / 2)))
        $b.Dispose()
    }

    $g.Dispose(); $bg.Dispose(); $accent.Dispose(); $panel.Dispose(); $rail.Dispose()
    $bmp
}

$frames = foreach ($s in $SIZES) {
    $bmp = New-Frame $s
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [pscustomobject]@{ Size = $s; Bytes = $ms.ToArray() }
}
$frames = @($frames)

$fs = [IO.File]::Create($Out)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)   # ICONDIR

$offset = 6 + (16 * $frames.Count)
foreach ($f in $frames) {
    $bw.Write([byte]($(if ($f.Size -ge 256) { 0 } else { $f.Size })))   # 0 means 256
    $bw.Write([byte]($(if ($f.Size -ge 256) { 0 } else { $f.Size })))
    $bw.Write([byte]0)              # palette
    $bw.Write([byte]0)              # reserved
    $bw.Write([uint16]1)            # planes
    $bw.Write([uint16]32)           # bpp
    $bw.Write([uint32]$f.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.Bytes) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()

Write-Host "wrote $Out ($([int]((Get-Item $Out).Length / 1KB)) KB, $($frames.Count) sizes)" -ForegroundColor Green
