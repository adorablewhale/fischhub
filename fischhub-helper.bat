<# : FischHub helper - keep this window open while you play (webhook editing, dashboard, alerts)
@echo off
setlocal
title FischHub helper
set "FH_SELF=%~f0"
set "FH_ARG=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:FH_SELF))"
echo.
pause
exit /b
#>
# ---------------------------------------------------------------- PowerShell part
# Everything FischHub needs outside Matcha, in one window. It listens on 127.0.0.1:47210 (this PC
# only) and does five things:
#  1. Webhook relay. Discord only edits a webhook message with PATCH, and Matcha can only send
#     GET/POST, so FischHub posts edits here and this sends the PATCH. With ?shot=1 it attaches a
#     screenshot of the Roblox window (only Roblox, never another window). It forwards nothing
#     but /api/webhooks/<id>/<token>[/messages/<id>], and only to discord.com.
#  2. Dashboard. http://127.0.0.1:47210 shows live stats and every catch, from the files FischHub
#     writes in the Matcha workspace: FischHub\dashboard\state.json (every 2 s),
#     FischHub\dashboard\catches.txt (one JSON line per catch) and FischHub\fishinfo.json.
#  3. Disconnect watchdog. FischHub posts to Discord itself when Roblox shows its disconnect
#     prompt. If Roblox or Matcha closes or crashes while farming, the script can't, so this
#     notices state.json going quiet for 2 minutes and posts that alert (webhook, ping and
#     on/off come from FischHub\settings.json).
#  4. AFK helper (off by default; switch it on in the page). When FischHub reports Roblox idle
#     and NOT focused (its own anti-AFK keys can't reach it), this briefly brings Roblox to the
#     front, taps O then I (camera zoom out/in) and gives focus back - only after you've been off
#     the keyboard and mouse for 3 s, at most once a minute, never while Roblox is minimized.
#  5. Settings and a live view from the page. A change made on the page is written to
#     FischHub\dashboard\commands.txt and FischHub applies it like a click in its menu. The Roblox
#     view on the page is a picture of the Roblox window only (see the screenshot note below).
#     Both need the page's key, which is new every time this window starts, so another website
#     open in your browser can't change settings or take pictures.
# Webhook URLs and tokens are never printed. Drag your Matcha workspace folder onto this file if
# it isn't C:\matcha\workspace.

$ErrorActionPreference = 'Stop'
$Port = 47210
$StallSec = 120
$Workspace = 'C:\matcha\workspace'
if ($env:FH_ARG) {
  $a = $env:FH_ARG.TrimEnd('\')
  if (Test-Path -LiteralPath (Join-Path $a 'FischHub')) { $Workspace = $a }
  elseif ((Split-Path $a -Leaf) -eq 'FischHub') { $Workspace = Split-Path $a }
}
$Dir = Join-Path $Workspace 'FischHub'
$StateFile = Join-Path $Dir 'dashboard\state.json'
$CatchFile = Join-Path $Dir 'dashboard\catches.txt'
$InfoFile = Join-Path $Dir 'fishinfo.json'
$SettingsFile = Join-Path $Dir 'settings.json'
$HelperFile = Join-Path $Dir 'dashboard\afk-helper.txt'
$CmdFile = Join-Path $Dir 'dashboard\commands.txt'
$CtlFile = Join-Path $Dir 'dashboard\controls.json'
$Token = [Guid]::NewGuid().ToString('N')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FHWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  public static uint IdleMs() {
    LII i = new LII();
    i.cbSize = (uint)Marshal.SizeOf(typeof(LII));
    if (!GetLastInputInfo(ref i)) return 0;
    return unchecked((uint)Environment.TickCount - i.dwTime);
  }
  public static bool Focus(IntPtr h) {
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return true;
    uint me = GetCurrentThreadId();
    uint them = GetWindowThreadProcessId(fg, IntPtr.Zero);
    AttachThreadInput(me, them, true);
    bool ok = SetForegroundWindow(h);
    AttachThreadInput(me, them, false);
    return ok;
  }
  public static void Tap(byte vk) {
    byte scan = (byte)MapVirtualKey(vk, 0);
    keybd_event(vk, scan, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(50);
    keybd_event(vk, scan, 2, UIntPtr.Zero);
  }
}
'@

# Screenshots of the Roblox window, and nothing else. PrintWindow with PW_RENDERFULLCONTENT asks
# Windows for Roblox's own picture (client area only), which works even behind other windows and
# never includes them. Only if that comes back black is the screen copied, and only when Roblox is
# the window in front AND no other window (an overlay, a popup, a notification) overlaps it.
$script:CanShot = $false
try {
  Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
public static class FHShot {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
  public static string Why = "";
  // True when a visible window of another program sits above Roblox over the given screen area.
  static bool Covered(IntPtr h, int l, int t, int r, int b) {
    uint mine; GetWindowThreadProcessId(h, out mine);
    for (IntPtr w = GetWindow(h, 3); w != IntPtr.Zero; w = GetWindow(w, 3)) { // 3 = GW_HWNDPREV, the next window up
      if (!IsWindowVisible(w)) continue;
      int cloaked = 0;
      if (DwmGetWindowAttribute(w, 14, out cloaked, 4) == 0 && cloaked != 0) continue; // 14 = DWMWA_CLOAKED
      uint pid; GetWindowThreadProcessId(w, out pid);
      if (pid == mine) continue;
      RECT x;
      if (!GetWindowRect(w, out x)) continue;
      if (x.R <= l || x.L >= r || x.B <= t || x.T >= b) continue;
      return true;
    }
    return false;
  }
  static bool Blank(Bitmap b) {
    for (int y = 1; y < 10; y++) for (int x = 1; x < 10; x++) {
      Color c = b.GetPixel(b.Width * x / 10, b.Height * y / 10);
      if (c.R > 8 || c.G > 8 || c.B > 8) return false;
    }
    return true;
  }
  public static byte[] Capture(IntPtr h, int maxWidth) {
    Why = "";
    if (IsIconic(h)) { Why = "Roblox is minimized"; return null; }
    RECT r;
    if (!GetClientRect(h, out r)) { Why = "no Roblox window"; return null; }
    int w = r.R - r.L, ht = r.B - r.T;
    if (w < 64 || ht < 64) { Why = "Roblox window too small"; return null; }
    Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb);
    Bitmap small = null;
    try {
      using (Graphics g = Graphics.FromImage(bmp)) {
        IntPtr dc = g.GetHdc();
        bool ok = PrintWindow(h, dc, 3); // PW_CLIENTONLY | PW_RENDERFULLCONTENT
        g.ReleaseHdc(dc);
        if (!ok || Blank(bmp)) {
          if (GetForegroundWindow() != h) { Why = "Roblox came back black and isn't the window in front, so nothing was captured"; return null; }
          POINT p = new POINT();
          ClientToScreen(h, ref p);
          if (Covered(h, p.X, p.Y, p.X + w, p.Y + ht)) { Why = "another window is over Roblox, so nothing was captured"; return null; }
          g.CopyFromScreen(p.X, p.Y, 0, 0, new Size(w, ht));
        }
      }
      Bitmap outBmp = bmp;
      if (w > maxWidth) { small = new Bitmap(bmp, new Size(maxWidth, (int)((long)ht * maxWidth / w))); outBmp = small; }
      ImageCodecInfo jpg = null;
      foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) { if (c.MimeType == "image/jpeg") jpg = c; }
      EncoderParameters ep = new EncoderParameters(1);
      ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 82L);
      using (MemoryStream ms = new MemoryStream()) { outBmp.Save(ms, jpg, ep); return ms.ToArray(); }
    } catch (Exception e) { Why = e.Message; return null; }
    finally { bmp.Dispose(); if (small != null) small.Dispose(); }
  }
}
'@
  [void][FHWin]::SetProcessDPIAware()
  $script:CanShot = $true
} catch { }
$script:ShotWhy = ''
$script:LiveShot = $null
$script:LiveShotAt = [DateTime]::MinValue
$script:ShotNote = if ($script:CanShot) { 'ready (turn on "Screenshot in webhook" in FischHub)' } else { 'not available on this PC' }

$Html = @'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FischHub</title>
<style>
:root {
  color-scheme: dark;
  --page: #0d0d0d; --surface: #1a1a19; --raised: #242423; --ink: #ffffff; --ink2: #c3c2b7; --muted: #898781;
  --grid: #2c2c2a; --base: #383835; --border: rgba(255,255,255,.10); --s1: #3987e5; --s2: #d95926;
  --good: #0ca30c; --warn: #fab219; --serious: #ec835a; --crit: #d03b3b;
  --shadow: 0 8px 28px rgba(0,0,0,.45);
}
:root[data-theme="light"] {
  color-scheme: light;
  --page: #f9f9f7; --surface: #fcfcfb; --raised: #f0efea; --ink: #0b0b0b; --ink2: #52514e; --muted: #6f6e69;
  --grid: #e1e0d9; --base: #c3c2b7; --border: rgba(11,11,11,.10); --s1: #2a78d6; --s2: #eb6834;
  --shadow: 0 8px 28px rgba(11,11,11,.12);
}
* { box-sizing: border-box; }
html { scroll-padding-top: 76px; }
body { margin: 0; background: var(--page); color: var(--ink);
  font: 14px/1.5 "Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, Roboto, sans-serif; -webkit-font-smoothing: antialiased; }
.num { font-variant-numeric: tabular-nums; }
.muted { color: var(--muted); }
.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
button { font: inherit; color: inherit; }

/* header */
.top { position: sticky; top: 0; z-index: 20; background: color-mix(in srgb, var(--page) 86%, transparent);
  -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px); border-bottom: 1px solid var(--border); }
.bar { max-width: 1440px; margin: 0 auto; padding: 10px 24px; display: flex; align-items: center; gap: 10px 18px; flex-wrap: wrap; }
.brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 16px; letter-spacing: -.01em; }
.logo { width: 28px; height: 28px; border-radius: 8px; background: var(--s1); display: grid; place-items: center; flex: none; }
.logo svg { width: 18px; height: 18px; }
.who { color: var(--muted); font-size: 13px; font-weight: 400; }
.live { display: inline-flex; align-items: center; gap: 7px; font-size: 12px; padding: 3px 11px 3px 9px; border: 1px solid var(--border);
  border-radius: 999px; color: var(--ink2); white-space: nowrap; }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex: none; }
.live[data-s="live"] .dot { background: var(--good); box-shadow: 0 0 0 3px color-mix(in srgb, var(--good) 28%, transparent); }
.live[data-s="stale"] .dot { background: var(--warn); }
.live[data-s="dead"] .dot { background: var(--crit); }
.phase { color: var(--ink2); font-size: 13px; flex: 1 1 180px; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
nav { display: flex; gap: 2px; align-items: center; }
nav a, .iconbtn { color: var(--ink2); text-decoration: none; font-size: 13px; padding: 5px 10px; border-radius: 8px; border: 0; background: none; cursor: pointer; }
nav a:hover, .iconbtn:hover { background: var(--raised); color: var(--ink); }
.iconbtn { display: grid; place-items: center; width: 32px; height: 32px; padding: 0; }
.iconbtn svg { width: 17px; height: 17px; }

/* layout */
main { max-width: 1440px; margin: 0 auto; padding: 20px 24px 56px; }
.block { margin-bottom: 36px; }
.sechead { display: flex; align-items: baseline; justify-content: space-between; gap: 6px 16px; flex-wrap: wrap; margin: 0 0 12px; }
.sechead h2 { font-size: 17px; margin: 0; font-weight: 650; letter-spacing: -.01em; }
.sechead .sub { color: var(--muted); font-size: 12px; }
.grid { display: grid; gap: 16px; grid-template-columns: repeat(12, minmax(0, 1fr)); }
.c12 { grid-column: span 12; } .c8 { grid-column: span 8; } .c6 { grid-column: span 6; } .c4 { grid-column: span 4; }
.stack { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
@media (max-width: 1100px) { .c8, .c4 { grid-column: span 12; } .stack.c4 { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); } }
@media (max-width: 860px) { .c6 { grid-column: span 12; } }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px; min-width: 0; }
.card h3 { margin: 0 0 12px; font-size: 13px; font-weight: 600; color: var(--ink); display: flex; justify-content: space-between;
  align-items: baseline; gap: 4px 10px; flex-wrap: wrap; }
.card h3 .aside { font-weight: 400; color: var(--muted); font-size: 12px; }

/* banner */
.banner { display: none; margin-bottom: 16px; border-radius: 12px; padding: 12px 16px; border: 1px solid var(--border); background: var(--surface);
  gap: 12px; align-items: flex-start; }
.banner.on { display: flex; }
.banner .ic { width: 22px; height: 22px; border-radius: 50%; display: grid; place-items: center; font-weight: 700; font-size: 13px; color: #fff; flex: none; background: var(--muted); }
.banner.crit { border-color: color-mix(in srgb, var(--crit) 55%, transparent); }
.banner.crit .ic { background: var(--crit); }
.banner.warn .ic { background: var(--warn); color: #0b0b0b; }
.banner b { display: block; }
.banner .d { color: var(--ink2); font-size: 13px; overflow-wrap: anywhere; }

/* hero */
.hero { display: grid; grid-template-columns: minmax(230px, 300px) minmax(0, 1fr); gap: 8px 28px; padding: 20px 22px; }
.eyebrow { color: var(--ink2); font-size: 13px; font-weight: 600; }
.big { font-size: 64px; line-height: 1.05; font-weight: 700; letter-spacing: -.035em; margin: 6px 0 14px; }
.kv { display: flex; justify-content: space-between; gap: 12px; padding: 6px 0; border-top: 1px solid var(--grid); font-size: 13px; }
.kv span { color: var(--ink2); }
.kv b { font-weight: 600; font-variant-numeric: tabular-nums; }
.hero .chart { height: 236px; }
@media (max-width: 760px) { .hero { grid-template-columns: minmax(0, 1fr); } .big { font-size: 52px; } .hero .chart { height: 200px; } }

/* tiles */
.tiles { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); margin: 16px 0; }
.tile .k { color: var(--ink2); font-size: 13px; font-weight: 600; }
.tile .v { font-size: 26px; font-weight: 650; letter-spacing: -.02em; margin: 4px 0 2px; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.tile .f { color: var(--muted); font-size: 12px; }

/* highlight cards */
.hls { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); margin-bottom: 16px; }
.hl .k { color: var(--ink2); font-size: 13px; font-weight: 600; display: flex; align-items: center; gap: 8px; }
.hl .v { font-size: 22px; font-weight: 650; letter-spacing: -.015em; margin: 6px 0 4px; overflow-wrap: anywhere; }
.hl .s { color: var(--ink2); font-size: 13px; overflow-wrap: anywhere; }
.pulse { width: 8px; height: 8px; border-radius: 50%; background: var(--s1); animation: pulse 1.4s ease-in-out infinite; }
@keyframes pulse { 50% { opacity: .25; } }
@media (prefers-reduced-motion: reduce) { .pulse { animation: none; } }

/* charts */
.chart { position: relative; height: 210px; touch-action: pan-y; }
.chart svg { display: block; width: 100%; height: 100%; overflow: visible; }
.chart .ax { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
.chart .gl { stroke: var(--grid); stroke-width: 1; }
.chart .bl { stroke: var(--base); stroke-width: 1; }
.chart .cross { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 3 3; }
.chart-empty { height: 100%; display: grid; place-items: center; color: var(--muted); font-size: 13px; text-align: center; padding: 0 12px;
  border: 1px dashed var(--grid); border-radius: 10px; }
details.twin { margin-top: 8px; }
details.twin summary, details.logbox summary { cursor: pointer; color: var(--muted); font-size: 12px; width: max-content; }
details.twin summary:hover, details.logbox summary:hover { color: var(--ink); }
.twin .wrap { max-height: 240px; overflow: auto; margin-top: 8px; }

/* tooltip */
.tip { position: fixed; z-index: 50; pointer-events: none; background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
  box-shadow: var(--shadow); padding: 8px 10px; font-size: 12px; min-width: 120px; max-width: 280px; display: none; }
.tip .t { color: var(--muted); margin-bottom: 4px; }
.tip .r { display: flex; align-items: center; gap: 8px; justify-content: space-between; }
.tip .r span { display: flex; align-items: center; gap: 6px; color: var(--ink2); overflow-wrap: anywhere; }
.tip .r b { font-variant-numeric: tabular-nums; }
.sw { width: 10px; height: 10px; border-radius: 3px; flex: none; }

/* tables */
.tablewrap { overflow-x: auto; }
.tablewrap.scroll { max-height: 640px; overflow: auto; }
.tablecard { display: flex; flex-direction: column; }
.tablecard .tablewrap.scroll { flex: 1 1 auto; min-height: 420px; max-height: none; contain: size; }
@media (max-width: 1100px) { .tablecard .tablewrap.scroll { contain: none; min-height: 0; max-height: 600px; } }
.tablewrap.scroll thead th { position: sticky; top: 0; background: var(--surface); z-index: 1; }
.charthead { display: flex; justify-content: space-between; align-items: center; gap: 8px; margin-bottom: 6px; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th { text-align: left; font-weight: 500; font-size: 12px; color: var(--muted); padding: 0 10px 8px 0; border-bottom: 1px solid var(--base); white-space: nowrap; }
td { padding: 7px 10px 7px 0; border-bottom: 1px solid var(--grid); vertical-align: middle; white-space: nowrap; }
tbody tr:hover td { background: color-mix(in srgb, var(--raised) 60%, transparent); }
th.r, td.r { text-align: right; }
th.where, td.where { padding-left: 18px; }
td.fish { white-space: normal; min-width: 180px; }
td.t { color: var(--muted); }
td.mut { color: var(--ink2); }
td.odds { color: var(--muted); }
td.odds.hi { color: var(--ink); font-weight: 600; }
.size { color: var(--muted); }
.fname { font-weight: 600; }
.chip { display: inline-block; font-size: 11px; line-height: 16px; padding: 0 6px; margin-left: 6px; border: 1px solid var(--border); border-radius: 5px;
  color: var(--ink2); white-space: nowrap; vertical-align: 1px; }
.chip.fx { border-color: color-mix(in srgb, var(--ink2) 45%, transparent); color: var(--ink); }
.rar { display: inline-flex; align-items: center; gap: 7px; }
.rar i { width: 9px; height: 9px; border-radius: 50%; flex: none; box-shadow: 0 0 0 1px var(--border); }
.empty { color: var(--muted); padding: 14px 0; text-align: center; }
.more { margin-top: 10px; background: var(--raised); border: 1px solid var(--border); border-radius: 8px; padding: 6px 14px; cursor: pointer; font-size: 13px; }
.more:hover { border-color: var(--base); }
.tablecard .more { align-self: flex-start; }
.show-sm { display: none; }
.rdot { width: 8px; height: 8px; border-radius: 50%; margin-right: 7px; vertical-align: 1px; box-shadow: 0 0 0 1px var(--border); }
@media (max-width: 640px) { .hide-sm { display: none; } .show-sm { display: inline-block; }
  td.fish { min-width: 0; } th, td { padding-right: 8px; } table { font-size: 13px; } }

/* filter chips */
.seg { display: flex; flex-wrap: wrap; gap: 6px; }
.seg button { border: 1px solid var(--border); background: none; border-radius: 999px; padding: 3px 11px; font-size: 12px; color: var(--ink2); cursor: pointer; }
.seg button:hover { color: var(--ink); border-color: var(--base); }
.seg button[aria-pressed="true"] { background: var(--ink); color: var(--page); border-color: var(--ink); }
.seg button .n { opacity: .7; margin-left: 4px; font-variant-numeric: tabular-nums; }

/* bars */
.bars { display: flex; flex-direction: column; gap: 2px; }
.brow { display: grid; grid-template-columns: minmax(90px, 42%) minmax(0, 1fr) auto; align-items: center; gap: 10px; padding: 4px 4px; border-radius: 6px; }
.brow:hover, .brow:focus { background: var(--raised); outline: none; }
.blab { display: flex; align-items: center; gap: 7px; min-width: 0; font-size: 13px; }
.blab span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.blab i { width: 9px; height: 9px; border-radius: 50%; flex: none; box-shadow: 0 0 0 1px var(--border); }
.btrack { height: 10px; border-left: 1px solid var(--base); }
.bfill { height: 100%; background: var(--s1); border-radius: 0 4px 4px 0; min-width: 2px; }
.bval { font-size: 13px; font-variant-numeric: tabular-nums; color: var(--ink); min-width: 28px; text-align: right; }
.bnote { color: var(--muted); font-size: 12px; margin-top: 6px; padding-left: 4px; }

/* roblox view */
.shotbox { position: relative; aspect-ratio: 16 / 9; background: var(--page); border: 1px solid var(--border); border-radius: 10px; overflow: hidden;
  display: grid; place-items: center; }
.shotbox img { width: 100%; height: 100%; object-fit: contain; display: block; cursor: zoom-in; }
.shotbox:fullscreen { border: 0; border-radius: 0; background: #000; }
.shotbox:fullscreen img { cursor: zoom-out; }
.shot-empty { color: var(--muted); font-size: 13px; text-align: center; padding: 0 24px; max-width: 460px; }
.shotbar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; margin-top: 10px; }
.shotbar .muted { font-size: 12px; flex: 1 1 220px; }
.btn { background: var(--raised); border: 1px solid var(--border); border-radius: 8px; padding: 5px 12px; cursor: pointer; font-size: 13px; color: var(--ink); }
.btn:hover:not(:disabled) { border-color: var(--base); }
.btn:disabled { opacity: .5; cursor: default; }
.btn.primary { background: var(--ink); color: var(--page); border-color: var(--ink); }

/* settings */
.ctl { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 6px 16px; align-items: center; padding: 11px 0; border-top: 1px solid var(--grid); }
.card h3 + .ctl { border-top: 0; padding-top: 2px; }
.ctl-t b { display: block; font-weight: 600; font-size: 13px; }
.ctl-t span { display: block; color: var(--muted); font-size: 12px; }
.ctl-c { display: flex; align-items: center; gap: 8px; justify-content: flex-end; }
.ctl.busy .ctl-c { opacity: .55; }
.ctl input[type=range] { width: 170px; accent-color: var(--s1); }
.ctl output { min-width: 70px; text-align: right; font-variant-numeric: tabular-nums; font-size: 13px; }
.ctl input[type=text], .ctl input[type=password] { width: 220px; max-width: 100%; background: var(--page); color: var(--ink); border: 1px solid var(--border);
  border-radius: 8px; padding: 5px 9px; font: inherit; font-size: 13px; }
.ctl input[type=text]:focus, .ctl input[type=password]:focus { outline: 2px solid var(--s1); outline-offset: 0; border-color: transparent; }
.ctl .state { font-size: 12px; color: var(--muted); }
.actions { display: flex; flex-wrap: wrap; gap: 8px; padding-top: 12px; border-top: 1px solid var(--grid); }
.switch { position: relative; display: inline-flex; cursor: pointer; }
.switch input { position: absolute; opacity: 0; width: 1px; height: 1px; }
.switch .knob, .toggle .knob { width: 36px; height: 20px; border-radius: 999px; background: var(--base); position: relative; flex: none; transition: background .15s; }
.switch .knob::after, .toggle .knob::after { content: ""; position: absolute; top: 2px; left: 2px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform .15s; }
.switch input:checked + .knob, .toggle input:checked + .knob { background: var(--s1); }
.switch input:checked + .knob::after, .toggle input:checked + .knob::after { transform: translateX(16px); }
.switch input:focus-visible + .knob, .toggle input:focus-visible + .knob { outline: 2px solid var(--s1); outline-offset: 2px; }
.switch input:disabled + .knob { opacity: .45; cursor: default; }
.quick { display: grid; gap: 8px; margin-top: 14px; }
.quick .q { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 9px 12px; background: var(--raised); border-radius: 10px; }
.quick .q b { font-weight: 600; font-size: 13px; }
.quick .q.busy { opacity: .6; }
.setnote { margin-bottom: 16px; }
@media (max-width: 640px) {
  .ctl { grid-template-columns: minmax(0, 1fr); }
  .ctl.k-toggle { grid-template-columns: minmax(0, 1fr) auto; }
  .ctl-c { justify-content: flex-start; flex-wrap: wrap; }
  .ctl input[type=range] { flex: 1 1 140px; width: auto; }
}

/* toast */
.toasts { position: fixed; right: 16px; bottom: 16px; z-index: 60; display: flex; flex-direction: column; gap: 8px; align-items: flex-end; pointer-events: none; }
.toast { background: var(--surface); border: 1px solid var(--border); border-left: 3px solid var(--good); border-radius: 8px; box-shadow: var(--shadow);
  padding: 9px 12px; font-size: 13px; max-width: min(380px, calc(100vw - 32px)); overflow-wrap: anywhere; }
.toast.err { border-left-color: var(--crit); }

/* status */
dl.st { display: grid; grid-template-columns: minmax(110px, auto) minmax(0, 1fr); gap: 0; margin: 0; }
dl.st dt, dl.st dd { padding: 7px 0; border-top: 1px solid var(--grid); }
dl.st dt { color: var(--muted); padding-right: 14px; font-size: 13px; }
dl.st dd { margin: 0; overflow-wrap: anywhere; white-space: pre-line; font-size: 13px; }
dl.st dt:first-of-type, dl.st dt:first-of-type + dd { border-top: 0; }
.toggle { display: flex; gap: 12px; align-items: flex-start; cursor: pointer; padding: 4px 0 12px; }
.toggle input { position: absolute; opacity: 0; width: 1px; height: 1px; }
.toggle .knob { margin-top: 1px; }
.toggle .tx b { display: block; font-weight: 600; }
.toggle .tx span { color: var(--muted); font-size: 12px; }
pre.log { margin: 10px 0 0; font: 12px/1.55 ui-monospace, "Cascadia Mono", Consolas, monospace; white-space: pre-wrap; overflow-wrap: anywhere;
  max-height: 420px; overflow: auto; color: var(--ink2); }
@media (max-width: 640px) {
  .bar, main { padding-left: 16px; padding-right: 16px; }
  .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .tile .v { font-size: 21px; }
  .hls { gap: 12px; }
  .phase { order: 5; flex-basis: 100%; }
  nav a { padding: 5px 8px; }
  .card { padding: 14px; }
}
</style>
</head>
<body>
<header class="top">
  <div class="bar">
    <div class="brand">
      <span class="logo" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M2.5 12c3-4.5 8.5-6.5 13-3.5L21 5v14l-5.5-3.5c-4.5 3-10 1-13-3.5z"/><circle cx="8" cy="11" r=".6" fill="#fff"/></svg></span>
      FischHub <span class="who" id="who"></span>
    </div>
    <span class="live" id="live" data-s="dead"><span class="dot"></span><span id="live-t">connecting</span></span>
    <span class="phase" id="phase"></span>
    <nav aria-label="Sections">
      <a href="#session">Session</a><a href="#settings">Settings</a><a href="#alltime">All time</a><a href="#status">Status</a>
      <button class="iconbtn" id="theme" type="button" title="Switch theme" aria-label="Switch theme">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>
      </button>
    </nav>
  </div>
</header>
<main>
  <div class="banner" id="banner" role="status"><span class="ic" id="banner-i">!</span><div><b id="banner-t"></b><div class="d" id="banner-d"></div></div></div>

  <section class="block" id="session">
    <div class="card hero">
      <div>
        <div class="eyebrow">Fish this session</div>
        <div class="big num" id="h-fish">-</div>
        <div id="h-kv"></div>
        <div class="quick" id="quick"></div>
      </div>
      <div>
        <div class="charthead"><span class="muted" id="ch-fish-l">Total over time</span>
          <div class="seg" id="hero-mode" role="group" aria-label="Chart"><button type="button" data-m="total" aria-pressed="true">Total</button><button type="button" data-m="rate" aria-pressed="false">Per hour</button></div></div>
        <div class="chart" id="ch-fish" role="img" aria-label="Fish caught over this session"></div>
        <details class="twin" id="tw-fish"><summary>Show data</summary><div class="wrap"></div></details>
      </div>
    </div>

    <div class="tiles">
      <div class="card tile"><div class="k">C$ gained</div><div class="v" id="t-coins">-</div><div class="f" id="t-coins-f"></div></div>
      <div class="card tile"><div class="k">XP gained</div><div class="v" id="t-xp">-</div><div class="f" id="t-xp-f"></div></div>
      <div class="card tile"><div class="k">Farming</div><div class="v" id="t-farm">-</div><div class="f" id="t-farm-f"></div></div>
      <div class="card tile"><div class="k">Mutated</div><div class="v" id="t-mut">-</div><div class="f" id="t-mut-f"></div></div>
      <div class="card tile"><div class="k">Instant catch</div><div class="v" id="t-ic">-</div><div class="f" id="t-ic-f"></div></div>
    </div>

    <div class="grid" style="margin-bottom:16px">
      <div class="card c8">
        <h3>Roblox <span class="aside" id="shot-aside"></span></h3>
        <div class="shotbox" id="shot-box"><img id="shot-img" alt="Your Roblox window" hidden><div class="shot-empty" id="shot-empty">Loading a picture of your Roblox window&hellip;</div></div>
        <div class="shotbar">
          <div class="seg" id="shot-mode" role="group" aria-label="Roblox view"><button type="button" data-m="live" aria-pressed="true">Live</button><button type="button" data-m="paused" aria-pressed="false">Paused</button></div>
          <button class="btn" type="button" id="shot-refresh">Refresh</button>
          <button class="btn" type="button" id="shot-full">Full screen</button>
          <span class="muted">Only the Roblox window is captured, straight from Windows. Other windows on your screen never are.</span>
        </div>
      </div>
      <div class="stack c4">
        <div class="card hl"><div class="k"><span class="pulse" id="reel-dot" hidden></span>On the line</div><div class="v" id="hl-reel">-</div><div class="s" id="hl-reel-s"></div></div>
        <div class="card hl"><div class="k">Rarest this session</div><div class="v num" id="hl-rare">-</div><div class="s" id="hl-rare-s"></div></div>
        <div class="card hl"><div class="k">Heaviest this session</div><div class="v num" id="hl-heavy">-</div><div class="s" id="hl-heavy-s"></div></div>
      </div>
    </div>

    <div class="grid">
      <div class="card c8 tablecard">
        <h3>Catches this session <span class="aside" id="rc-aside"></span></h3>
        <div class="seg" id="filters" role="group" aria-label="Filter catches" style="margin-bottom:12px"></div>
        <div class="tablewrap scroll"><table>
          <thead><tr><th>Time</th><th>Fish</th><th class="hide-sm">Rarity</th><th class="hide-sm">Mutation</th><th class="r">Weight</th><th class="r hide-sm">Odds</th></tr></thead>
          <tbody id="recent"></tbody></table></div>
        <button class="more" id="more" type="button" hidden></button>
      </div>
      <div class="stack c4">
        <div class="card"><h3>By rarity <span class="aside">rarest first</span></h3><div class="bars" id="b-rarity"></div></div>
        <div class="card"><h3>Most caught</h3><div class="bars" id="b-fish"></div></div>
        <div class="card"><h3>Mutations</h3><div class="bars" id="b-mut"></div></div>
      </div>
      <div class="card c6">
        <h3>C$ gained <span class="aside">since FischHub loaded</span></h3>
        <div class="chart" id="ch-coins" role="img" aria-label="C$ gained over this session"></div>
        <details class="twin" id="tw-coins"><summary>Show data</summary><div class="wrap"></div></details>
      </div>
      <div class="card c6">
        <h3>XP gained <span class="aside">since FischHub loaded</span></h3>
        <div class="chart" id="ch-xp" role="img" aria-label="XP gained over this session"></div>
        <details class="twin" id="tw-xp"><summary>Show data</summary><div class="wrap"></div></details>
      </div>
    </div>
  </section>

  <section class="block" id="settings">
    <div class="sechead"><h2>Settings</h2><span class="sub">changes apply in FischHub right away and are saved, just like the menu</span></div>
    <div class="banner setnote" id="set-note"><span class="ic">i</span><div><b id="set-note-t">Waiting for FischHub</b><div class="d" id="set-note-d"></div></div></div>
    <div class="grid" id="set-grid"></div>
  </section>

  <section class="block" id="alltime">
    <div class="sechead"><h2>All time</h2><span class="sub" id="at-sub">every catch FischHub has logged</span></div>
    <div class="tiles" style="margin-top:0">
      <div class="card tile"><div class="k">Catches logged</div><div class="v" id="a-n">-</div><div class="f" id="a-n-f"></div></div>
      <div class="card tile"><div class="k">Different fish</div><div class="v" id="a-kinds">-</div><div class="f" id="a-kinds-f"></div></div>
      <div class="card tile"><div class="k">Mutated</div><div class="v" id="a-mut">-</div><div class="f" id="a-mut-f"></div></div>
      <div class="card tile"><div class="k">Shiny / sparkling</div><div class="v" id="a-fx">-</div><div class="f" id="a-fx-f"></div></div>
      <div class="card tile"><div class="k">Rarest ever</div><div class="v" id="a-rare">-</div><div class="f" id="a-rare-f"></div></div>
    </div>
    <div class="grid">
      <div class="card c4"><h3>By rarity <span class="aside">rarest first</span></h3><div class="bars" id="a-b-rarity"></div></div>
      <div class="card c4"><h3>Most caught</h3><div class="bars" id="a-b-fish"></div></div>
      <div class="card c4"><h3>Mutations</h3><div class="bars" id="a-b-mut"></div></div>
      <div class="card c12">
        <h3>Rarest catches <span class="aside">ranked by the game's odds</span></h3>
        <div class="tablewrap"><table>
          <thead><tr><th>When</th><th>Fish</th><th class="hide-sm">Rarity</th><th class="hide-sm">Mutation</th><th class="r">Weight</th><th class="r">Odds</th><th class="hide-sm where">Where</th></tr></thead>
          <tbody id="best"></tbody></table></div>
      </div>
    </div>
  </section>

  <section class="block" id="status">
    <div class="sechead"><h2>Status</h2><span class="sub" id="st-sub"></span></div>
    <div class="grid">
      <div class="card c6"><h3>FischHub</h3><dl class="st" id="st"></dl></div>
      <div class="card c6"><h3>Helper <span class="aside">this window</span></h3>
        <label class="toggle"><input type="checkbox" id="helper"><span class="knob"></span>
          <span class="tx"><b>AFK helper</b><span>When Roblox is idle in the background, bring it to the front for a moment and tap O then I.</span></span></label>
        <dl class="st" id="hp"></dl>
      </div>
      <div class="card c12"><details class="logbox"><summary>Log &middot; last 40 lines</summary><pre class="log" id="log"></pre></details></div>
    </div>
  </section>
</main>
<div class="tip" id="tip" role="tooltip"></div>
<div class="toasts" id="toasts" role="status" aria-live="polite"></div>
<script>
"use strict";
const RARITY = ["Trash","Common","Uncommon","Unusual","Rare","Legendary","Mythical","Exotic","Secret","Divine Secret","Apex",
  "Extinct","Limited","Special","Relic","Fragment","Gemstone","Seed"];
const RCOLOR = { Trash:"#7d7c77", Common:"#b8b7b0", Uncommon:"#3fb950", Unusual:"#2ea8a0", Rare:"#3987e5", Legendary:"#e3872d",
  Mythical:"#db61a2", Exotic:"#a371f7", Secret:"#f0503f", "Divine Secret":"#d4a72c", Apex:"#b62324", Extinct:"#9e6a03",
  Limited:"#1f9fbf", Special:"#bf8700", Relic:"#8957e5", Fragment:"#6e7681", Gemstone:"#0fbf8f", Seed:"#5a9e32" };
const DOT = "\u00b7";
const $ = id => document.getElementById(id);
const arr = v => Array.isArray(v) ? v : [];
const isNum = n => typeof n === "number" && isFinite(n);
const rank = r => { const i = RARITY.indexOf(r); return i < 0 ? -1 : (i <= 10 ? i : 7); };
const fmtN = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
const fmtC = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 2 });
const num = n => isNum(n) ? fmtN.format(Math.round(n)) : "-";
const compact = n => isNum(n) ? (Math.abs(n) < 10000 ? num(n) : fmtC.format(n)) : "-";
const signed = n => isNum(n) ? (n > 0 ? "+" : n < 0 ? "\u2212" : "") + compact(Math.abs(n)) : "-";
const dur = s => { s = Math.max(0, Math.floor(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
  return h ? `${h}h ${String(m).padStart(2, "0")}m` : m ? `${m}m ${String(x).padStart(2, "0")}s` : `${x}s`; };
const clock = (t, sec) => new Date(t * 1000).toLocaleTimeString([], sec === false ? { hour: "2-digit", minute: "2-digit" } : { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const day = t => new Date(t * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
const ago = t => { const s = Date.now() / 1000 - t; return s < 60 ? "just now" : s < 3600 ? Math.floor(s / 60) + " min ago" : s < 86400 ? Math.floor(s / 3600) + " h ago" : day(t); };
const kg = w => isNum(w) ? (w >= 100 ? num(w) : w.toFixed(1)) + " kg" : "";
const oddsN = o => { const m = /1\s*\/\s*([\d.,]+)\s*([kmb])?/i.exec(o || ""); if (!m) return 0;
  return Number(m[1].replace(/,/g, "")) * ({ k: 1e3, m: 1e6, b: 1e9 }[(m[2] || "").toLowerCase()] || 1); };
const oddsOf = c => c._o != null ? c._o : (c._o = oddsN(c.odds));
const cap = s => s ? s.charAt(0).toUpperCase() + s.slice(1) : s;

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function kids(e, list) { e.replaceChildren(...list.filter(Boolean)); return e; }

let S = null;          // state.json
let age = 0;
let all = [];          // catches.txt, oldest first
let allFrom = 0;
let rarityOf = {};
let infoVer = 0;
const rarityFor = c => c.rarity || rarityOf[c.name] || null;

// ---------------------------------------------------------------- theme
function setTheme(t) {
  document.documentElement.dataset.theme = t;
  try { localStorage.setItem("fh-theme", t); } catch (e) {}
  $("theme").title = t === "dark" ? "Switch to light" : "Switch to dark";
}
(function () {
  let t = null;
  try { t = localStorage.getItem("fh-theme"); } catch (e) {}
  if (t !== "dark" && t !== "light") t = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  setTheme(t);
})();
$("theme").addEventListener("click", () => setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark"));

// ---------------------------------------------------------------- tooltip
const tip = $("tip");
function showTip(x, y, title, rows) {
  const parts = [];
  if (title) parts.push(el("div", "t", title));
  rows.forEach(r => {
    const row = el("div", "r"), left = el("span");
    if (r.color) { const sw = el("i", "sw"); sw.style.background = r.color; left.append(sw); }
    left.append(document.createTextNode(r.label));
    row.append(left, el("b", null, r.value));
    parts.push(row);
  });
  kids(tip, parts);
  tip.style.display = "block";
  const w = tip.offsetWidth, h = tip.offsetHeight, pad = 14;
  let left = x + pad, top = y + pad;
  if (left + w > window.innerWidth - 8) left = x - w - pad;
  if (top + h > window.innerHeight - 8) top = y - h - pad;
  tip.style.left = Math.max(8, left) + "px";
  tip.style.top = Math.max(8, top) + "px";
}
const hideTip = () => { tip.style.display = "none"; };

// ---------------------------------------------------------------- line charts (one series each, crosshair + tooltip)
function niceTicks(lo, hi, n, int) {
  if (!(hi > lo)) hi = lo + (int ? 4 : 1);
  const raw = (hi - lo) / n, mag = Math.pow(10, Math.floor(Math.log10(raw))), f = raw / mag;
  let step = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * mag;
  if (int) step = Math.max(1, Math.round(step));
  const out = [];
  for (let v = Math.floor(lo / step) * step; v <= hi + step * 0.999; v += step) out.push(Math.round(v / step) * step);
  if (out[out.length - 1] < hi) out.push(out[out.length - 1] + step);
  return out;
}
const NS = "http://www.w3.org/2000/svg";
function sv(tag, attrs, text) { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); if (text != null) e.textContent = text; return e; }

function makeChart(id, twinId, opt) {
  const box = $(id), c = { box, opt, pts: [], sig: "", g: null, hx: null };
  function geometry() {
    const w = box.clientWidth, h = box.clientHeight, pts = c.pts;
    const P = { l: 46, r: 14, t: 10, b: 24 };
    const x0 = pts[0][0], x1 = Math.max(pts[pts.length - 1][0], x0 + 1);
    let lo = Infinity, hi = -Infinity;
    pts.forEach(p => { if (p[1] < lo) lo = p[1]; if (p[1] > hi) hi = p[1]; });
    const ticks = niceTicks(Math.min(0, lo), Math.max(hi, 0), 4, opt.int);
    const y0 = ticks[0], y1 = ticks[ticks.length - 1];
    return { w, h, P, x0, x1, ticks,
      X: t => P.l + (t - x0) / (x1 - x0) * (w - P.l - P.r),
      Y: v => P.t + (1 - (v - y0) / (y1 - y0)) * (h - P.t - P.b) };
  }
  function draw() {
    const pts = c.pts;
    if (pts.length < 2 || box.clientWidth < 40) {
      c.g = null;
      kids(box, [el("div", "chart-empty", opt.empty)]);
      return;
    }
    const g = c.g = geometry(), { w, h, P, X, Y } = g;
    const svg = sv("svg", { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: "none", "aria-hidden": "true" });
    g.ticks.forEach(v => {
      const y = Y(v);
      svg.append(sv("line", { x1: P.l, x2: w - P.r, y1: y, y2: y, class: v === 0 ? "bl" : "gl" }));
      svg.append(sv("text", { x: P.l - 8, y: y + 4, "text-anchor": "end", class: "ax" }, opt.tick(v)));
    });
    const span = g.x1 - g.x0, nx = w < 420 ? 3 : 5;
    for (let i = 0; i < nx; i++) {
      const t = g.x0 + span * i / (nx - 1);
      svg.append(sv("text", { x: X(t), y: h - 6, "text-anchor": i === 0 ? "start" : i === nx - 1 ? "end" : "middle", class: "ax" }, clock(t, span < 600)));
    }
    // thin the path to about one point per pixel
    const step = Math.max(1, Math.floor(pts.length / Math.max(60, w - P.l - P.r)));
    const vis = pts.filter((p, i) => i % step === 0 || i === pts.length - 1);
    const line = vis.map((p, i) => i === 0 ? "M" + X(p[0]).toFixed(1) + "," + Y(p[1]).toFixed(1)
      : opt.step ? "H" + X(p[0]).toFixed(1) + "V" + Y(p[1]).toFixed(1) : "L" + X(p[0]).toFixed(1) + "," + Y(p[1]).toFixed(1)).join("");
    const zero = Y(Math.max(g.ticks[0], Math.min(0, g.ticks[g.ticks.length - 1])));
    svg.append(sv("path", { d: line + `L${X(vis[vis.length - 1][0]).toFixed(1)},${zero}L${X(vis[0][0]).toFixed(1)},${zero}Z`,
      style: `fill:var(${opt.color});opacity:.10;stroke:none` }));
    svg.append(sv("path", { d: line, style: `fill:none;stroke:var(${opt.color});stroke-width:2;stroke-linejoin:round;stroke-linecap:round` }));
    const last = pts[pts.length - 1];
    svg.append(sv("circle", { cx: X(last[0]), cy: Y(last[1]), r: 4, style: `fill:var(${opt.color});stroke:var(--surface);stroke-width:2` }));
    c.cross = sv("line", { y1: P.t, y2: h - P.b, class: "cross", visibility: "hidden" });
    c.hdot = sv("circle", { r: 4.5, visibility: "hidden", style: `fill:var(${opt.color});stroke:var(--surface);stroke-width:2` });
    svg.append(c.cross, c.hdot);
    kids(box, [svg]);
    if (c.hx != null) hover(c.hx, c.hy);
  }
  function hover(clientX, clientY) {
    c.hx = clientX; c.hy = clientY;
    const g = c.g;
    if (!g) return;
    const r = box.getBoundingClientRect(), px = clientX - r.left;
    const t = g.x0 + (px - g.P.l) / (g.w - g.P.l - g.P.r) * (g.x1 - g.x0);
    let a = 0, b = c.pts.length - 1;
    while (b - a > 1) { const m = (a + b) >> 1; if (c.pts[m][0] < t) a = m; else b = m; }
    const p = Math.abs(c.pts[a][0] - t) <= Math.abs(c.pts[b][0] - t) ? c.pts[a] : c.pts[b];
    const x = g.X(p[0]), y = g.Y(p[1]);
    c.cross.setAttribute("x1", x); c.cross.setAttribute("x2", x); c.cross.setAttribute("visibility", "visible");
    c.hdot.setAttribute("cx", x); c.hdot.setAttribute("cy", y); c.hdot.setAttribute("visibility", "visible");
    showTip(clientX, clientY, clock(p[0]), [{ label: opt.name, value: opt.value(p[1]), color: `var(${opt.color})` }]);
  }
  box.addEventListener("pointermove", e => hover(e.clientX, e.clientY));
  box.addEventListener("pointerleave", () => {
    c.hx = null; hideTip();
    if (c.cross) { c.cross.setAttribute("visibility", "hidden"); c.hdot.setAttribute("visibility", "hidden"); }
  });
  const twin = $(twinId);
  function drawTwin() {
    if (!twin.open) return;
    const pts = c.pts, body = twin.querySelector(".wrap");
    if (!pts.length) { kids(body, [el("div", "empty", "no data yet")]); return; }
    const n = Math.min(pts.length, 30), rows = [];
    for (let i = 0; i < n; i++) rows.push(pts[Math.round(i * (pts.length - 1) / Math.max(1, n - 1))]);
    const tb = el("tbody");
    rows.reverse().forEach(p => { const tr = el("tr"); tr.append(el("td", "t", clock(p[0])), el("td", "r", opt.value(p[1]))); tb.append(tr); });
    const th = el("thead"), hr = el("tr");
    hr.append(el("th", null, "Time"), el("th", "r", opt.name));
    th.append(hr);
    kids(body, [kids(el("table"), [th, tb])]);
  }
  twin.addEventListener("toggle", drawTwin);
  new ResizeObserver(() => draw()).observe(box);
  c.set = (pts, o) => {
    if (o) Object.assign(opt, o);
    const sig = (opt.key || "") + "|" + pts.length + "|" + (pts.length ? pts[pts.length - 1].join(",") : "");
    if (sig === c.sig) return;
    c.sig = sig; c.pts = pts; draw(); drawTwin();
  };
  return c;
}

const chFish = makeChart("ch-fish", "tw-fish", { name: "Fish", color: "--s1", int: true, tick: v => compact(v), value: v => num(v),
  empty: "The line starts with your first catch." });
const chCoins = makeChart("ch-coins", "tw-coins", { name: "C$ gained", color: "--s2", tick: v => signed(v), value: v => signed(v) + " C$",
  empty: "A point every 30 s \u2014 check back in a minute." });
const chXp = makeChart("ch-xp", "tw-xp", { name: "XP gained", color: "--s1", tick: v => signed(v), value: v => signed(v) + " XP",
  empty: "A point every 30 s \u2014 check back in a minute." });

// ---------------------------------------------------------------- bars (single hue, rarity dot as the label's marker)
function bars(box, items, opt) {
  opt = opt || {};
  if (!items.length) { kids(box, [el("div", "empty", opt.empty || "nothing yet")]); return; }
  const total = opt.total || items.reduce((s, i) => s + i.n, 0);
  const shown = items.slice(0, opt.max || 8), max = Math.max(...shown.map(i => i.n));
  const rows = shown.map(i => {
    const row = el("div", "brow"), lab = el("span", "blab");
    row.tabIndex = 0;
    row.setAttribute("aria-label", `${i.label}: ${num(i.n)}`);
    if (i.dot) { const d = el("i"); d.style.background = i.dot; lab.append(d); }
    lab.append(el("span", null, i.label));
    const track = el("span", "btrack"), fill = el("span", "bfill");
    fill.style.display = "block";
    fill.style.width = (i.n / max * 100).toFixed(1) + "%";
    track.append(fill);
    row.append(lab, track, el("span", "bval", num(i.n)));
    const show = e => { const r = row.getBoundingClientRect();
      showTip(e && e.clientX != null ? e.clientX : r.right - 40, e && e.clientY != null ? e.clientY : r.top,
        i.label, [{ label: opt.unit || "caught", value: `${num(i.n)} (${(i.n / total * 100).toFixed(1)}%)` }]); };
    row.addEventListener("pointermove", show);
    row.addEventListener("focus", () => show());
    row.addEventListener("pointerleave", hideTip);
    row.addEventListener("blur", hideTip);
    return row;
  });
  if (items.length > shown.length) {
    const rest = items.slice(shown.length).reduce((s, i) => s + i.n, 0);
    rows.push(el("div", "bnote", `+ ${items.length - shown.length} more (${num(rest)})`));
  }
  kids(box, rows);
}
function tally(list, keyFn) {
  const m = new Map();
  list.forEach(c => { const k = keyFn(c); if (k) m.set(k, (m.get(k) || 0) + 1); });
  return [...m.entries()].map(([label, n]) => ({ label, n }));
}
function rarityBars(box, list) {
  const items = tally(list, c => rarityFor(c) || "Unknown").sort((a, b) => rank(b.label) - rank(a.label) || b.n - a.n);
  items.forEach(i => i.dot = RCOLOR[i.label] || "#6e7681");
  bars(box, items, { max: 12 });
}
function fishBars(box, list) {
  const items = tally(list, c => c.name).sort((a, b) => b.n - a.n);
  items.forEach(i => i.dot = RCOLOR[rarityOf[i.label]] || RCOLOR[(list.find(c => c.name === i.label) || {}).rarity] || null);
  bars(box, items, { max: 8 });
}
function mutBars(box, list) {
  const items = tally(list, c => c.mutation).sort((a, b) => b.n - a.n);
  bars(box, items, { max: 8, total: list.length, empty: "no mutations yet" });
}

// ---------------------------------------------------------------- fish cells
function fishCell(c) {
  const td = el("td", "fish"), r = rarityFor(c);
  if (r) { const d = el("i", "rdot show-sm"); d.style.background = RCOLOR[r] || "#6e7681"; d.title = r; td.append(d); }
  if (c.size) td.append(el("span", "size", cap(String(c.size).toLowerCase()) + " "));
  td.append(el("span", "fname", c.name || "unknown"));
  if (c.shiny) td.append(el("span", "chip fx", "\u2727 Shiny"));
  if (c.sparkling) td.append(el("span", "chip fx", "\u2726 Sparkling"));
  if (c.glitched) td.append(el("span", "chip fx", "Glitched"));
  if (c.tag) td.append(el("span", "chip", cap(c.tag)));
  if (c.source === "reel") { const s = el("span", "chip", "reel read"); s.title = "The game didn't announce this one, so FischHub read the reel"; td.append(s); }
  return td;
}
function rarityCell(r) {
  const td = el("td", "hide-sm");
  if (!r) { td.append(el("span", "muted", "?")); return td; }
  const s = el("span", "rar"), d = el("i");
  d.style.background = RCOLOR[r] || "#6e7681";
  s.append(d, document.createTextNode(r));
  td.append(s);
  return td;
}
function fishText(c) {
  return [c.shiny && "shiny", c.sparkling && "sparkling", c.size && String(c.size).toLowerCase(), c.mutation, c.name].filter(Boolean).join(" ");
}
function catchRow(c, when, short, oddsCls) {
  const tr = el("tr"), tt = el("td", "t");
  tt.append(el("span", "hide-sm", when(c.t)), el("span", "show-sm", short(c.t)));
  const odds = oddsOf(c), td = el("td", "r odds " + (oddsCls || "hide-sm") + (odds >= 1000 ? " hi" : ""), c.odds || "\u2014");
  tr.append(tt, fishCell(c), rarityCell(rarityFor(c)),
    el("td", "mut hide-sm", c.mutation || "\u2014"), el("td", "r", kg(c.weight)), td);
  return tr;
}

// ---------------------------------------------------------------- session catches
const keyOf = c => [c.t, c.name, c.weight, c.tag || "", c.mutation || ""].join("|");
let sess = [], sessSig = "";
function sessionList() {
  if (!S) return [];
  const sig = all.length + "|" + S.t + "|" + S.startedAt;
  if (sig === sessSig) return sess;
  sessSig = sig;
  const start = (S.startedAt || 0) - 1, who = S.player, m = new Map();
  all.forEach((c, i) => { if (c.t >= start && (!c.player || !who || c.player === who)) m.set(keyOf(c), [c, i]); });
  arr(S.recent).forEach((c, i) => { const k = keyOf(c); if (!m.has(k)) m.set(k, [c, 1e9 - i]); });
  sess = [...m.values()].sort((a, b) => b[0].t - a[0].t || b[1] - a[1]).map(x => x[0]);
  return sess;
}

const FILTERS = [
  ["all", "All", () => true],
  ["mut", "Mutated", c => !!c.mutation],
  ["fx", "Shiny / sparkling", c => c.shiny || c.sparkling || c.glitched],
  ["rare", "Mythical +", c => rank(rarityFor(c)) >= 6],
  ["bonus", "Extra / duplicate", c => !!c.tag],
];
let filter = "all", limit = 100, tableSig = "", heroMode = "total";
document.querySelectorAll("#hero-mode button").forEach(b => b.addEventListener("click", () => {
  heroMode = b.dataset.m;
  document.querySelectorAll("#hero-mode button").forEach(x => x.setAttribute("aria-pressed", String(x === b)));
  renderSession();
}));
function renderFilters(list) {
  kids($("filters"), FILTERS.map(([id, label, fn]) => {
    const b = el("button", null, label);
    b.type = "button";
    b.setAttribute("aria-pressed", String(filter === id));
    b.append(el("span", "n", num(list.filter(fn).length)));
    b.addEventListener("click", () => { filter = id; limit = 100; tableSig = ""; renderSession(); });
    return b;
  }));
}
function renderTable(list) {
  const fn = FILTERS.find(f => f[0] === filter)[2], rows = list.filter(fn);
  const sig = [filter, limit, rows.length, rows.length && keyOf(rows[0]), infoVer].join("|");
  if (sig === tableSig) return;
  tableSig = sig;
  renderFilters(list);
  const tb = $("recent");
  if (!rows.length) {
    const tr = el("tr"), td = el("td", "empty", list.length ? "nothing matches this filter" : "no catches yet this session");
    td.colSpan = 6; tr.append(td); kids(tb, [tr]);
  } else kids(tb, rows.slice(0, limit).map(c => catchRow(c, t => clock(t), t => clock(t, false))));
  const more = $("more"), left = rows.length - limit;
  more.hidden = left <= 0;
  more.textContent = `Show ${num(Math.min(left, 200))} more`;
  $("rc-aside").textContent = rows.length ? `${num(rows.length)} ${filter === "all" ? "fish" : "shown"}` : "";
}
$("more").addEventListener("click", () => { limit += 200; tableSig = ""; renderSession(); });

function best(list, score) { let b = null, bs = -Infinity; list.forEach(c => { const s = score(c); if (s > bs) { bs = s; b = c; } }); return bs > 0 ? b : null; }

function renderSession() {
  if (!S) return;
  const s = S, st = s.stats || {}, n = s.numbers || {}, b = s.base || {}, list = sessionList();
  const fish = isNum(st.fish) ? st.fish : list.length;
  const hrs = (s.farm || 0) / 3600;
  $("h-fish").textContent = num(fish);
  document.title = `${num(fish)} fish ${DOT} FischHub`;
  const kv = [["Per hour", hrs >= 1 / 60 ? num(fish / hrs) : "-"],
    ["Extra & duplicate", num(st.bonus || 0), "Fish the game gives on top of the one you reeled in"],
    ["Game's catch counter", num(st.caught), "Roblox's own counter counts one fish per reel and skips Extra!/Duplicate! fish"]];
  if (st.lost) kv.push(["Lost", num(st.lost)]);
  if (st.unreadFish) kv.push(["Couldn't be read", num(st.unreadFish)]);
  kids($("h-kv"), kv.map(([k, v, t]) => { const d = el("div", "kv"); if (t) d.title = t; d.append(el("span", null, k), el("b", null, v)); return d; }));

  // fish over time: every catch this session (running total), or the catch rate in about 40 buckets
  const asc = list.slice().reverse(), t0 = s.startedAt || (asc[0] && asc[0].t) || s.t;
  if (heroMode === "rate") {
    const width = Math.max(60, Math.ceil((s.t - t0) / 40 / 60) * 60), pts = [];
    let i = 0;
    for (let a = t0; a < s.t; a += width) {
      const b = Math.min(a + width, s.t);
      let n = 0;
      while (i < asc.length && asc[i].t < a + width) { if (asc[i].t >= a) n++; i++; }
      if (b - a >= width * 0.25) pts.push([b, n * 3600 / (b - a)]);
    }
    $("ch-fish-l").textContent = `Per hour, in ${width / 60}-minute steps`;
    chFish.set(pts.length >= 2 ? pts : [], { key: "rate", step: false, name: "Fish per hour", empty: "The rate shows up after a few minutes of fishing." });
  } else {
    const pts = [[t0, 0]];
    asc.forEach((c, i) => pts.push([c.t, i + 1]));
    if (s.t > pts[pts.length - 1][0]) pts.push([s.t, asc.length]);
    $("ch-fish-l").textContent = "Total over time";
    chFish.set(asc.length ? pts : [], { key: "total", step: true, name: "Fish", empty: "The line starts with your first catch." });
  }

  const delta = k => isNum(n[k]) && isNum(b[k]) ? n[k] - b[k] : null;
  const dc = delta("coins"), dx = delta("xp"), rate = v => hrs >= 1 / 60 && v != null ? signed(v / hrs) + " / hr" : null;
  $("t-coins").textContent = signed(dc); $("t-coins").title = dc != null ? num(dc) + " C$" : "";
  $("t-coins-f").textContent = [rate(dc), isNum(n.coins) ? "balance " + compact(n.coins) : null].filter(Boolean).join(` ${DOT} `);
  $("t-xp").textContent = signed(dx);
  $("t-xp-f").textContent = [isNum(n.level) ? "level " + num(n.level) : null, rate(dx)].filter(Boolean).join(` ${DOT} `);
  $("t-farm").textContent = dur(s.farm);
  $("t-farm-f").textContent = [fish && s.farm ? (s.farm / fish).toFixed(1) + " s per fish" : null, num(st.casts) + " casts"].filter(Boolean).join(` ${DOT} `);
  const muts = list.filter(c => c.mutation).length, sh = list.filter(c => c.shiny).length, sp = list.filter(c => c.sparkling).length;
  $("t-mut").textContent = list.length ? `${num(muts)}` : "-";
  $("t-mut-f").textContent = list.length ? `${(muts / list.length * 100).toFixed(0)}% ${DOT} shiny ${num(sh)} ${DOT} sparkling ${num(sp)}` : "";
  const ic = s.ic || {};
  if (s.instantCatch && ic.reels) {
    $("t-ic").textContent = (ic.acquired / ic.reels * 100).toFixed(0) + "%";
    $("t-ic-f").textContent = `${num(ic.acquired)} of ${num(ic.reels)} reels hooked`;
  } else { $("t-ic").textContent = s.instantCatch ? "on" : "off"; $("t-ic-f").textContent = s.instantCatch ? "waiting for a reel" : ""; }

  const r = s.reeling;
  $("reel-dot").hidden = !r;
  if (r) {
    $("hl-reel").textContent = r.name || "unknown fish";
    $("hl-reel-s").textContent = [r.shiny && "shiny", r.sparkling && "sparkling", r.mutation, kg(r.weight), r.rarity || rarityOf[r.name]].filter(Boolean).join(` ${DOT} `);
  } else {
    $("hl-reel").textContent = s.autoFish ? "Waiting for a bite" : "Not fishing";
    $("hl-reel-s").textContent = [s.phase, s.note].filter(Boolean).join(` ${DOT} `);
  }
  const rare = best(list, oddsOf);
  $("hl-rare").textContent = rare ? rare.odds : "-";
  $("hl-rare-s").textContent = rare ? `${fishText(rare)} ${DOT} ${ago(rare.t)}` : "odds show up with the game's catch line";
  const heavy = best(list, c => c.weight || 0);
  $("hl-heavy").textContent = heavy ? kg(heavy.weight) : "-";
  $("hl-heavy-s").textContent = heavy ? `${fishText(heavy)} ${DOT} ${ago(heavy.t)}` : "";

  renderTable(list);
  const bsig = list.length + "|" + infoVer;
  if (bsig !== renderSession.bsig) {
    renderSession.bsig = bsig;
    rarityBars($("b-rarity"), list); fishBars($("b-fish"), list); mutBars($("b-mut"), list);
  }

  const smp = arr(s.samples), live = s.t;
  const series = k => { if (!isNum(b[k])) return [];
    const p = smp.filter(x => isNum(x[k])).map(x => [x.t, x[k] - b[k]]);
    if (p.length && isNum(n[k]) && live > p[p.length - 1][0]) p.push([live, n[k] - b[k]]);
    return p; };
  chCoins.set(series("coins")); chXp.set(series("xp"));
}

function renderStatus() {
  if (!S) return;
  const s = S, a = s.afk || {}, loc = s.location || {}, ic = s.ic || {};
  const items = [
    ["Auto fish", s.autoFish ? `on ${DOT} ${s.phase || ""}${s.note ? " (" + s.note + ")" : ""}` : "off"],
    ["Mode", [s.mode, s.castStyle && s.castStyle + " cast"].filter(Boolean).join(` ${DOT} `)],
    ["Rod", `${s.rod || "none"}${s.rodState ? " (" + s.rodState + ")" : ""}`],
    ["Instant catch", s.instantCatch ? ic.status || "on" : "off"],
    ["Anti-AFK", a.on ? `${a.status || ""}${a.taps ? ` ${DOT} ${a.taps} taps` : ""}${a.needFocus ? ` ${DOT} Roblox needs focus` : ""}` : "off"],
    ["Location", `${loc.spot || "-"}${isNum(loc.x) ? `  (${loc.x}, ${loc.y}, ${loc.z})` : ""}`],
    ["Webhook", s.hook || "off"], ["Aurora totems", s.aurora || "-"], ["Fish info", s.fishStatus || "-"],
    ["Script", `v${s.v || "?"} ${DOT} up ${dur(s.uptime)}`],
  ];
  if (s.manual) items.unshift(["Paused", s.manual]);
  if (s.blocked) items.unshift(["Blocked", s.blocked]);
  kids($("st"), items.flatMap(([k, v]) => [el("dt", null, k), el("dd", null, v)]));
  $("log").textContent = arr(s.log).slice().reverse().join("\n");
}

function renderAllTime() {
  const named = all.filter(c => c.name && c.name !== "unknown");
  if (!all.length) {
    ["a-n", "a-kinds", "a-mut", "a-fx", "a-rare"].forEach(id => { $(id).textContent = "-"; $(id + "-f").textContent = ""; });
    $("a-n-f").textContent = "catches are added here as you fish";
    ["a-b-rarity", "a-b-fish", "a-b-mut"].forEach(id => kids($(id), [el("div", "empty", "nothing logged yet")]));
    kids($("best"), []);
    return;
  }
  const players = new Set(all.map(c => c.player).filter(Boolean));
  $("at-sub").textContent = `every catch FischHub has logged${players.size > 1 ? ` ${DOT} ${players.size} accounts` : ""}`;
  $("a-n").textContent = compact(all.length); $("a-n").title = num(all.length);
  $("a-n-f").textContent = "since " + day(all[0].t);
  const kinds = new Set(named.map(c => c.name));
  $("a-kinds").textContent = num(kinds.size);
  $("a-kinds-f").textContent = "kinds of fish and items";
  const muts = named.filter(c => c.mutation).length;
  $("a-mut").textContent = compact(muts);
  $("a-mut-f").textContent = named.length ? (muts / named.length * 100).toFixed(1) + "% of catches" : "";
  const sh = named.filter(c => c.shiny).length, sp = named.filter(c => c.sparkling).length;
  $("a-fx").textContent = `${num(sh)} / ${num(sp)}`;
  $("a-fx-f").textContent = named.length ? `${((sh + sp) / named.length * 100).toFixed(2)}% of catches` : "";
  const rare = best(named, oddsOf);
  $("a-rare").textContent = rare ? rare.odds : "-";
  $("a-rare-f").textContent = rare ? `${fishText(rare)} ${DOT} ${day(rare.t)}` : "";
  rarityBars($("a-b-rarity"), named); fishBars($("a-b-fish"), named); mutBars($("a-b-mut"), named);
  const top = named.filter(c => oddsOf(c) > 0).sort((x, y) => oddsOf(y) - oddsOf(x) || (y.weight || 0) - (x.weight || 0)).slice(0, 25);
  if (!top.length) {
    const tr = el("tr"), td = el("td", "empty", "no odds logged yet"); td.colSpan = 7; tr.append(td); kids($("best"), [tr]);
  } else kids($("best"), top.map(c => { const tr = catchRow(c, day, t => new Date(t * 1000).toLocaleDateString([], { month: "short", day: "numeric" }), "all"); tr.append(el("td", "muted hide-sm where", c.spot || "")); return tr; }));
}

function setLive(state, text) { $("live").dataset.s = state; $("live-t").textContent = text; }
function banner(kind, title, detail) {
  const b = $("banner");
  b.className = "banner" + (kind ? " on " + kind : "");
  $("banner-t").textContent = title || ""; $("banner-d").textContent = detail || "";
  $("banner-i").textContent = kind === "crit" || kind === "warn" ? "!" : "i";
}

function renderHead() {
  if (!S) return;
  $("who").textContent = `${S.player || ""} ${DOT} v${S.v || "?"}`;
  $("phase").textContent = S.autoFish ? [S.phase, S.note].filter(Boolean).join(` ${DOT} `) : "Auto fish is off";
  $("st-sub").textContent = S.userId ? `${S.player} ${DOT} started ${clock(S.startedAt, false)}` : "";
  const d = S.disconnect;
  if (d) banner("crit", `${d.title || "Disconnected"} at ${clock(d.t)}`, [d.message, S.alertStatus].filter(Boolean).join(" \u2014 "));
  else if (age >= 60) banner("warn", `FischHub hasn't updated for ${dur(age)}`, "Roblox or Matcha may have closed, or the game froze. The numbers below are from the last update.");
  else banner(null);
}

// ---------------------------------------------------------------- settings (sent to FischHub through the helper)
const TOKEN = "__FH_TOKEN__";
let CTL = null, ctlStamp = null;
const views = new Map();   // setting key -> functions that show a value
const pend = new Map();    // setting key (or "do:<action>") -> { id, t, label, key }
const busyEls = new Map(); // setting key -> elements dimmed while a change is on its way

function toast(text, bad) {
  const t = el("div", "toast" + (bad ? " err" : ""), text);
  $("toasts").append(t);
  setTimeout(() => t.remove(), bad ? 6000 : 3500);
}
async function post(body) {
  const res = await fetch("/cmd", { method: "POST", headers: { "Content-Type": "application/json", "X-FH-Token": TOKEN }, body: JSON.stringify(body) });
  let j = {};
  try { j = await res.json(); } catch (e) {}
  if (!res.ok || !j.id) throw new Error(j.error || "the helper said " + res.status);
  return j.id;
}
function view(key, fn) { if (!views.has(key)) views.set(key, []); views.get(key).push(fn); }
function busy(key, elx) { if (!busyEls.has(key)) busyEls.set(key, []); busyEls.get(key).push(elx); }
function setBusy(key, on) { (busyEls.get(key) || []).forEach(e => e.classList.toggle("busy", on)); }
const fmtVal = (c, v) => c.kind === "slider" ? `${Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${c.unit || ""}`.trim() : String(v);

async function change(c, value) {
  if (c.risk && value === true && !confirm(`${c.label}\n\n${c.risk}\n\nTurn it on?`)) { syncControls(true); return; }
  const key = c.key;
  pend.set(key, { id: null, t: Date.now(), label: c.label, key });
  setBusy(key, true);
  try {
    pend.get(key).id = await post({ set: key, value });
  } catch (e) {
    pend.delete(key); setBusy(key, false); syncControls(true);
    toast(`${c.label}: ${e.message}`, true);
  }
}
async function act(a) {
  const key = "do:" + a.key;
  if (pend.has(key)) return;
  pend.set(key, { id: null, t: Date.now(), label: a.label, key });
  setBusy(key, true);
  try { pend.get(key).id = await post({ do: a.key }); }
  catch (e) { pend.delete(key); setBusy(key, false); toast(`${a.label}: ${e.message}`, true); }
}
// FischHub reports each change it applied (state.cmd.results); anything it doesn't pick up in 15 s is dropped.
function checkResults() {
  const res = arr(S && S.cmd && S.cmd.results);
  for (const [key, p] of pend) {
    if (!p.id) continue;
    const r = res.find(x => String(x.id) === String(p.id));
    if (r && typeof r.ok === "boolean") {
      pend.delete(key); setBusy(key, false);
      const msg = r.msg === "true" ? "on" : r.msg === "false" ? "off" : (r.msg || (r.ok ? "done" : "failed"));
      toast(`${p.label}: ${msg}`, !r.ok);
    } else if (!r && Date.now() - p.t > 15000) {
      pend.delete(key); setBusy(key, false);
      toast(`${p.label}: FischHub didn't pick this up. Is it running, with Settings \u203a Dashboard feed on?`, true);
    }
  }
}
function syncControls(force) {
  if (!S || !S.settings) return;
  for (const [key, fns] of views) {
    if (pend.has(key) && !force) continue;
    fns.forEach(fn => fn(S.settings[key]));
  }
}

function makeControl(c, compact) {
  const box = el("div", "ctl-c");
  if (c.kind === "toggle") {
    const lab = el("label", "switch"), inp = el("input"), knob = el("span", "knob");
    inp.type = "checkbox"; inp.setAttribute("aria-label", c.label);
    inp.addEventListener("change", () => change(c, inp.checked));
    lab.append(inp, knob); box.append(lab);
    view(c.key, v => { inp.checked = v === true; });
  } else if (c.kind === "choice") {
    const seg = el("div", "seg"); seg.setAttribute("role", "group"); seg.setAttribute("aria-label", c.label);
    const btns = arr(c.options).map(o => { const b = el("button", null, o); b.type = "button";
      b.addEventListener("click", () => { if (b.getAttribute("aria-pressed") !== "true") { btns.forEach(x => x.setAttribute("aria-pressed", String(x === b))); change(c, o); } });
      return b; });
    seg.append(...btns); box.append(seg);
    view(c.key, v => btns.forEach(b => b.setAttribute("aria-pressed", String(b.textContent === v))));
  } else if (c.kind === "slider") {
    const r = el("input"), out = el("output");
    r.type = "range"; r.min = c.min; r.max = c.max; r.step = c.step; r.setAttribute("aria-label", c.label);
    let dragging = false;
    r.addEventListener("pointerdown", () => { dragging = true; });
    r.addEventListener("input", () => { out.textContent = fmtVal(c, r.value); });
    r.addEventListener("change", () => { dragging = false; change(c, Number(r.value)); });
    box.append(r, out);
    view(c.key, v => { if (!dragging && isNum(v)) { r.value = v; out.textContent = fmtVal(c, v); } });
  } else {
    const inp = el("input"), save = el("button", "btn", "Save"), state = el("span", "state");
    const secret = c.kind === "secret";
    inp.type = secret ? "password" : "text"; inp.autocomplete = "off"; inp.spellcheck = false;
    inp.placeholder = secret ? "paste a new webhook url" : (c.placeholder || "");
    inp.setAttribute("aria-label", c.label);
    save.type = "button";
    const send = () => { change(c, inp.value.trim()); if (secret) inp.value = ""; };
    save.addEventListener("click", send);
    inp.addEventListener("keydown", e => { if (e.key === "Enter") send(); });
    box.append(inp, save);
    if (secret) {
      box.append(state);
      view(c.key, v => { state.textContent = v === "set" ? "saved" : v === "invalid" ? "not a webhook url" : "not set"; });
    } else view(c.key, v => { if (document.activeElement !== inp) inp.value = v == null ? "" : String(v); });
  }
  return box;
}

function buildControls() {
  views.clear(); busyEls.clear();
  const grid = $("set-grid"), quick = $("quick");
  if (!CTL || !arr(CTL.controls).length) { kids(grid, []); kids(quick, []); return; }
  const groups = [];
  arr(CTL.controls).forEach(c => { let g = groups.find(x => x.name === c.group); if (!g) groups.push(g = { name: c.group, items: [] }); g.items.push(c); });
  kids(grid, groups.map(g => {
    const card = el("div", "card c6");
    card.append(el("h3", null, g.name));
    g.items.forEach(c => {
      const row = el("div", "ctl k-" + c.kind), t = el("div", "ctl-t");
      t.append(el("b", null, c.label));
      if (c.help) t.append(el("span", null, c.help));
      row.append(t, makeControl(c));
      busy(c.key, row);
      card.append(row);
    });
    const acts = arr(CTL.actions).filter(a => a.group === g.name);
    if (acts.length) {
      const bar = el("div", "actions");
      acts.forEach(a => { const b = el("button", "btn", a.label); b.type = "button"; b.addEventListener("click", () => act(a)); busy("do:" + a.key, b); bar.append(b); });
      card.append(bar);
    }
    return card;
  }));
  kids(quick, ["autoFish", "instantCatch"].map(k => arr(CTL.controls).find(c => c.key === k)).filter(Boolean).map(c => {
    const q = el("div", "q");
    q.append(el("b", null, c.label), makeControl(c).firstChild);
    busy(c.key, q);
    return q;
  }));
  syncControls(true);
  setLiveControls();
}
async function loadControls() {
  try {
    const j = await (await fetch("/controls", { cache: "no-store" })).json();
    CTL = j && Array.isArray(j.controls) ? j : null;
  } catch (e) { CTL = null; }
  buildControls();
}
// Controls work only while FischHub is running and writing the feed.
function setLiveControls() {
  const live = !!(S && !S.unloaded && age < 15 && !S.disconnect);
  document.querySelectorAll("#set-grid input, #set-grid button, #quick input").forEach(x => { x.disabled = !live; });
  const note = $("set-note");
  let t = "", d = "";
  if (!S) { t = "Waiting for FischHub"; d = "Load FischHub in Matcha with Settings \u203a Dashboard feed on, and its settings show up here."; }
  else if (!S.settings) { t = "Update FischHub to change settings here"; d = `This is FischHub v${S.v || "?"}; changing settings from this page needs 2.3.0 or newer.`; }
  else if (!CTL) { t = "Loading FischHub's settings"; d = ""; }
  else if (!live) { t = "FischHub isn't running right now"; d = "Changes need FischHub loaded in Matcha and connected to the game."; }
  note.className = "banner setnote" + (t ? " on" : "");
  $("set-note-t").textContent = t; $("set-note-d").textContent = d;
}

// ---------------------------------------------------------------- Roblox view (a picture of the Roblox window only, from the helper)
let shotLive = true, shotBusy = false, shotAt = 0, shotUrl = null;
try { shotLive = localStorage.getItem("fh-shot") !== "paused"; } catch (e) {}
function shotMode(live) {
  shotLive = live;
  try { localStorage.setItem("fh-shot", live ? "live" : "paused"); } catch (e) {}
  document.querySelectorAll("#shot-mode button").forEach(b => b.setAttribute("aria-pressed", String((b.dataset.m === "live") === live)));
  if (live) shot();
}
function shotEmpty(text) {
  $("shot-img").hidden = true;
  const e = $("shot-empty"); e.hidden = false; e.textContent = text;
}
async function shot() {
  if (shotBusy) return;
  shotBusy = true;
  try {
    const w = Math.max(320, Math.min(1920, Math.round($("shot-box").clientWidth * (window.devicePixelRatio || 1))));
    const res = await fetch("/shot?w=" + w, { headers: { "X-FH-Token": TOKEN }, cache: "no-store" });
    if (res.ok && (res.headers.get("Content-Type") || "").startsWith("image/")) {
      const url = URL.createObjectURL(await res.blob()), img = $("shot-img"), old = shotUrl;
      shotUrl = url;
      img.onload = () => { if (old) URL.revokeObjectURL(old); };
      img.src = url; img.hidden = false; $("shot-empty").hidden = true;
      shotAt = Date.now();
    } else {
      let j = {};
      try { j = await res.json(); } catch (e) {}
      shotEmpty(j.why ? "No picture: " + j.why + "." : "No picture right now.");
    }
  } catch (e) { shotEmpty("The helper isn't reachable."); }
  shotBusy = false;
  shotAside();
}
function shotAside() {
  const s = shotAt ? Math.round((Date.now() - shotAt) / 1000) : null;
  $("shot-aside").textContent = s == null ? "" : (s < 2 ? "just now" : `${s}s ago`) + (shotLive ? "" : " \u00b7 paused");
}
document.querySelectorAll("#shot-mode button").forEach(b => b.addEventListener("click", () => shotMode(b.dataset.m === "live")));
$("shot-refresh").addEventListener("click", () => shot());
const fullShot = () => { const box = $("shot-box");
  if (document.fullscreenElement) document.exitFullscreen(); else if (box.requestFullscreen) box.requestFullscreen(); };
$("shot-full").addEventListener("click", fullShot);
$("shot-img").addEventListener("click", fullShot);
setInterval(() => { if (shotLive && !document.hidden) shot(); else shotAside(); }, 3000);
document.addEventListener("visibilitychange", () => { if (!document.hidden && shotLive) shot(); });

// ---------------------------------------------------------------- polling
let badReads = 0;
async function pollState() {
  let j = null;
  try {
    const res = await fetch("/state", { cache: "no-store" });
    try { j = await res.json(); badReads = 0; } catch (e) { // usually the file caught mid-write
      if (++badReads >= 5) setLive("dead", "state file unreadable");
      setTimeout(pollState, 1000); return;
    }
  } catch (e) { setLive("dead", "helper not reachable"); setTimeout(pollState, 2000); return; }
  try {
    if (j.missing) {
      setLive("dead", "no data");
      if (!S) banner("warn", "Waiting for FischHub", "Load FischHub in Matcha and keep Settings \u203a Dashboard feed on. This page fills in by itself.");
    } else if (j.state && j.state.unloaded) {
      setLive("dead", "unloaded");
      if (S) { S.unloaded = true; setLiveControls(); }
      banner("warn", `FischHub was unloaded at ${clock(j.state.t)}`, "Load it again in Matcha to pick up where you left off.");
    } else if (j.state) {
      S = j.state; age = j.age || 0;
      if (S.disconnect) setLive("dead", "disconnected");
      else setLive(age < 8 ? "live" : age < 60 ? "stale" : "dead", age < 8 ? "live" : `${dur(age)} ago`);
      renderHead(); renderSession(); renderStatus();
      if (S.controls && S.controls !== ctlStamp) { ctlStamp = S.controls; loadControls(); }
      checkResults(); syncControls(); setLiveControls();
    }
  } catch (e) { console.warn(e); }
  setTimeout(pollState, 2000);
}

async function pollCatches() {
  try {
    const res = await fetch("/catches?from=" + allFrom, { cache: "no-store" });
    const next = Number(res.headers.get("X-Next") || 0);
    const buf = new Uint8Array(await res.arrayBuffer());
    if (next < allFrom) { all = []; allFrom = 0; }
    const cut = buf.lastIndexOf(10);
    if (cut >= 0) {
      new TextDecoder().decode(buf.subarray(0, cut)).split("\n").forEach(l => { try { if (l.trim()) all.push(JSON.parse(l)); } catch (e) {} });
      allFrom += cut + 1;
      renderAllTime(); renderSession();
    } else if (!all.length) renderAllTime();
  } catch (e) {}
  setTimeout(pollCatches, 10000);
}

async function pollInfo() {
  try {
    const j = await (await fetch("/fishinfo", { cache: "no-store" })).json();
    rarityOf = j.rarity || {}; infoVer++;
    renderSession(); renderAllTime();
  } catch (e) {}
  setTimeout(pollInfo, 60000);
}

async function helper(on) {
  try {
    const j = await (await fetch("/helper" + (on == null ? "" : "?afk=" + (on ? 1 : 0)), { cache: "no-store", headers: { "X-FH-Token": TOKEN } })).json();
    $("helper").checked = !!j.afk;
    kids($("hp"), [["AFK helper", j.afkNote], ["Disconnect watchdog", j.watch], ["Screenshots", j.shot]]
      .flatMap(([k, v]) => [el("dt", null, k), el("dd", null, v || "-")]));
  } catch (e) {}
}
$("helper").addEventListener("change", e => helper(e.target.checked));
setInterval(() => helper(), 5000);
shotMode(shotLive); setLiveControls();
helper(); pollInfo(); pollState(); pollCatches();
</script>
</body>
</html>
'@
$HtmlBytes = [Text.Encoding]::UTF8.GetBytes($Html.Replace('__FH_TOKEN__', $Token))

function Say([string]$text, [string]$color = 'Gray') {
  Write-Host ("  " + (Get-Date -Format 'HH:mm:ss') + "  " + $text) -ForegroundColor $color
}

function Read-Shared([string]$path, [long]$from = 0) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try {
    $len = $fs.Length
    if ($from -gt $len) { $from = 0 }
    [void]$fs.Seek($from, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] ($len - $from)
    $got = 0
    while ($got -lt $buf.Length) {
      $n = $fs.Read($buf, $got, $buf.Length - $got)
      if ($n -le 0) { break }
      $got += $n
    }
    return @{ bytes = $buf; size = $len; from = $from }
  } finally { $fs.Close() }
}

function Read-Json([string]$path) {
  $r = Read-Shared $path
  if (-not $r) { return $null }
  try { return ([Text.Encoding]::UTF8.GetString($r.bytes) | ConvertFrom-Json) } catch { return $null }
}

function Send([Net.Sockets.NetworkStream]$stream, [int]$status, [string]$type, [byte[]]$body, [string]$extra = '') {
  $reason = if ($status -lt 300) { 'OK' } elseif ($status -eq 404) { 'Not Found' } else { 'Error' }
  $head = "HTTP/1.1 $status $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`n$($extra)Connection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

function Send-Text($stream, [int]$status, [string]$type, [string]$text, [string]$extra = '') {
  Send $stream $status $type ([Text.Encoding]::UTF8.GetBytes($text)) $extra
}

function Read-Line($stream) {
  $sb = New-Object System.Text.StringBuilder
  while ($true) {
    $b = $stream.ReadByte()
    if ($b -lt 0) { return $null }
    if ($b -eq 10) { break }
    if ($b -ne 13) { [void]$sb.Append([char]$b) }
    if ($sb.Length -gt 16384) { return $null }
  }
  return $sb.ToString()
}

function Read-Exact($stream, [int]$count) {
  $buf = New-Object byte[] $count
  $got = 0
  while ($got -lt $count) {
    $n = $stream.Read($buf, $got, $count - $got)
    if ($n -le 0) { break }
    $got += $n
  }
  if ($got -lt $count) {
    $part = New-Object byte[] $got
    [Array]::Copy($buf, $part, $got)
    return ,$part
  }
  return ,$buf
}

function Json-Str([string]$s) {
  return '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n') + '"'
}

# Requests from the page must come from this PC's own address (not a website that points its name at
# 127.0.0.1) and, for anything that changes something or takes a picture, carry the page's key.
function Is-Local($headers) {
  $h = [string]$headers['host']
  if ($h -and $h -notmatch '^(127\.0\.0\.1|localhost)(:\d+)?$') { return $false }
  $o = [string]$headers['origin']
  if ($o -and $o -notmatch '^http://(127\.0\.0\.1|localhost)(:\d+)?$') { return $false }
  return $true
}
function Has-Key($headers) { return (Is-Local $headers) -and ([string]$headers['x-fh-token'] -eq $Token) }

# Page changes waiting for FischHub. Each is one JSON line in commands.txt; FischHub reports the
# last one it read (cmd.ack in state.json) and those are dropped, as is anything older than 2 min.
$script:Cmds = New-Object System.Collections.ArrayList
$script:CmdLast = [long]0
$script:CmdAck = [long]0
function Write-Commands {
  $keep = @($script:Cmds | Where-Object { $_.id -gt $script:CmdAck -and ((Get-Date) - $_.at).TotalSeconds -lt 120 })
  $script:Cmds = New-Object System.Collections.ArrayList
  foreach ($c in $keep) { [void]$script:Cmds.Add($c) }
  $text = ($keep | ForEach-Object { $_.line + "`n" }) -join ''
  try { [IO.File]::WriteAllText($CmdFile, $text, (New-Object Text.UTF8Encoding $false)) } catch { }
}
function Add-Command($stream, $headers, [byte[]]$body) {
  if (-not (Has-Key $headers)) { Send-Text $stream 403 'application/json' '{"error":"reload the page"}'; return }
  $j = $null
  try { $j = [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json } catch { }
  $part = $null
  if ($j -and $j.set -is [string] -and $j.set -match '^[A-Za-z]{1,40}$') {
    $v = $j.value
    if ($v -is [bool]) { $val = $(if ($v) { 'true' } else { 'false' }) }
    elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $val = $v.ToString([Globalization.CultureInfo]::InvariantCulture) }
    elseif ($v -is [string] -and $v.Length -le 400) { $val = Json-Str ($v -replace '[\x00-\x1f]', '') }
    else { $val = $null }
    if ($val) { $part = '"set":' + (Json-Str $j.set) + ',"value":' + $val }
  } elseif ($j -and $j.do -is [string] -and $j.do -match '^[A-Za-z]{1,40}$') {
    $part = '"do":' + (Json-Str $j.do)
  }
  if (-not $part) { Send-Text $stream 400 'application/json' '{"error":"not a setting change"}'; return }
  if (-not (Test-Path -LiteralPath (Split-Path $CmdFile))) { Send-Text $stream 409 'application/json' '{"error":"no FischHub dashboard folder yet - load FischHub first"}'; return }
  $id = [Math]::Max($script:CmdLast + 1, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $script:CmdLast = $id
  [void]$script:Cmds.Add(@{ id = $id; at = Get-Date; line = '{"id":"' + $id + '",' + $part + '}' })
  Write-Commands
  Send-Text $stream 200 'application/json' ('{"id":"' + $id + '"}')
  $what = if ($j.set -eq 'webhookUrl') { 'webhook url' } elseif ($j.set) { $j.set + ' = ' + [string]$j.value } else { $j.do }
  Say ('page: ' + $what)
}

function Get-Roblox {
  return Get-Process -Name 'RobloxPlayerBeta' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}

# A JPEG of the Roblox window, or $null with the reason in $script:ShotWhy. Webhook pictures also
# update the note the page shows ($script:ShotNote); the page's own live view doesn't.
function Take-Shot([int]$maxWidth = 1280, [bool]$forWebhook = $true) {
  $img = $null
  if (-not $script:CanShot) { $script:ShotWhy = 'screenshots are not available on this PC' }
  else {
    $rb = Get-Roblox
    if (-not $rb) { $script:ShotWhy = 'no Roblox window' }
    else {
      $img = [FHShot]::Capture($rb.MainWindowHandle, $maxWidth)
      if (-not $img) { $script:ShotWhy = [FHShot]::Why }
    }
  }
  if ($forWebhook) {
    $script:ShotNote = if ($img) { 'last one ' + (Get-Date -Format 'HH:mm:ss') + ' (' + [int]($img.Length / 1024) + ' KB)' }
      elseif ($script:CanShot) { 'skipped - ' + $script:ShotWhy } else { 'not available on this PC' }
  }
  if ($img) { return ,$img }
  return $null
}

# Sends a webhook request to discord. With a screenshot the body becomes multipart: the JSON as
# payload_json (its first embed shows the picture) plus the file. An edit without a picture
# clears the previous one (attachments: []).
function Send-Discord([string]$method, [string]$url, [string]$json, $img, [bool]$isEdit) {
  if ($img) {
    $json = ([regex]'"embeds"\s*:\s*\[\s*\{').Replace($json, '$0"image":{"url":"attachment://fischhub.jpg"},', 1)
    $json = '{"attachments":[{"id":0,"filename":"fischhub.jpg"}],' + $json.TrimStart().Substring(1)
    $boundary = '----fischhub' + [Guid]::NewGuid().ToString('N')
    $ms = New-Object IO.MemoryStream
    $head = [Text.Encoding]::UTF8.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"payload_json`"`r`nContent-Type: application/json`r`n`r`n$json`r`n--$boundary`r`nContent-Disposition: form-data; name=`"files[0]`"; filename=`"fischhub.jpg`"`r`nContent-Type: image/jpeg`r`n`r`n")
    $tail = [Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n")
    $ms.Write($head, 0, $head.Length)
    $ms.Write($img, 0, $img.Length)
    $ms.Write($tail, 0, $tail.Length)
    $body = $ms.ToArray()
    $type = "multipart/form-data; boundary=$boundary"
  } else {
    if ($isEdit) { $json = '{"attachments":[],' + $json.TrimStart().Substring(1) }
    $body = [Text.Encoding]::UTF8.GetBytes($json)
    $type = 'application/json'
  }
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = $method
  $req.ContentType = $type
  $req.UserAgent = 'FischHub-helper (https://github.com/j5cks/fischhub, 2)'
  $req.Timeout = 20000
  $req.ContentLength = $body.Length
  $rs = $req.GetRequestStream()
  $rs.Write($body, 0, $body.Length)
  $rs.Close()
  $resp = $null
  try {
    $resp = $req.GetResponse()
  } catch {
    $ex = $_.Exception
    while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
    if ($ex) { $resp = $ex.Response }
  }
  if (-not $resp) { return @{ status = 502; text = '{"message":"the helper could not reach discord"}' } }
  $status = [int]$resp.StatusCode
  $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
  $text = $reader.ReadToEnd()
  $resp.Close()
  return @{ status = $status; text = $text }
}

# FischHub's webhook requests: an edit (.../messages/<id>, sent on as PATCH) or a new message
# (sent on as POST ?wait=true). ?shot=1 adds a screenshot.
function Relay($stream, [string]$path, [string]$query, [byte[]]$body) {
  $isEdit = $path -match '^/api/webhooks/\d+/[A-Za-z0-9_\-]+/messages/\d+$'
  $isNew = $path -match '^/api/webhooks/\d+/[A-Za-z0-9_\-]+$'
  if (-not ($isEdit -or $isNew) -or $body.Length -lt 2) {
    Send-Text $stream 404 'application/json' '{"message":"the FischHub helper only forwards webhook messages"}'
    return
  }
  $img = $null
  if ($query -match '(^|&)shot=1') { $img = Take-Shot }
  $json = [Text.Encoding]::UTF8.GetString($body)
  $url = 'https://discord.com' + $path + $(if ($isNew) { '?wait=true' } else { '' })
  $r = Send-Discord $(if ($isEdit) { 'PATCH' } else { 'POST' }) $url $json $img ([bool]$isEdit)
  Send-Text $stream $r.status 'application/json; charset=utf-8' $r.text
  $what = if ($isEdit) { 'edited message' } else { 'posted message' }
  if ($img) { $what += ' + screenshot' }
  Say ("$what -> discord " + $r.status) $(if ($r.status -lt 300) { 'Green' } else { 'Yellow' })
}

# ---------------------------------------------------------------- disconnect watchdog
$script:Watch = @{ farming = $false; alerted = $false; state = $null; note = 'waiting for FischHub'; at = [DateTime]::MinValue }

function Webhook-Settings {
  $s = Read-Json $SettingsFile
  if (-not $s) { return $null }
  $url = [string]$s.webhookUrl
  if ($url -notmatch '^https://([a-z]+\.)?discord(app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+$') { return $null }
  $ping = [string]$s.webhookPing
  $mention = if ($ping -eq 'everyone') { '@everyone' } elseif ($ping -match '^\d+$') { "<@$ping>" } else { '' }
  return @{ url = $url; alert = ($s.disconnectAlert -ne $false); shot = ($s.webhookShot -eq $true); mention = $mention }
}

function Send-StallAlert([double]$age) {
  $hook = Webhook-Settings
  if (-not $hook) { $script:Watch.note = 'FischHub stopped updating - no webhook url in settings.json, so no alert sent'; return }
  if (-not $hook.alert) { $script:Watch.note = 'FischHub stopped updating (alerts are off in FischHub)'; return }
  $rb = Get-Roblox
  $why = if ($rb) { 'roblox is still open, so matcha or fischhub stopped (or the game froze)' } else { 'roblox is closed (it crashed or was quit)' }
  $st = $script:Watch.state
  $fields = @()
  if ($st -and $st.stats) { $fields += '{"name":"caught this session","value":' + (Json-Str ([string][int]$st.stats.caught)) + ',"inline":true}' }
  if ($st -and $st.farm) { $fields += '{"name":"farming","value":' + (Json-Str ([TimeSpan]::FromSeconds([int]$st.farm).ToString())) + ',"inline":true}' }
  if ($st -and $st.location -and $st.location.spot) { $fields += '{"name":"location","value":' + (Json-Str ([string]$st.location.spot).ToLower()) + ',"inline":true}' }
  $desc = 'fischhub stopped updating ' + [int]($age / 60) + ' min ago - ' + $why
  $player = if ($st -and $st.player) { ([string]$st.player).ToLower() } else { 'fischhub' }
  $json = '{"username":"fischhub",' + $(if ($hook.mention) { '"content":' + (Json-Str $hook.mention) + ',' } else { '' }) +
    '"embeds":[{"title":"fischhub ' + [char]0xB7 + ' stopped responding","color":65793,"description":' + (Json-Str $desc) +
    ',"author":{"name":' + (Json-Str $player) + '},"fields":[' + ($fields -join ',') + '],"timestamp":' +
    (Json-Str ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))) + '}]}'
  $img = $null
  if ($hook.shot -and $rb) { $img = Take-Shot }
  $r = Send-Discord 'POST' ($hook.url + '?wait=true') $json $img $false
  $ok = $r.status -lt 300
  $script:Watch.note = 'FischHub stopped updating - alert ' + $(if ($ok) { 'sent ' + (Get-Date -Format 'HH:mm:ss') } else { 'failed (discord ' + $r.status + ')' })
  Say ('FischHub stopped updating (' + $why + ') - alert ' + $(if ($ok) { 'sent' } else { 'failed' })) $(if ($ok) { 'Yellow' } else { 'Red' })
}

function Watch-Tick {
  if (-not (Test-Path -LiteralPath $StateFile)) { $script:Watch.note = 'no dashboard file yet - turn on Settings > Dashboard feed in FischHub'; return }
  $age = ((Get-Date) - (Get-Item -LiteralPath $StateFile).LastWriteTime).TotalSeconds
  if ($age -lt 15) {
    $st = Read-Json $StateFile
    if (-not $st) { return }
    $script:Watch.state = $st
    if ($st.cmd -and [string]$st.cmd.ack -match '^\d+$' -and [long]$st.cmd.ack -gt $script:CmdAck) {
      $script:CmdAck = [long]$st.cmd.ack
      if ($script:Cmds.Count) { Write-Commands }
    }
    $script:Watch.farming = ($st.autoFish -eq $true) -and -not $st.unloaded -and -not $st.disconnect
    if ($script:Watch.alerted) { Say 'FischHub is updating again' 'Green'; $script:Watch.alerted = $false }
    if ($st.unloaded) { $script:Watch.note = 'FischHub was unloaded' }
    elseif ($st.disconnect) { $script:Watch.note = 'disconnected - FischHub posted the alert itself' }
    elseif ($script:Watch.farming) { $script:Watch.note = 'watching - alerts if FischHub goes quiet for ' + [int]($StallSec / 60) + ' min while farming' }
    else { $script:Watch.note = 'watching (auto fish is off, so a stop won''t alert)' }
    return
  }
  if ($age -ge $StallSec -and $script:Watch.farming -and -not $script:Watch.alerted) {
    $script:Watch.alerted = $true
    Send-StallAlert $age
  }
}

# ---------------------------------------------------------------- AFK helper
$script:Helper = (Test-Path -LiteralPath $HelperFile) -and ((Get-Content -LiteralPath $HelperFile -TotalCount 1) -eq 'on')
$script:HelperNote = if ($script:Helper) { 'on - waiting until FischHub reports Roblox idle in the background' } else { 'off' }
$script:LastHelp = [DateTime]::MinValue

function Helper-Tick {
  if (-not $script:Helper) { return }
  if (((Get-Date) - $script:LastHelp).TotalSeconds -lt 60) { return }
  if (-not (Test-Path -LiteralPath $StateFile)) { return }
  if (((Get-Date) - (Get-Item -LiteralPath $StateFile).LastWriteTime).TotalSeconds -gt 15) { return }
  $r = Read-Shared $StateFile
  if (-not $r -or [Text.Encoding]::UTF8.GetString($r.bytes) -notmatch '"needFocus":true') { return }
  if ([FHWin]::IdleMs() -lt 3000) { $script:HelperNote = 'on - Roblox needs input; waiting for you to stop typing/moving the mouse'; return }
  $rb = Get-Roblox
  if (-not $rb) { $script:HelperNote = 'on - no Roblox window found'; return }
  $h = $rb.MainWindowHandle
  if ([FHWin]::IsIconic($h)) { $script:HelperNote = 'on - Roblox is minimized; restore it (it can stay behind other windows)'; return }
  $script:LastHelp = Get-Date
  $prev = [FHWin]::GetForegroundWindow()
  if (-not [FHWin]::Focus($h)) { $script:HelperNote = 'on - Windows refused to focus Roblox; will retry'; return }
  Start-Sleep -Milliseconds 120
  [FHWin]::Tap(0x4F)
  Start-Sleep -Milliseconds 80
  [FHWin]::Tap(0x49)
  Start-Sleep -Milliseconds 120
  if ($prev -ne [IntPtr]::Zero -and $prev -ne $h) { [void][FHWin]::Focus($prev) }
  $script:HelperNote = 'on - last nudge ' + (Get-Date -Format 'HH:mm:ss')
  Say 'AFK helper: Roblox was idle in the background - tapped O/I' 'Yellow'
}

# ---------------------------------------------------------------- http
function Handle-Client($client) {
  $client.ReceiveTimeout = 5000
  $client.SendTimeout = 5000
  $stream = $client.GetStream()
  $line = Read-Line $stream
  if (-not $line) { return }
  $headers = @{}
  while ($true) {
    $h = Read-Line $stream
    if ($h -eq $null -or $h -eq '') { break }
    $i = $h.IndexOf(':')
    if ($i -gt 0) { $headers[$h.Substring(0, $i).Trim().ToLower()] = $h.Substring($i + 1).Trim() }
  }
  if ($headers['expect'] -eq '100-continue') {
    $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
    $stream.Write($cont, 0, $cont.Length)
  }
  $body = New-Object byte[] 0
  if ($headers['transfer-encoding'] -eq 'chunked') {
    $ms = New-Object System.IO.MemoryStream
    while ($true) {
      $sizeLine = Read-Line $stream
      if ($sizeLine -eq $null) { break }
      $size = [Convert]::ToInt32(($sizeLine.Split(';')[0]).Trim(), 16)
      if ($size -eq 0) { [void](Read-Line $stream); break }
      $chunk = Read-Exact $stream $size
      $ms.Write($chunk, 0, $chunk.Length)
      [void](Read-Line $stream)
    }
    $body = $ms.ToArray()
  } elseif ($headers['content-length']) {
    $len = [int]$headers['content-length']
    if ($len -gt 0 -and $len -le 1048576) { $body = Read-Exact $stream $len }
  }
  $parts = $line.Split(' ')
  $method = $parts[0]
  $target = if ($parts.Length -gt 1) { $parts[1] } else { '/' }
  $path = ($target -split '\?')[0]
  $query = if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' }

  if ($method -eq 'POST' -and $path -eq '/cmd') { Add-Command $stream $headers $body; return }
  if ($method -eq 'POST') { Relay $stream $path $query $body; return }
  if ($method -ne 'GET') { Send-Text $stream 404 'text/plain' 'GET or POST only'; return }
  if (-not (Is-Local $headers)) { Send-Text $stream 403 'text/plain' 'open http://127.0.0.1:47210 instead'; return }
  switch ($path) {
    { $_ -eq '/' -or $_ -eq '/index.html' } { Send $stream 200 'text/html; charset=utf-8' $HtmlBytes; return }
    '/ping' { Send-Text $stream 200 'application/json' '{"relay":"fischhub-relay","helper":"fischhub-helper"}'; return }
    '/state' {
      $r = Read-Shared $StateFile
      if (-not $r) { Send-Text $stream 200 'application/json' '{"missing":true}'; return }
      $age = [int]((Get-Date) - (Get-Item -LiteralPath $StateFile).LastWriteTime).TotalSeconds
      Send-Text $stream 200 'application/json; charset=utf-8' ('{"age":' + $age + ',"state":' + [Text.Encoding]::UTF8.GetString($r.bytes) + '}')
      return
    }
    '/catches' {
      $from = 0
      if ($query -match '(^|&)from=(\d+)') { $from = [long]$Matches[2] }
      $r = Read-Shared $CatchFile $from
      if (-not $r) { Send $stream 200 'text/plain; charset=utf-8' (New-Object byte[] 0) "X-Next: 0`r`n"; return }
      Send $stream 200 'text/plain; charset=utf-8' $r.bytes "X-Next: $($r.size)`r`n"
      return
    }
    '/controls' {
      $r = Read-Shared $CtlFile
      if (-not $r) { Send-Text $stream 200 'application/json' '{}'; return }
      Send $stream 200 'application/json; charset=utf-8' $r.bytes
      return
    }
    '/shot' {
      if (-not (Has-Key $headers)) { Send-Text $stream 403 'application/json' '{"why":"reload the page"}'; return }
      $w = 1280
      if ($query -match '(^|&)w=(\d+)') { $w = [Math]::Max(320, [Math]::Min(1920, [int]$Matches[2])) }
      if (-not $script:LiveShot -or ((Get-Date) - $script:LiveShotAt).TotalMilliseconds -ge 900) {
        $script:LiveShot = Take-Shot $w $false
        $script:LiveShotAt = Get-Date
      }
      if ($script:LiveShot) { Send $stream 200 'image/jpeg' $script:LiveShot; return }
      Send-Text $stream 200 'application/json' ('{"why":' + (Json-Str $script:ShotWhy) + '}')
      return
    }
    '/fishinfo' {
      $r = Read-Shared $InfoFile
      if (-not $r) { Send-Text $stream 200 'application/json' '{}'; return }
      Send $stream 200 'application/json; charset=utf-8' $r.bytes
      return
    }
    '/helper' {
      if ($query -match '(^|&)afk=([01])') {
        if (-not (Has-Key $headers)) { Send-Text $stream 403 'application/json' '{"error":"reload the page"}'; return }
        $script:Helper = $Matches[2] -eq '1'
        try { Set-Content -LiteralPath $HelperFile -Value $(if ($script:Helper) { 'on' } else { 'off' }) } catch {}
        $script:HelperNote = if ($script:Helper) { 'on - waiting until FischHub reports Roblox idle in the background' } else { 'off' }
        Say ('AFK helper ' + $(if ($script:Helper) { 'on' } else { 'off' }))
      }
      Send-Text $stream 200 'application/json' ('{"afk":' + $(if ($script:Helper) { 'true' } else { 'false' }) +
        ',"afkNote":' + (Json-Str $script:HelperNote) + ',"watch":' + (Json-Str $script:Watch.note) + ',"shot":' + (Json-Str $script:ShotNote) + '}')
      return
    }
    default { Send-Text $stream 404 'text/plain' 'not found' }
  }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch {
  Write-Host ''
  Write-Host "  Port $Port is already in use - the helper (or the old webhook-relay.bat) is probably open in another window." -ForegroundColor Yellow
  try { Start-Process "http://127.0.0.1:$Port/" } catch {}
  exit 1
}
Write-Host ''
Write-Host '  FischHub helper' -ForegroundColor Cyan
Write-Host "  dashboard: http://127.0.0.1:$Port  (this PC only) - keep this window open, close it to stop."
Write-Host '  also: edits your webhook message, adds screenshots, and alerts if FischHub stops while farming.'
Write-Host "  reading $Dir"
if (-not (Test-Path -LiteralPath $Dir)) {
  Write-Host "  That folder doesn't exist - drag your Matcha workspace folder onto fischhub-helper.bat." -ForegroundColor Yellow
}
Write-Host ("  screenshots: " + $script:ShotNote + " | AFK helper: " + $(if ($script:Helper) { 'on' } else { 'off (switch it on in the page)' }))
Write-Host ''
try { Start-Process "http://127.0.0.1:$Port/" } catch { Write-Host "  Open http://127.0.0.1:$Port in your browser." }

$pending = New-Object System.Collections.ArrayList
$nextHelp = Get-Date
$nextWatch = Get-Date
while ($true) {
  while ($listener.Pending()) { [void]$pending.Add(@{ c = $listener.AcceptTcpClient(); at = Get-Date }) }
  # Browsers open spare connections that never send anything; serve only the ones with a request.
  for ($i = $pending.Count - 1; $i -ge 0; $i--) {
    $p = $pending[$i]
    $ready = $false
    try { $ready = $p.c.Available -gt 0 } catch {}
    if ($ready) {
      $pending.RemoveAt($i)
      try { Handle-Client $p.c } catch { Say ('request failed: ' + $_.Exception.Message) 'Red' } finally { $p.c.Close() }
    } elseif (((Get-Date) - $p.at).TotalSeconds -gt 10) {
      $pending.RemoveAt($i)
      $p.c.Close()
    }
  }
  if ((Get-Date) -ge $nextHelp) {
    $nextHelp = (Get-Date).AddSeconds(1)
    try { Helper-Tick } catch { Say ('AFK helper error: ' + $_.Exception.Message) 'Red' }
  }
  if ((Get-Date) -ge $nextWatch) {
    $nextWatch = (Get-Date).AddSeconds(5)
    try { Watch-Tick } catch { Say ('watchdog error: ' + $_.Exception.Message) 'Red' }
  }
  Start-Sleep -Milliseconds 15
}
