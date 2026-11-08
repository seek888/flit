<#
.SYNOPSIS
  Baseline ("before the Windows port") screenshot run for Flit.

.DESCRIPTION
  Launches the archived pre-port build (D:\flit-verify\ux-before\app\flit.exe)
  against an existing FlitDesk home (D:\flit-verify\home, which holds my_app),
  walks the pages with the reusable probe in ui_probe.ps1, and writes numbered
  screenshots plus a JSON manifest into the output folder.

  Why coordinates: this Flutter build exposes no UIA semantics tree (checked:
  UIAutomation sees only the FLUTTERVIEW pane), so the script clicks by
  window-relative physical pixels. All hit points were measured on the
  1902x1191 visible frame at 150% DPI (3840x2160 physical = 2560x1440 logical).
  Hit points anchored to the right/bottom edge use the live window size, so
  they keep working after a resize; content coordinates assume a >= 1200 px
  wide window (the baseline layout clamps content to 800 logical px anyway).

  Each page group starts from a fresh launch (-Fresh): a single long click
  chain drifts as soon as one navigation misses, and a fresh start always
  lands on the project list.

.PARAMETER Exe
  Pre-port executable. Defaults to the archived baseline copy.
.PARAMETER OutDir
  Screenshot folder. PNGs are named NN-<page>.png; manifest.json is written.
.PARAMETER FlitHome
  Value for FLIT_DESKTOP_HOME (toolchain home that holds projects/).
.PARAMETER StopAfter
  Stop after N steps (0 = all). Useful while calibrating clicks.
.PARAMETER StartAt
  First step number to run (1-based); earlier steps are skipped.
.PARAMETER KeepRunning
  Leave the app open at the end (default: close it).

.EXAMPLE
  pwsh -File tool\desktop\ux_baseline_shots.ps1
.EXAMPLE
  pwsh -File tool\desktop\ux_baseline_shots.ps1 -StopAfter 5 -KeepRunning
#>
[CmdletBinding()]
param(
  [string]$Exe = 'D:\flit-verify\ux-before\app\flit.exe',
  [string]$OutDir = 'D:\flit-verify\ux-before',
  [string]$FlitHome = 'D:\flit-verify\home',
  [int]$StopAfter = 0,
  [int]$StartAt = 1,
  [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui_probe.ps1')

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$manifest = New-Object System.Collections.Generic.List[object]
$script:StepIndex = 0

function Get-Vis { return GetWindowBounds }

function Restart {
  Launch -Exe $Exe -Env @{ FLIT_DESKTOP_HOME = $FlitHome } -Fresh -TimeoutSec 90 | Out-Null
  WaitWindow -Title 'Flit' -TimeoutSec 90 | Out-Null
  FocusApp | Out-Null
  Start-Sleep -Milliseconds 1500
}

# Appbar icon anchored to the window's right edge (measured: +173, clone 105, gear 38).
function ClickTopRight {
  param([int]$FromRight, [int]$Y = 79)
  $v = Get-Vis
  ClickRel -X ($v.Width - $FromRight) -Y $Y
}

# Bottom status bar toggle (left chevron), anchored to the window's bottom edge.
function ClickStatusBar { param([int]$X = 39); $v = Get-Vis; ClickRel -X $X -Y ($v.Height - 58) }

# Editor dock toolbar: terminal toggle sits after the 代码/预览 tabs, right of them.
function ClickTerminalToggle { $v = Get-Vis; ClickRel -X 113 -Y ($v.Height - 51) }

# Appbar back arrow of a pushed route.
function ClickBack { param([int]$X = 50, [int]$Y = 111); ClickRel -X $X -Y $Y }

function Save-Step {
  param([string]$Name, [string]$Page, [string]$Action)
  $path = Join-Path $OutDir $Name
  $shot = Shot -Path $path
  $v = Get-Vis
  $manifest.Add([pscustomobject]@{
      file          = [System.IO.Path]::GetFileName($path)
      page          = $Page
      action        = $Action
      windowWidth   = $v.Width
      windowHeight  = $v.Height
      logicalWidth  = $v.LogicalWidth
      logicalHeight = $v.LogicalHeight
      windowX       = $v.X
      windowY       = $v.Y
      dpi           = $v.Dpi
      capturedAt    = (Get-Date).ToString('s')
    })
  Write-Host ''
}

$steps = @(
  @{ Name = '01-projects.png'; Fresh = $true; Page = 'Project list (home)'
     Action = 'fresh launch, default 1280x800 logical window' }

  @{ Name = '02-projects-storage-dialog.png'; Fresh = $true; Page = 'Project list / "where are projects stored" dialog'
     Action = 'fresh launch, click the storage banner row' ;
     Run = { $v = Get-Vis; ClickRel -X ([int]($v.Width / 2)) -Y 151 } }

  @{ Name = '03-new-project.png'; Fresh = $true; Page = 'New project'
     Action = 'fresh launch, click + in the app bar';
     Run = { ClickTopRight -FromRight 173 } }

  @{ Name = '04-clone-project.png'; Fresh = $true; Page = 'Clone repository'
     Action = 'fresh launch, click the download icon in the app bar';
     Run = { ClickTopRight -FromRight 105 } }

  @{ Name = '05-settings.png'; Fresh = $true; Page = 'Settings'
     Action = 'fresh launch, click the gear icon in the app bar';
     Run = { ClickTopRight -FromRight 38 } }

  @{ Name = '06-environment.png'; Fresh = $true; Page = 'Development environment'
     Action = 'fresh launch, gear, then the 寮€鍙戠幆澧?row';
     Run = { ClickTopRight -FromRight 38; ClickRel -X 760 -Y 682 }; SettleMs = 4500 }

  @{ Name = '07-env-vars.png'; Fresh = $true; Page = 'Environment variables'
     Action = 'fresh launch, gear, then the 鐜鍙橀噺 row';
     Run = { ClickTopRight -FromRight 38; ClickRel -X 760 -Y 779 } }

  @{ Name = '08-editor.png'; Fresh = $true; Page = 'Editor / workbench (project opened)'
     Action = 'fresh launch, click the my_app project tile';
     Run = { $v = Get-Vis; ClickRel -X ([int]($v.Width / 2) - 250) -Y 327 } }

  @{ Name = '09-editor-file-drawer.png'; Page = 'Editor / project tool window (file tree)'
     Action = 'click the hamburger at the top left';
     Run = { ClickRel -X 37 -Y 79 } }

  @{ Name = '10-editor-file-open.png'; Page = 'Editor / second file open in the tab row'
     Action = 'click analysis_options.yaml in the file tree';
     Run = { ClickRel -X 150 -Y 630 } }

  @{ Name = '11-editor-terminal-expanded.png'; Page = 'Editor / task console expanded'
     Action = 'close the modal drawer (click the editor area), then click the terminal toggle in the dock toolbar';
     Run = { ClickRel -X 1000 -Y 600; ClickTerminalToggle } }

  @{ Name = '12-editor-narrow.png'; Page = 'Editor at 900x900 logical'
     Action = 'resize to 900x900 logical (records any min-size clamp; no persistent sidebar expected)';
     Run = { ResizeWindow -Width 900 -Height 900 -NoVerify } }

  @{ Name = '13-editor-wide.png'; Page = 'Editor at 1600x900 logical'
     Action = 'resize to 1600x900 logical (content column stays 800 logical)';
     Run = { ResizeWindow -Width 1600 -Height 900 -NoVerify } }
)

foreach ($step in $steps) {
  $script:StepIndex++
  if ($script:StepIndex -lt $StartAt) { continue }
  if ($StopAfter -gt 0 -and $script:StepIndex -gt $StopAfter) { break }
  if ($step.ContainsKey('Fresh')) { Restart }
  if ($step.ContainsKey('Run')) { & $step['Run'] }
  if ($step.ContainsKey('SettleMs')) { Start-Sleep -Milliseconds $step['SettleMs'] }
  else { Start-Sleep -Milliseconds 2500 }
  Save-Step -Name $step['Name'] -Page $step['Page'] -Action $step['Action']
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutDir 'manifest.json') -Encoding UTF8
Write-Host ("wrote {0} screenshots + manifest.json to {1}" -f $manifest.Count, $OutDir)
if (-not $KeepRunning) { CloseApp | Out-Null }
Write-Host 'baseline run complete'

