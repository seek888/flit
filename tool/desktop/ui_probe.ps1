<#
.SYNOPSIS
  Reusable Windows UI probe for Flit desktop acceptance runs.

.DESCRIPTION
  Drives and screenshots a running Windows desktop app (Flit) from PowerShell.
  Works on Windows PowerShell 5.1 and PowerShell 7+.

  Design goals:
    * DPI aware: the process opts into per-monitor-v2 awareness before any
      window work, so all coordinates and screenshots are in physical pixels.
      Required on 2560x1440 @ 125%/150% desktops; otherwise clicks drift.
    * UIAutomation first, coordinates as fallback: FindByUia/Click -Name use
      the accessibility tree when the app exposes one (Flutter does when
      semantics is on); ClickRel uses window-relative physical pixels.
    * Explicit failures: every helper throws "[ui_probe] ..." with the state it
      observed and what to do next. No silent no-ops.
    * Idempotent: Launch re-uses an already running instance of the same exe;
      KillApp/CloseApp tolerate an already-closed app; Shot overwrites.
    * Fully parameterised paths: nothing hard-coded except documented defaults.

  Units:
    * Public *coordinate* inputs are physical screen pixels (Click, ClickRel).
    * ResizeWindow takes LOGICAL width/height by default (window-manager
      semantics) and scales by the window DPI; pass -Physical to bypass.
    * Reported bounds carry both physical and logical size.

  Usage (dot-source to load the functions):
    . D:\Documents\GitHub\flit\tool\desktop\ui_probe.ps1

    Launch -Exe 'D:\flit-verify\ux-before\app\flit.exe' -Env @{FLIT_DESKTOP_HOME='D:\flit-verify\home'}
    WaitWindow -Title 'Flit' -TimeoutSec 60
    Shot -Path 'D:\flit-verify\ux-before\01-projects.png' -Window
    KeyCombo -Modifiers 'Ctrl' -Key 'p'
    ResizeWindow -Width 1200 -Height 800
    CloseApp

  Self-test (launches, screenshots, prints bounds, closes):
    pwsh -File tool\desktop\ui_probe.ps1 -SelfTest

.NOTES
  No Flutter/Dart dependency. Only .NET Framework 4.x assemblies shipped with
  Windows are used: System.Windows.Forms, System.Drawing, UIAutomationClient.
#>
[CmdletBinding()]
param(
  [string]$DefaultExe = 'D:\flit-verify\ux-before\app\flit.exe',
  [string]$DefaultOutDir = 'D:\flit-verify\ux-before',
  [int]$PauseMs = 400,
  [switch]$SelfTest
)

$script:UiProbeVersion = '1.0.0'
$script:AppProcess = $null
$script:AppExePath = $null
$script:AppHwnd = [IntPtr]::Zero
$script:PauseMs = if ($PauseMs -gt 0) { $PauseMs } else { 400 }
$script:DefaultExe = $DefaultExe
$script:DefaultOutDir = $DefaultOutDir
$script:CoordLog = New-Object System.Collections.Generic.List[string]

function Add-TypeSafe {
  param([string]$AssemblyName)
  try { Add-Type -AssemblyName $AssemblyName -ErrorAction Stop; return $true }
  catch { return $false }
}

foreach ($asm in @('System.Windows.Forms', 'System.Drawing', 'UIAutomationClient', 'UIAutomationTypes')) {
  [void](Add-TypeSafe -AssemblyName $asm)
}

if (-not ('UiProbe.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace UiProbe {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public static class Native {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hwnd, int cmd);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    public const uint MouseLeftDown = 0x0002;
    public const uint MouseLeftUp = 0x0004;
    public const uint MouseRightDown = 0x0008;
    public const uint MouseRightUp = 0x0010;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    public const uint WM_CLOSE = 0x0010;
  }
}
'@
}

# Per-monitor-v2 (-4), then the pre-1607 fallback. Must run before UI calls.
$dpiResult = $null
try { $dpiResult = [UiProbe.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $dpiResult = $null }
if ($dpiResult -ne $true) {
  try { [void][UiProbe.Native]::SetProcessDPIAware() } catch { }
}

function Get-UiProbeDpi {
  param([IntPtr]$Hwnd = $script:AppHwnd)
  $dpi = 96
  if ($Hwnd -ne [IntPtr]::Zero) {
    try { $d = [UiProbe.Native]::GetDpiForWindow($Hwnd); if ($d -ge 72 -and $d -le 384) { $dpi = [int]$d } } catch { }
  }
  return $dpi
}

function Get-UiProbeWindowRect {
  param(
    [IntPtr]$Hwnd = $script:AppHwnd,
    [switch]$RawFrame
  )
  if ($Hwnd -eq [IntPtr]::Zero) { throw '[ui_probe] Get-UiProbeWindowRect: no window handle; call WaitWindow first.' }
  $rect = New-Object UiProbe.RECT
  if (-not $RawFrame) {
    $hr = [UiProbe.Native]::DwmGetWindowAttribute($Hwnd, [UiProbe.Native]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$rect, 16)
    if ($hr -ne 0) { $RawFrame = $true }
  }
  if ($RawFrame) {
    if (-not [UiProbe.Native]::GetWindowRect($Hwnd, [ref]$rect)) {
      throw "[ui_probe] GetWindowRect failed for hwnd=$Hwnd (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
  }
  return $rect
}

function ConvertTo-UiProbeBounds {
  param([UiProbe.RECT]$Rect, [int]$Dpi = 96)
  $w = $Rect.Right - $Rect.Left
  $h = $Rect.Bottom - $Rect.Top
  [pscustomobject]@{
    X             = [int]$Rect.Left
    Y             = [int]$Rect.Top
    Width         = [int]$w
    Height        = [int]$h
    LogicalWidth  = [int][Math]::Round($w * 96.0 / $Dpi)
    LogicalHeight = [int][Math]::Round($h * 96.0 / $Dpi)
    Dpi           = [int]$Dpi
  }
}

function Write-UiProbeLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
  $script:CoordLog.Add($line)
  Write-Host $line
}

function Get-UiProbeAppProcess {
  param([string]$Exe)
  $candidates = @()
  if ($Exe) {
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
    $candidates = @(Get-Process -Name $leaf -ErrorAction SilentlyContinue)
    if ($candidates.Count -gt 0 -and $script:AppExePath) {
      $candidates = @($candidates | Where-Object { $_.Path -eq $script:AppExePath })
    }
  } elseif ($script:AppProcess -and -not $script:AppProcess.HasExited) {
    $candidates = @($script:AppProcess)
  }
  if (-not $candidates -or $candidates.Count -eq 0) { return $null }
  return $candidates[0]
}

<#
.SYNOPSIS
  Start the app, or reuse an already running instance of the same exe.
.PARAMETER Exe
  Absolute path to the executable.
.PARAMETER Arguments
  Extra command line arguments (string or array).
.PARAMETER Workdir
  Working directory for the process (defaults to the exe directory).
.PARAMETER Env
  Hashtable of environment variables applied to the child process, e.g.
  @{ FLIT_DESKTOP_HOME = 'D:\flit-verify\home' }. Values of $null remove the var.
.PARAMETER Fresh
  Kill an already running instance of this exe first, then start clean.
.PARAMETER TimeoutSec
  How long to wait for a main window before failing.
#>
function Launch {
  [CmdletBinding()]
  param(
    [string]$Exe = $script:DefaultExe,
    $Arguments,
    [string]$Workdir,
    [hashtable]$Env,
    [int]$TimeoutSec = 60,
    [switch]$Force,
    [switch]$Fresh
  )
  if (-not $Exe) { throw '[ui_probe] Launch: no exe given and no default configured.' }
  if (-not (Test-Path -LiteralPath $Exe)) { throw "[ui_probe] Launch: exe not found: $Exe" }
  $Exe = (Resolve-Path -LiteralPath $Exe).Path
  if (-not $Workdir) { $Workdir = Split-Path -Parent $Exe }
  if (-not (Test-Path -LiteralPath $Workdir)) { throw "[ui_probe] Launch: workdir not found: $Workdir" }

  $existing = Get-UiProbeAppProcess -Exe $Exe
  if ($existing -and -not ($Force -or $Fresh)) {
    $script:AppProcess = $existing
    $script:AppExePath = $Exe
    Write-UiProbeLog "reuse running $([System.IO.Path]::GetFileName($Exe)) pid=$($existing.Id)"
    return $existing
  }
  if ($existing -or $script:AppProcess) { KillApp -Exe $Exe | Out-Null }

  $argList = @()
  if ($Arguments) {
    if ($Arguments -is [array]) { $argList = @($Arguments | ForEach-Object { [string]$_ }) }
    else { $argList = @([string]$Arguments) }
  }

  $restore = @{}
  if ($Env) {
    foreach ($k in $Env.Keys) {
      $restore[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
      [Environment]::SetEnvironmentVariable($k, [string]$Env[$k], 'Process')
    }
  }
  try {
    $startArgs = @{
      FilePath         = $Exe
      WorkingDirectory = $Workdir
      PassThru         = $true
    }
    if ($argList.Count -gt 0) { $startArgs['ArgumentList'] = ($argList -join ' ') }
    $proc = Start-Process @startArgs
  } finally {
    if ($Env) {
      foreach ($k in $restore.Keys) { [Environment]::SetEnvironmentVariable($k, $restore[$k], 'Process') }
    }
  }
  $script:AppProcess = $proc
  $script:AppExePath = $Exe
  Write-UiProbeLog "started $([System.IO.Path]::GetFileName($Exe)) pid=$($proc.Id) workdir=$Workdir"
  if ($TimeoutSec -gt 0) { [void](WaitWindow -TimeoutSec $TimeoutSec) }
  return $proc
}

<#
.SYNOPSIS
  Wait for the app's main window whose title matches (case-insensitive substring).
.PARAMETER Title
  Expected window title (substring match). Empty = accept any main window.
.PARAMETER TimeoutSec
  Seconds to wait; throws on timeout with process/window diagnostics.
#>
function WaitWindow {
  [CmdletBinding()]
  param(
    [string]$Title = 'Flit',
    [int]$TimeoutSec = 30,
    [switch]$Quiet
  )
  $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSec))
  $lastState = 'not started'
  while ((Get-Date) -lt $deadline) {
    $proc = $script:AppProcess
    if (-not $proc -or $proc.HasExited) {
      $proc = Get-UiProbeAppProcess
      if ($proc) { $script:AppProcess = $proc }
    }
    if (-not $proc) { $lastState = 'no app process' }
    elseif ($proc.HasExited) { $lastState = "process exited (code $($proc.ExitCode))" }
    else {
      $proc.Refresh()
      $hwnd = $proc.MainWindowHandle
      $winTitle = $proc.MainWindowTitle
      if ($hwnd -ne [IntPtr]::Zero) {
        if (-not $Title -or $winTitle -like "*$Title*") {
          $script:AppHwnd = $hwnd
          $bounds = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect -Hwnd $hwnd) -Dpi (Get-UiProbeDpi -Hwnd $hwnd)
          if (-not $Quiet) {
            Write-UiProbeLog ("window '$winTitle' hwnd=$hwnd bounds={0}x{1} at ({2},{3}) dpi={4} logical={5}x{6}" -f `
                $bounds.Width, $bounds.Height, $bounds.X, $bounds.Y, $bounds.Dpi, $bounds.LogicalWidth, $bounds.LogicalHeight)
          }
          return [pscustomobject]@{ Hwnd = $hwnd; Title = $winTitle; Bounds = $bounds }
        }
        $lastState = "main window title '$winTitle' does not match '$Title'"
      } else {
        $lastState = 'no main window handle yet'
      }
    }
    Start-Sleep -Milliseconds 250
  }
  $procInfo = if ($proc -and -not $proc.HasExited) { "pid=$($proc.Id) mainTitle='$($proc.MainWindowTitle)'" } else { 'process not running' }
  throw "[ui_probe] WaitWindow: timed out after ${TimeoutSec}s waiting for title like '$Title' ($lastState; $procInfo). Check that the app started, that its window is not minimised, and raise -TimeoutSec."
}

function Get-UiProbeTitle {
  param([IntPtr]$Hwnd = $script:AppHwnd)
  if ($Hwnd -eq [IntPtr]::Zero) { return '' }
  $p = Get-UiProbeAppProcess
  if ($p) { $p.Refresh(); if ($p.MainWindowHandle -eq $Hwnd) { return $p.MainWindowTitle } }
  return ''
}

<#
.SYNOPSIS
  Bring the app window to the foreground (needed before clicks/keys are reliable).
#>
function FocusApp {
  [CmdletBinding()]
  param([IntPtr]$Hwnd = $script:AppHwnd, [int]$Attempts = 5)
  if ($Hwnd -eq [IntPtr]::Zero) { throw '[ui_probe] FocusApp: no window handle; call WaitWindow first.' }
  for ($i = 1; $i -le $Attempts; $i++) {
    if ([UiProbe.Native]::GetForegroundWindow() -eq $Hwnd) { return $true }
    [void][UiProbe.Native]::ShowWindow($Hwnd, 9)  # SW_RESTORE
    [void][UiProbe.Native]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds 150
  }
  if ([UiProbe.Native]::GetForegroundWindow() -ne $Hwnd) {
    throw "[ui_probe] FocusApp: could not bring hwnd=$Hwnd to the foreground after $Attempts attempts (another window may be modal or the desktop is locked)."
  }
  return $true
}

<#
.SYNOPSIS
  Screenshot the whole screen, or one window (default) to a PNG.
.PARAMETER Path
  Absolute output PNG path; parent directory is created.
.PARAMETER Window
  Capture only the app window frame (default: whole virtual screen).
.PARAMETER WindowTitle
  Find the window by title instead of using the tracked app window.
.PARAMETER PrintWindow
  Use PrintWindow(PW_RENDERFULLCONTENT) instead of a screen grab (works for
  occluded windows; may be blank for GPU-composited Flutter surfaces).
#>
function Shot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$FullScreen,
    [string]$WindowTitle,
    [switch]$PrintWindow,
    [switch]$Quiet
  )
  $hwnd = $script:AppHwnd
  if ($WindowTitle) {
    $hwnd = Find-UiProbeWindowByTitle -Title $WindowTitle
    $script:AppHwnd = $hwnd
  }
  if (-not $FullScreen -and $hwnd -eq [IntPtr]::Zero) {
    throw '[ui_probe] Shot: no app window; pass -WindowTitle, call WaitWindow, or use -FullScreen.'
  }

  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $bmp = $null
  $graphics = $null
  try {
    if ($FullScreen) {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $bounds = [pscustomobject]@{ X = $vs.X; Y = $vs.Y; Width = $vs.Width; Height = $vs.Height }
      $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
      $graphics = [System.Drawing.Graphics]::FromImage($bmp)
      $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
    } else {
      $dpi = Get-UiProbeDpi -Hwnd $hwnd
      $bounds = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect -Hwnd $hwnd) -Dpi $dpi
      if ($PrintWindow) {
        [void][UiProbe.Native]::ShowWindow($hwnd, 9)
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $graphics.GetHdc()
        try { [void][UiProbe.Native]::PrintWindow($hwnd, $hdc, 2) } finally { $graphics.ReleaseHdc($hdc) }
      } else {
        [void](FocusApp -Hwnd $hwnd)
        Start-Sleep -Milliseconds 120
        $bounds = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect -Hwnd $hwnd) -Dpi $dpi
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
      }
    }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    if ($graphics) { $graphics.Dispose() }
    if ($bmp) { $bmp.Dispose() }
  }
  if (-not $Quiet) {
    Write-UiProbeLog ("shot {0} ({1}x{2} at {3},{4})" -f $Path, $bounds.Width, $bounds.Height, $bounds.X, $bounds.Y)
  }
  return [pscustomobject]@{ Path = $Path; Bounds = $bounds }
}

function Find-UiProbeWindowByTitle {
  param([string]$Title)
  if (-not $Title) { throw '[ui_probe] Find-UiProbeWindowByTitle: empty title.' }
  $found = @()
  foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
    $p.Refresh()
    if ($p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle -like "*$Title*") {
      $found += [pscustomobject]@{ Hwnd = $p.MainWindowHandle; Title = $p.MainWindowTitle; Process = $p }
    }
  }
  if ($found.Count -eq 0) {
    $titles = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.MainWindowTitle } | Where-Object { $_ })
    throw "[ui_probe] Find-UiProbeWindowByTitle: no visible window title matches '$Title'. Visible titles: $($titles -join ' | ')"
  }
  return $found[0].Hwnd
}

function Move-UiProbeCursor {
  param([int]$X, [int]$Y)
  if (-not [UiProbe.Native]::SetCursorPos($X, $Y)) {
    throw "[ui_probe] SetCursorPos($X,$Y) failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
  }
}

<#
.SYNOPSIS
  Left-click at physical screen pixels, or at the centre of a UIA element (-Name).
.PARAMETER X,Y
  Physical screen coordinates.
.PARAMETER Name
  UIA element name; wins over X/Y when given.
#>
function Click {
  [CmdletBinding()]
  param([int]$X, [int]$Y, [string]$Name, [switch]$NoPause)
  if ($Name) {
    $el = FindByUia -Name $Name
    $X = [int]($el.Bounds.X + $el.Bounds.Width / 2)
    $Y = [int]($el.Bounds.Y + $el.Bounds.Height / 2)
  }
  if ($script:AppHwnd -ne [IntPtr]::Zero) { [void](FocusApp) }
  Move-UiProbeCursor -X $X -Y $Y
  Start-Sleep -Milliseconds 80
  [UiProbe.Native]::mouse_event([UiProbe.Native]::MouseLeftDown, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [UiProbe.Native]::mouse_event([UiProbe.Native]::MouseLeftUp, 0, 0, 0, [IntPtr]::Zero)
  if (-not $NoPause) { Start-Sleep -Milliseconds $script:PauseMs }
  Write-UiProbeLog "click ($X,$Y)$(if ($Name) { " via UIA '$Name'" })"
}

<#
.SYNOPSIS
  Double-left-click at physical screen pixels (or a UIA element centre).
#>
function DoubleClick {
  [CmdletBinding()]
  param([int]$X, [int]$Y, [string]$Name)
  if ($Name) {
    $el = FindByUia -Name $Name
    $X = [int]($el.Bounds.X + $el.Bounds.Width / 2)
    $Y = [int]($el.Bounds.Y + $el.Bounds.Height / 2)
  }
  if ($script:AppHwnd -ne [IntPtr]::Zero) { [void](FocusApp) }
  Move-UiProbeCursor -X $X -Y $Y
  Start-Sleep -Milliseconds 80
  for ($i = 0; $i -lt 2; $i++) {
    [UiProbe.Native]::mouse_event([UiProbe.Native]::MouseLeftDown, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [UiProbe.Native]::mouse_event([UiProbe.Native]::MouseLeftUp, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
  }
  Start-Sleep -Milliseconds $script:PauseMs
  Write-UiProbeLog "double-click ($X,$Y)"
}

<#
.SYNOPSIS
  Left-click at an offset inside the app window's screenshot space.
.PARAMETER X,Y
  Offsets in PHYSICAL pixels from the window frame's top-left corner; the same
  coordinate space as the PNG written by Shot -Window.
#>
function ClickRel {
  [CmdletBinding()]
  param([int]$X, [int]$Y, [switch]$NoPause)
  if ($script:AppHwnd -eq [IntPtr]::Zero) { throw '[ui_probe] ClickRel: no app window; call WaitWindow first.' }
  $dpi = Get-UiProbeDpi
  $b = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect) -Dpi $dpi
  Click -X ($b.X + $X) -Y ($b.Y + $Y) -NoPause:$NoPause
}

<#
.SYNOPSIS
  Right-click at physical screen pixels (or a UIA element centre).
#>
function RightClick {
  [CmdletBinding()]
  param([int]$X, [int]$Y, [string]$Name)
  if ($Name) {
    $el = FindByUia -Name $Name
    $X = [int]($el.Bounds.X + $el.Bounds.Width / 2)
    $Y = [int]($el.Bounds.Y + $el.Bounds.Height / 2)
  }
  if ($script:AppHwnd -ne [IntPtr]::Zero) { [void](FocusApp) }
  Move-UiProbeCursor -X $X -Y $Y
  Start-Sleep -Milliseconds 80
  [UiProbe.Native]::mouse_event([UiProbe.Native]::MouseRightDown, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [UiProbe.Native]::mouse_event([UiProbe.Native]::MouseRightUp, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds $script:PauseMs
  Write-UiProbeLog "right-click ($X,$Y)"
}

<#
.SYNOPSIS
  Scroll the mouse wheel at a point (positive = away from the user).
.PARAMETER Delta
  Wheel delta in 120 units, e.g. -3 scrolls down three notches.
#>
function Wheel {
  [CmdletBinding()]
  param([int]$X, [int]$Y, [int]$Delta = 1, [switch]$NoPause)
  if ($script:AppHwnd -ne [IntPtr]::Zero) { [void](FocusApp) }
  Move-UiProbeCursor -X $X -Y $Y
  Start-Sleep -Milliseconds 60
  [UiProbe.Native]::mouse_event(0x0800, 0, 0, [uint32]($Delta * 120), [IntPtr]::Zero)
  if (-not $NoPause) { Start-Sleep -Milliseconds $script:PauseMs }
  Write-UiProbeLog "wheel $Delta at ($X,$Y)"
}

<#
.SYNOPSIS
  Send a SendKeys sequence to the focused app window.
.PARAMETER Sequence
  SendKeys syntax, e.g. "{ENTER}", "hello", "{TAB}{TAB}", "^s".
#>
function SendKeys {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$Sequence, [int]$DelayMs = 300)
  if ($script:AppHwnd -ne [IntPtr]::Zero) { [void](FocusApp) }
  [System.Windows.Forms.SendKeys]::SendWait($Sequence)
  Start-Sleep -Milliseconds $DelayMs
  Write-UiProbeLog "sendkeys '$Sequence'"
}

<#
.SYNOPSIS
  Send a key combination such as Ctrl+Shift+P.
.PARAMETER Modifiers
  Comma/plus separated: Ctrl, Shift, Alt, Win (aliases Control, Ctl).
.PARAMETER Key
  Single key: letters a-z, digits, F1-F12, Enter, Esc, Tab, Space, arrows, Del.
#>
function KeyCombo {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Modifiers,
    [Parameter(Mandatory = $true)][string]$Key,
    [int]$DelayMs = 500
  )
  $map = @{ 'ctrl' = '^'; 'control' = '^'; 'ctl' = '^'; 'shift' = '+'; 'alt' = '%'; 'win' = '' }
  $prefix = ''
  foreach ($m in ($Modifiers -split '[,+]' | Where-Object { $_.Trim() })) {
    $k = $m.Trim().ToLowerInvariant()
    if (-not $map.ContainsKey($k)) { throw "[ui_probe] KeyCombo: unsupported modifier '$m' (use Ctrl, Shift, Alt)." }
    $prefix += $map[$k]
  }
  $named = @{
    'enter' = '{ENTER}'; 'esc' = '{ESC}'; 'escape' = '{ESC}'; 'tab' = '{TAB}'
    'space' = ' '; 'backspace' = '{BACKSPACE}'; 'del' = '{DELETE}'; 'delete' = '{DELETE}'
    'home' = '{HOME}'; 'end' = '{END}'; 'pageup' = '{PGUP}'; 'pagedown' = '{PGDN}'
    'up' = '{UP}'; 'down' = '{DOWN}'; 'left' = '{LEFT}'; 'right' = '{RIGHT}'
    'insert' = '{INSERT}'; 'plus' = '+'; 'minus' = '-'
  }
  $token = $Key
  $lower = $Key.Trim().ToLowerInvariant()
  if ($named.ContainsKey($lower)) { $token = $named[$lower] }
  elseif ($lower -match '^f([1-9]|1[0-2])$') { $token = '{' + $lower.ToUpperInvariant() + '}' }
  elseif ($Key.Length -ne 1) { throw "[ui_probe] KeyCombo: unsupported key '$Key'." }
  if ($token -in @('+', '^', '%', '~', '(', ')', '{', '}')) { $token = '{' + $token + '}' }
  $seq = $prefix + $token
  if ($script:AppHwnd -ne [IntPtr]::Zero) { [void](FocusApp) }
  [System.Windows.Forms.SendKeys]::SendWait($seq)
  Start-Sleep -Milliseconds $DelayMs
  Write-UiProbeLog "keycombo '$Modifiers+$Key' -> '$seq'"
}

<#
.SYNOPSIS
  Find a UIAutomation element by accessible name inside the app window.
.PARAMETER Name
  Accessible name (exact match preferred, substring fallback).
.PARAMETER TimeoutSec
  Poll the tree until found (Flutter semantics may appear a moment after load).
.PARAMETER IncludeDescendants
  Search the whole subtree (default) instead of direct children.
#>
function FindByUia {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$TimeoutSec = 10,
    [string]$ControlType,
    [switch]$AllowMultiple
  )
  if ($script:AppHwnd -eq [IntPtr]::Zero) { throw '[ui_probe] FindByUia: no app window; call WaitWindow first.' }
  $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSec))
  $lastCount = 0
  $available = @()
  while ((Get-Date) -lt $deadline) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:AppHwnd)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $lastCount = $all.Count
    $available = @()
    $exact = @()
    $partial = @()
    foreach ($el in $all) {
      $n = $el.Current.Name
      if (-not $n) { continue }
      if ($available.Count -lt 60) { $available += $n }
      if ($n -eq $Name) { $exact += $el }
      elseif ($n -like "*$Name*") { $partial += $el }
    }
    $hits = if ($exact.Count -gt 0) { $exact } else { $partial }
    if ($ControlType) { $hits = @($hits | Where-Object { $_.Current.ControlType.ProgrammaticName -like "*$ControlType*" }) }
    if ($hits.Count -gt 0) {
      if ($hits.Count -gt 1 -and -not $AllowMultiple) {
        # Still deterministic: report and take the first (top-left) hit.
        Write-UiProbeLog "FindByUia: '$Name' matched $($hits.Count) elements; using the first."
      }
      $el = $hits[0]
      $r = $el.Current.BoundingRectangle
      if ($r.Width -le 0 -or $r.Height -le 0) { continue }
      return [pscustomobject]@{
        Name        = $el.Current.Name
        ControlType = $el.Current.ControlType.ProgrammaticName
        AutomationId= $el.Current.AutomationId
        Bounds      = [pscustomobject]@{ X = [int]$r.X; Y = [int]$r.Y; Width = [int]$r.Width; Height = [int]$r.Height }
        Element     = $el
      }
    }
    Start-Sleep -Milliseconds 300
  }
  throw "[ui_probe] FindByUia: no element named '$Name' in hwnd=$($script:AppHwnd) after ${TimeoutSec}s (UIA descendants=$lastCount; names seen: $((($available | Select-Object -Unique) -join ' | '))). Flutter exposes UIA only when semantics is enabled; fall back to ClickRel."
}

<#
.SYNOPSIS
  List UIA elements of the app window (diagnostics; Flutter may expose none).
#>
function DumpUia {
  [CmdletBinding()]
  param([int]$MaxDepth = 6, [IntPtr]$Hwnd = $script:AppHwnd)
  if ($Hwnd -eq [IntPtr]::Zero) { throw '[ui_probe] DumpUia: no app window; call WaitWindow first.' }
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add(("ROOT {0} | '{1}'" -f $root.Current.ControlType.ProgrammaticName, $root.Current.Name))
  $script:dumpWalker = $walker
  $script:dumpLines = $lines
  function Walk-UiProbe([System.Windows.Automation.AutomationElement]$el, [int]$depth) {
    if ($depth -gt $MaxDepth) { return }
    $child = $script:dumpWalker.GetFirstChild($el)
    while ($child -ne $null) {
      $r = $child.Current.BoundingRectangle
      $text = '  ' * $depth + ('{0} | {1} | {2},{3} {4}x{5}' -f $child.Current.ControlType.ProgrammaticName, $child.Current.Name, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
      $script:dumpLines.Add($text)
      Walk-UiProbe -el $child -depth ($depth + 1)
      $child = $script:dumpWalker.GetNextSibling($child)
    }
  }
  Walk-UiProbe -el $root -depth 1
  return $script:dumpLines
}

<#
.SYNOPSIS
  Resize the app window.
.PARAMETER Width,Height
  LOGICAL size by default (scaled by window DPI); -Physical sends raw pixels.
.PARAMETER NoVerify
  Skip the post-resize size check (min/max track sizes can clamp the request).
#>
function ResizeWindow {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height,
    [switch]$Physical,
    [switch]$NoActivate,
    [switch]$NoVerify
  )
  if ($script:AppHwnd -eq [IntPtr]::Zero) { throw '[ui_probe] ResizeWindow: no app window; call WaitWindow first.' }
  $dpi = Get-UiProbeDpi
  # SetWindowPos sizes the RAW window rect (GetWindowRect); the DWM visible
  # frame is ~9 px smaller per side, so position and verify against the raw rect.
  $cur = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect -RawFrame) -Dpi $dpi
  if ($Physical) {
    $w = $Width; $h = $Height
  } else {
    $w = [int][Math]::Round($Width * $dpi / 96.0)
    $h = [int][Math]::Round($Height * $dpi / 96.0)
  }
  $flags = [UiProbe.Native]::SWP_NOZORDER
  if ($NoActivate) { $flags = $flags -bor [UiProbe.Native]::SWP_NOACTIVATE }
  if (-not [UiProbe.Native]::SetWindowPos($script:AppHwnd, [IntPtr]::Zero, $cur.X, $cur.Y, $w, $h, $flags)) {
    throw "[ui_probe] ResizeWindow: SetWindowPos($w,$h) failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
  }
  Start-Sleep -Milliseconds 700
  $raw = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect -RawFrame) -Dpi $dpi
  $visible = ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect) -Dpi $dpi
  Write-UiProbeLog ("resize -> raw {0}x{1} / visible {2}x{3} (logical raw {4}x{5}); requested logical {6}x{7}" -f `
      $raw.Width, $raw.Height, $visible.Width, $visible.Height, $raw.LogicalWidth, $raw.LogicalHeight, $Width, $Height)
  if (-not $NoVerify) {
    $dx = [Math]::Abs($raw.Width - $w); $dy = [Math]::Abs($raw.Height - $h)
    if ($dx -gt 2 -or $dy -gt 2) {
      throw ("[ui_probe] ResizeWindow: requested {0}x{1} physical but the raw window rect ended at {2}x{3}; " -f $w, $h, $raw.Width, $raw.Height) +
            'the app probably enforces a minimum/maximum size. Retry with a larger size, or pass -NoVerify to accept the clamp.'
    }
  }
  return $raw
}

<#
.SYNOPSIS
  Read the app window position/size in physical and logical pixels.
#>
function GetWindowBounds {
  [CmdletBinding()]
  param([switch]$RawFrame)
  if ($script:AppHwnd -eq [IntPtr]::Zero) { throw '[ui_probe] GetWindowBounds: no app window; call WaitWindow first.' }
  $dpi = Get-UiProbeDpi
  return ConvertTo-UiProbeBounds -Rect (Get-UiProbeWindowRect -RawFrame:$RawFrame) -Dpi $dpi
}

<#
.SYNOPSIS
  Ask the app to close (WM_CLOSE), like pressing the title-bar X.
.PARAMETER TimeoutSec
  Seconds to wait for exit; returns $false (without force-killing) on timeout.
#>
function CloseApp {
  [CmdletBinding()]
  param([int]$TimeoutSec = 10)
  $proc = $script:AppProcess
  if (-not $proc -or $proc.HasExited) { $proc = Get-UiProbeAppProcess }
  if (-not $proc -or $proc.HasExited) {
    Write-UiProbeLog 'close: app already closed (no-op)'
    $script:AppHwnd = [IntPtr]::Zero
    return $true
  }
  $hwnd = $script:AppHwnd
  if ($hwnd -eq [IntPtr]::Zero) { $proc.Refresh(); $hwnd = $proc.MainWindowHandle }
  if ($hwnd -ne [IntPtr]::Zero) { [void][UiProbe.Native]::PostMessage($hwnd, [UiProbe.Native]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    Write-UiProbeLog "close: app pid=$($proc.Id) still running after ${TimeoutSec}s (a modal dialog may be blocking); use KillApp to force."
    return $false
  }
  Write-UiProbeLog "close: app pid=$($proc.Id) exited code $($proc.ExitCode)"
  $script:AppProcess = $null
  $script:AppHwnd = [IntPtr]::Zero
  return $true
}

<#
.SYNOPSIS
  Force-kill the app (idempotent; also kills child shell/flutter processes it spawned).
#>
function KillApp {
  [CmdletBinding()]
  param([int]$TimeoutSec = 10, [string]$Exe)
  $procs = @()
  $wantedPath = $null
  $candidateExe = if ($Exe) { $Exe } elseif ($script:AppExePath) { $script:AppExePath } else { $null }
  if ($candidateExe) {
    try { $wantedPath = (Resolve-Path -LiteralPath $candidateExe).Path } catch { $wantedPath = $candidateExe }
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($candidateExe)
    $procs = @(Get-Process -Name $leaf -ErrorAction SilentlyContinue)
    $procs = @($procs | Where-Object { try { $_.Path -eq $wantedPath } catch { $false } })
  } elseif ($script:AppProcess -and -not $script:AppProcess.HasExited) {
    $procs = @($script:AppProcess)
  }
  if (-not $procs -or $procs.Count -eq 0) {
    Write-UiProbeLog 'kill: app already closed (no-op)'
    $script:AppProcess = $null
    $script:AppHwnd = [IntPtr]::Zero
    return $true
  }
  foreach ($p in $procs) {
    try { $p.Kill(); Write-UiProbeLog "kill: pid=$($p.Id) terminated" } catch { Write-UiProbeLog "kill: pid=$($p.Id) kill failed: $($_.Exception.Message)" }
  }
  foreach ($p in $procs) { try { [void]$p.WaitForExit($TimeoutSec * 1000) } catch { } }
  $script:AppProcess = $null
  $script:AppHwnd = [IntPtr]::Zero
  return $true
}

function Get-UiProbeInfo {
  [CmdletBinding()]
  param()
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen
  [pscustomobject]@{
    ScriptVersion = $script:UiProbeVersion
    PowerShell    = $PSVersionTable.PSVersion.ToString()
    DpiAware       = ($dpiResult -eq $true)
    Screen        = ('{0}x{1}' -f $screen.Bounds.Width, $screen.Bounds.Height)
    AppExe        = $script:AppExePath
    AppHwnd       = $script:AppHwnd
    ProcessId     = if ($script:AppProcess -and -not $script:AppProcess.HasExited) { $script:AppProcess.Id } else { $null }
    PauseMs       = $script:PauseMs
  }
}

# ------------------------------- self-test ---------------------------------
if ($SelfTest) {
  $out = Join-Path $script:DefaultOutDir 'selftest'
  Write-UiProbeLog "self-test version $script:UiProbeVersion"
  Get-UiProbeInfo | Format-List | Out-String | Write-Host
  Launch -Exe $DefaultExe -Env @{ FLIT_DESKTOP_HOME = $env:FLIT_DESKTOP_HOME } | Out-Null
  $win = WaitWindow -Title 'Flit' -TimeoutSec 60
  $shot = Shot -Path (Join-Path $out 'selftest-window.png')
  $uia = DumpUia -MaxDepth 3
  Write-Host '--- UIA tree ---'
  $uia | ForEach-Object { Write-Host $_ }
  $b = GetWindowBounds
  Write-Host ("--- bounds --- physical {0}x{1} at ({2},{3}); logical {4}x{5}; dpi {6}" -f $b.Width, $b.Height, $b.X, $b.Y, $b.LogicalWidth, $b.LogicalHeight, $b.Dpi)
  CloseApp | Out-Null
  Write-UiProbeLog 'self-test done'
}
