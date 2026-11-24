# ui.ps1 - screen capture + mouse/keyboard control using Win32 APIs only.
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 files without a BOM as ANSI
# and would corrupt any non-ASCII literal.
#
# Usage:
#   .\ui.ps1 shot
#   .\ui.ps1 shot -Region "0,0,1280,720" -Out .\_screen\crop.png
#   .\ui.ps1 windows
#   .\ui.ps1 focus -Title "Notepad"
#   .\ui.ps1 move  -X 800 -Y 500
#   .\ui.ps1 click -X 800 -Y 500
#   .\ui.ps1 click -X 800 -Y 500 -Double
#   .\ui.ps1 click -X 800 -Y 500 -Button right
#   .\ui.ps1 type  -Text "hello world"
#   .\ui.ps1 key   -Keys "ENTER"
#   .\ui.ps1 key   -Keys "CTRL+A"
#   .\ui.ps1 key   -Keys "F5"
#   .\ui.ps1 paste -Text "multi line / unicode text via clipboard"

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('shot', 'move', 'click', 'type', 'key', 'paste', 'windows', 'focus')]
  [string]$Action,

  [int]$X = -1,
  [int]$Y = -1,
  [string]$Text,
  [string]$Keys,
  [string]$Region,
  [string]$Out,
  [string]$Title,
  [ValidateSet('left', 'right', 'middle')][string]$Button = 'left',
  [switch]$Double,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Print UTF-8 so a parent process decodes window titles and paths correctly.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

if (-not ('UiNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class UiNative {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, IntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);

  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT {
    public uint uMsg; public ushort wParamL; public ushort wParamH;
  }
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUT {
    [FieldOffset(0)] public uint type;
    [FieldOffset(8)] public KEYBDINPUT ki;
    [FieldOffset(8)] public MOUSEINPUT mi;
    [FieldOffset(8)] public HARDWAREINPUT hi;
  }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

  public const uint INPUT_KEYBOARD = 1;
  public const uint KEYEVENTF_UNICODE = 0x0004;

  // Type text by Unicode code point. Immune to keyboard layout and to the
  // ASCII-vs-virtual-key trap (ASCII 91 is '[' but VK 0x5B is the Windows key).
  public static int SendUnicode(string text, int delayMs) {
    int sent = 0;
    foreach (char ch in text) {
      var inp = new INPUT[2];
      inp[0].type = INPUT_KEYBOARD;
      inp[0].ki.wVk = 0;
      inp[0].ki.wScan = (ushort)ch;
      inp[0].ki.dwFlags = KEYEVENTF_UNICODE;
      inp[1].type = INPUT_KEYBOARD;
      inp[1].ki.wVk = 0;
      inp[1].ki.wScan = (ushort)ch;
      inp[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      uint r = SendInput(2, inp, Marshal.SizeOf(typeof(INPUT)));
      if (r == 2) sent++;
      if (delayMs > 0) System.Threading.Thread.Sleep(delayMs);
    }
    return sent;
  }
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

  public static string TitleOf(IntPtr h) {
    var sb = new StringBuilder(512);
    GetWindowTextW(h, sb, 512);
    return sb.ToString();
  }

  // Robust foreground switch: Windows blocks SetForegroundWindow from a background
  // process. Pressing ALT releases the foreground lock; AttachThreadInput borrows the
  // foreground thread's input state so the call is honored.
  public static bool ForceForeground(IntPtr hWnd) {
    if (GetForegroundWindow() == hWnd) return true;
    keybd_event(0x12, 0, 0, IntPtr.Zero);
    keybd_event(0x12, 0, KEYEVENTF_KEYUP, IntPtr.Zero);
    ShowWindow(hWnd, 9);
    BringWindowToTop(hWnd);

    uint fgPid;
    uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
    uint myThread = GetCurrentThreadId();
    bool attached = AttachThreadInput(myThread, fgThread, true);
    try {
      SetForegroundWindow(hWnd);
    } finally {
      if (attached) AttachThreadInput(myThread, fgThread, false);
    }
    for (int i = 0; i < 10; i++) {
      if (GetForegroundWindow() == hWnd) return true;
      System.Threading.Thread.Sleep(60);
    }
    return false;
  }

  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

  public const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
  public const uint KEYEVENTF_KEYUP = 0x0002;

  public static List<string> Windows() {
    var list = new List<string>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512);
      GetWindowTextW(h, sb, 512);
      string t = sb.ToString();
      if (t.Length == 0) return true;
      RECT r; GetWindowRect(h, out r);
      uint pid; GetWindowThreadProcessId(h, out pid);
      list.Add(string.Format("{0}\t{1}\t{2},{3},{4},{5}\t{6}", h, pid, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, t));
      return true;
    }, IntPtr.Zero);
    return list;
  }
}
'@
}

function Get-CursorPos {
  $pt = New-Object UiNative+POINT
  [void][UiNative]::GetCursorPos([ref]$pt)
  return $pt
}

# Keystrokes go to whatever window owns the foreground, never to a coordinate.
# Refuse to send anything unless the intended target is provably in front.
function Assert-TargetFocused {
  param([string]$ExpectedTitle, [switch]$AllowAny)
  $fg = [UiNative]::TitleOf([UiNative]::GetForegroundWindow())
  if ($ExpectedTitle) {
    if ($fg -notlike "*$ExpectedTitle*") {
      throw "REFUSING to send keys: foreground is '$fg', expected '$ExpectedTitle'"
    }
    return $fg
  }
  if (-not $AllowAny) {
    throw "REFUSING to send keys: pass -Title '<window>' to verify the target, or -Force to accept '$fg'"
  }
  return $fg
}

function Save-Screen {
  param([string]$Path, [string]$RegionSpec)
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $rx = $vs.X; $ry = $vs.Y; $rw = $vs.Width; $rh = $vs.Height
  if ($RegionSpec) {
    $p = @($RegionSpec.Split(',') | ForEach-Object { [int]$_.Trim() })
    if ($p.Count -ne 4) { throw "Region must be x,y,w,h" }
    $rx = $p[0]; $ry = $p[1]; $rw = $p[2]; $rh = $p[3]
  }
  $bmp = New-Object System.Drawing.Bitmap($rw, $rh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rx, $ry, 0, 0, $bmp.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

[void][UiNative]::SetProcessDPIAware()

switch ($Action) {

  'shot' {
    if (-not $Out) {
      $dir = Join-Path (Get-Location).Path '_screen'
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $Out = Join-Path $dir ("shot-{0}.png" -f (Get-Date -Format 'HHmmss'))
    }
    Save-Screen -Path $Out -RegionSpec $Region
    $kb = [math]::Round((Get-Item $Out).Length / 1KB)
    "OK $Out ($kb KB)"
  }

  'move' {
    if ($X -lt 0 -or $Y -lt 0) { throw "move needs -X and -Y" }
    [void][UiNative]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 60
    $pt = Get-CursorPos
    "OK cursor at X=$($pt.X) Y=$($pt.Y)"
  }

  'click' {
    if ($X -ge 0 -and $Y -ge 0) { [void][UiNative]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 60 }
    $down = switch ($Button) { 'right' { 0x0008 } 'middle' { 0x0020 } default { 0x0002 } }
    $up = switch ($Button) { 'right' { 0x0010 } 'middle' { 0x0040 } default { 0x0004 } }
    $times = 1
    if ($Double) { $times = 2 }
    for ($i = 0; $i -lt $times; $i++) {
      [void][UiNative]::mouse_event($down, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 30
      [void][UiNative]::mouse_event($up, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 60
    }
    $pt = Get-CursorPos
    "OK $Button click x$times at X=$($pt.X) Y=$($pt.Y)"
  }

  'type' {
    if (-not $Text) { throw "type needs -Text" }
    $null = Assert-TargetFocused -ExpectedTitle $Title -AllowAny:$Force
    $sent = [UiNative]::SendUnicode($Text, 15)
    $after = [UiNative]::TitleOf([UiNative]::GetForegroundWindow())
    if ($Title -and ($after -notlike "*$Title*")) {
      throw "FOCUS LOST MID-TYPING: sent $sent chars, foreground switched to '$after'"
    }
    "OK sent $sent/$($Text.Length) chars to '$after'"
  }

  'paste' {
    if (-not $Text) { throw "paste needs -Text" }
    $null = Assert-TargetFocused -ExpectedTitle $Title -AllowAny:$Force
    $prev = Get-Clipboard -Raw -ErrorAction SilentlyContinue
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 80
    $main = 0x56
    [void][UiNative]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
    [void][UiNative]::keybd_event($main, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [void][UiNative]::keybd_event($main, 0, 0x0002, [IntPtr]::Zero)
    [void][UiNative]::keybd_event(0x11, 0, 0x0002, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    if ($null -ne $prev -and $prev -ne '') { Set-Clipboard -Value $prev }
    "OK pasted $($Text.Length) chars via clipboard"
  }

  'key' {
    if (-not $Keys) { throw "key needs -Keys, e.g. ENTER / CTRL+A / F5" }
    $null = Assert-TargetFocused -ExpectedTitle $Title -AllowAny:$Force
    $map = @{
      'ENTER' = 0x0D; 'RETURN' = 0x0D; 'TAB' = 0x09; 'ESC' = 0x1B; 'ESCAPE' = 0x1B; 'SPACE' = 0x20;
      'BACKSPACE' = 0x08; 'DELETE' = 0x2E; 'DEL' = 0x2E; 'HOME' = 0x24; 'END' = 0x23;
      'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27;
      'PGUP' = 0x21; 'PAGEDOWN' = 0x22; 'PGDN' = 0x22; 'INSERT' = 0x2D;
      'F1' = 0x70; 'F2' = 0x71; 'F3' = 0x72; 'F4' = 0x73; 'F5' = 0x74; 'F6' = 0x75;
      'F7' = 0x76; 'F8' = 0x77; 'F9' = 0x78; 'F10' = 0x79; 'F11' = 0x7A; 'F12' = 0x7B
    }
    $mods = @{ 'CTRL' = 0x11; 'SHIFT' = 0x10; 'ALT' = 0x12; 'WIN' = 0x5B }
    $parts = @($Keys.Split('+') | ForEach-Object { $_.Trim() })
    $mainKey = $parts[$parts.Count - 1].ToUpperInvariant()
    $held = @()
    if ($parts.Count -gt 1) {
      for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $mk = $parts[$i].ToUpperInvariant()
        if (-not $mods.ContainsKey($mk)) { throw "unknown modifier: $mk" }
        $held += [byte]$mods[$mk]
        [void][UiNative]::keybd_event([byte]$mods[$mk], 0, 0, [IntPtr]::Zero)
      }
    }
    if ($mainKey.Length -eq 1) { $vk = [byte][int][char]$mainKey }
    elseif ($map.ContainsKey($mainKey)) { $vk = [byte]$map[$mainKey] }
    else { throw "unknown key: $mainKey" }
    [void][UiNative]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [void][UiNative]::keybd_event($vk, 0, 0x0002, [IntPtr]::Zero)
    for ($i = $held.Count - 1; $i -ge 0; $i--) { [void][UiNative]::keybd_event($held[$i], 0, 0x0002, [IntPtr]::Zero) }
    "OK key $Keys"
  }

  'windows' {
    $rows = [UiNative]::Windows()
    "HWND`tPID`tRECT`tTITLE"
    foreach ($r in $rows) { $r }
    "total $($rows.Count) visible windows"
  }

  'focus' {
    if (-not $Title) { throw "focus needs -Title" }
    $match = @([UiNative]::Windows() | Where-Object { $_ -like "*$Title*" }) | Select-Object -First 1
    if (-not $match) { throw "no window title matching '$Title'" }
    $fields = $match.Split("`t")
    $hwnd = [IntPtr][long]$fields[0]
    $ok = [UiNative]::ForceForeground($hwnd)
    $fgTitle = [UiNative]::TitleOf([UiNative]::GetForegroundWindow())
    if (-not $ok) { throw "FOREGROUND FAILED hwnd=$hwnd still-front=$fgTitle" }
    "OK hwnd=$hwnd foreground=True title=$($fields[3])"
  }
}