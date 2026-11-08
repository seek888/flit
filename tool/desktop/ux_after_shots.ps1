<#
.SYNOPSIS
  Post-port ("after") Windows desktop screenshot run for Flit.

.DESCRIPTION
  Launches the freshly built release binary, walks the desktop shell with the
  reusable ui_probe.ps1 probe, and writes numbered screenshots plus a manifest
  into the output folder.

  Coordinate system: Shot captures the whole window frame (title bar included),
  while ClickRel/Move-UiProbeCursor address the client area. FRAME_TOP is the
  measured title-bar height at 150% DPI; At() subtracts it so steps can be
  written in screenshot pixels.

.PARAMETER Exe
  Built executable. Defaults to the release build in this repo.
.PARAMETER OutDir
  Screenshot folder.
.PARAMETER FlitHome
  Value for FLIT_DESKTOP_HOME (toolchain home holding projects/).
.PARAMETER StopAfter
  Stop after N steps (0 = all).
.PARAMETER KeepRunning
  Leave the app open at the end.
#>
[CmdletBinding()]
param(
  [string]$Exe = 'D:\Documents\GitHub\flit\build\windows\x64\runner\Release\flit.exe',
  [string]$OutDir = 'D:\flit-verify\ux-after',
  [string]$FlitHome = 'D:\flit-verify\home',
  [int]$StopAfter = 0,
  [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui_probe.ps1')

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$manifest = New-Object System.Collections.Generic.List[object]
$script:StepIndex = 0
$FRAME_TOP = 46   # title bar height in screenshot pixels (150% DPI)

function Get-Vis { return GetWindowBounds }
function At { param([int]$X, [int]$Y) ClickRel -X $X -Y ([Math]::Max(2, $Y - $FRAME_TOP)) }
function AtMove { param([int]$X, [int]$Y) Move-UiProbeCursor -X ($script:AppRect.X + $X) -Y ($script:AppRect.Y + $Y - $FRAME_TOP) }
function AtDouble { param([int]$X, [int]$Y) DoubleClick -X ($script:AppRect.X + $X) -Y ($script:AppRect.Y + $Y - $FRAME_TOP) }
function Escape { SendKeys '{ESC}' | Out-Null; Start-Sleep -Milliseconds 400 }

function Restart {
  Launch -Exe $Exe -Env @{ FLIT_DESKTOP_HOME = $FlitHome } -Fresh -TimeoutSec 90 | Out-Null
  WaitWindow -Title 'Flit' -TimeoutSec 90 | Out-Null
  FocusApp | Out-Null
  Start-Sleep -Milliseconds 2200
  $script:AppRect = GetWindowBounds
}

function Save-Step {
  param([string]$Name, [string]$Page, [string]$Action)
  $path = Join-Path $OutDir $Name
  Shot -Path $path | Out-Null
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
  @{ Name = '01-home.png'; Fresh = $true; Page = 'Project list (desktop home)'
     Action = 'fresh launch: menu bar + command toolbar + project table' }

  @{ Name = '02-menu-file.png'; Page = 'File menu'
     Action = 'click 文件';
     Run = { At -X 30 -Y 62 } }

  @{ Name = '03-menu-view.png'; Page = 'View menu'
     Action = 'Escape then click 视图';
     Run = { Escape; At -X 116 -Y 62 } }

  @{ Name = '04-editor.png'; Page = 'Editor 1268x794 logical: docked sidebar + tabs + status bar'
     Action = 'Escape then double-click my_app';
     Run = { Escape; AtDouble -X 300 -Y 265 }; SettleMs = 6000 }

  @{ Name = '05-editor-git.png'; Page = 'Editor / version control sidebar'
     Action = 'click 版本控制 tab in the sidebar';
     Run = { At -X 310 -Y 202 }; SettleMs = 2500 }

  @{ Name = '06-editor-terminal.png'; Page = 'Editor / terminal dock expanded'
     Action = 'click 终端 in the status bar (bottom right)';
     Run = { $v = Get-Vis; At -X ([int]($v.Width - 46)) -Y 1178 }; SettleMs = 2500 }

  @{ Name = '07-editor-960.png'; Page = 'Editor at 960 wide (dock threshold)'
     Action = 'resize to 960x700 logical';
     Run = { ResizeWindow -Width 960 -Height 700 -NoVerify }; SettleMs = 2500 }

  @{ Name = '08-editor-1500.png'; Page = 'Editor at 1500x900 logical'
     Action = 'resize to 1500x900 logical';
     Run = { ResizeWindow -Width 1500 -Height 900 -NoVerify }; SettleMs = 2500 }

  @{ Name = '09-shortcuts.png'; Page = 'Help / keyboard shortcuts dialog'
     Action = 'F1 opens 快捷键说明';
     Run = { SendKeys '{F1}' | Out-Null }; SettleMs = 2500 }

  @{ Name = '10-settings.png'; Page = 'Settings'
     Action = 'Escape x2 back to the list, then 设置';
     Run = { Escape; Escape; Start-Sleep -Milliseconds 800; At -X 1830 -Y 118 }; SettleMs = 3500 }
)

foreach ($step in $steps) {
  $script:StepIndex++
  if ($StopAfter -gt 0 -and $script:StepIndex -gt $StopAfter) { break }
  if ($step.ContainsKey('Fresh')) { Restart }
  if ($step.ContainsKey('Run')) { & $step['Run'] }
  if ($step.ContainsKey('SettleMs')) { Start-Sleep -Milliseconds $step['SettleMs'] }
  else { Start-Sleep -Milliseconds 1800 }
  Save-Step -Name $step['Name'] -Page $step['Page'] -Action $step['Action']
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutDir 'manifest.json') -Encoding UTF8
Write-Host ("wrote {0} screenshots + manifest.json to {1}" -f $manifest.Count, $OutDir)
if (-not $KeepRunning) { CloseApp | Out-Null }