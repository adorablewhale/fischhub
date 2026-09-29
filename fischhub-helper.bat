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
# only) and does four things:
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

# Screenshots of the Roblox window. PrintWindow with PW_RENDERFULLCONTENT captures a DirectX
# window even behind other windows; if that comes back black, the screen is copied only when
# Roblox is the window in front, so nothing else on your screen ends up in Discord.
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
  public static string Why = "";
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
          if (GetForegroundWindow() != h) { Why = "Roblox was behind another window and couldn't be captured"; return null; }
          POINT p = new POINT();
          ClientToScreen(h, ref p);
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
$script:ShotNote = if ($script:CanShot) { 'ready (turn on "Screenshot in webhook" in FischHub)' } else { 'not available on this PC' }

$Html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FischHub Dashboard</title>
<style>
:root {
  --bg: #0e1116; --panel: #161b22; --line: #262d36; --text: #e6e8eb; --dim: #8b949e;
  --accent: #7aa2ff; --good: #3fb950; --warn: #d29922; --bad: #f85149; --bar: #2f81f7;
}
@media (prefers-color-scheme: light) {
  :root { --bg: #f5f6f8; --panel: #ffffff; --line: #d8dde3; --text: #1b1f24; --dim: #5b6570;
    --accent: #3558d6; --good: #1a7f37; --warn: #9a6700; --bad: #cf222e; --bar: #3558d6; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; padding: 14px 20px; border-bottom: 1px solid var(--line); }
header h1 { margin: 0; font-size: 18px; }
.pill { padding: 2px 10px; border-radius: 999px; font-size: 12px; border: 1px solid var(--line); color: var(--dim); }
.pill.live { color: var(--good); border-color: var(--good); }
.pill.stale { color: var(--warn); border-color: var(--warn); }
.pill.dead { color: var(--bad); border-color: var(--bad); }
#phase { color: var(--dim); flex: 1 1 260px; }
main { padding: 16px 20px 40px; display: grid; gap: 16px; grid-template-columns: repeat(12, 1fr); max-width: 1500px; margin: 0 auto; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; min-width: 0; }
.card h2 { margin: 0 0 10px; font-size: 13px; font-weight: 600; color: var(--dim); text-transform: uppercase; letter-spacing: .04em; }
.span3 { grid-column: span 3; } .span4 { grid-column: span 4; } .span5 { grid-column: span 5; }
.span6 { grid-column: span 6; } .span7 { grid-column: span 7; } .span8 { grid-column: span 8; } .span12 { grid-column: span 12; }
@media (max-width: 1100px) { .span3, .span4, .span5 { grid-column: span 6; } .span6, .span7, .span8 { grid-column: span 12; } }
@media (max-width: 640px) { main { padding: 12px 16px 32px; } .span3, .span4, .span5, .span6 { grid-column: span 12; } }
.kpis { grid-column: span 12; display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); }
.kpi .v { font-size: 26px; font-weight: 650; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.kpi .s { color: var(--dim); font-size: 12px; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 5px 6px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { color: var(--dim); font-weight: 500; font-size: 12px; }
td.name { white-space: normal; }
.scroll { max-height: 420px; overflow: auto; }
.tag { display: inline-block; padding: 0 7px; border-radius: 6px; font-size: 11px; font-weight: 600; color: #fff; }
.mut { color: var(--warn); }
.dim { color: var(--dim); }
.row { display: flex; align-items: center; gap: 8px; margin: 4px 0; }
.row .lbl { flex: 0 0 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row .track { flex: 1; height: 10px; background: var(--line); border-radius: 5px; overflow: hidden; }
.row .fill { height: 100%; border-radius: 5px; }
.row .n { flex: 0 0 56px; text-align: right; font-variant-numeric: tabular-nums; }
dl { display: grid; grid-template-columns: 130px 1fr; gap: 4px 10px; margin: 0; }
dt { color: var(--dim); } dd { margin: 0; overflow-wrap: anywhere; white-space: pre-line; }
pre { margin: 0; font: 12px/1.45 ui-monospace, Consolas, monospace; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 360px; overflow: auto; }
canvas { width: 100%; height: 180px; display: block; }
.reel { display: none; margin-left: auto; padding: 4px 12px; border-radius: 8px; background: var(--panel); border: 1px solid var(--accent); }
label.sw { display: inline-flex; gap: 8px; align-items: center; cursor: pointer; margin-top: 8px; }
.empty { color: var(--dim); padding: 8px 0; }
.banner { grid-column: span 12; display: none; border-radius: 10px; padding: 12px 16px; border: 1px solid var(--bad); background: color-mix(in srgb, var(--bad) 14%, var(--panel)); }
.banner b { color: var(--bad); }
</style>
</head>
<body>
<header>
  <h1>FischHub</h1>
  <span id="who" class="dim"></span>
  <span id="live" class="pill dead">no data</span>
  <span id="phase"></span>
  <span id="reel" class="reel"></span>
</header>
<main>
  <div id="banner" class="banner"></div>
  <div class="kpis">
    <div class="card kpi"><h2>Caught</h2><div class="v" id="k-caught">-</div><div class="s" id="k-caught-s"></div></div>
    <div class="card kpi"><h2>Money</h2><div class="v" id="k-coins">-</div><div class="s" id="k-coins-s"></div></div>
    <div class="card kpi"><h2>Level</h2><div class="v" id="k-level">-</div><div class="s" id="k-level-s"></div></div>
    <div class="card kpi"><h2>Farming</h2><div class="v" id="k-farm">-</div><div class="s" id="k-farm-s"></div></div>
    <div class="card kpi"><h2>Special catches</h2><div class="v" id="k-special">-</div><div class="s" id="k-special-s"></div></div>
    <div class="card kpi"><h2>Instant catch</h2><div class="v" id="k-ic">-</div><div class="s" id="k-ic-s"></div></div>
  </div>

  <section class="card span6"><h2>Catches this session</h2><canvas id="c-caught"></canvas></section>
  <section class="card span6"><h2>C$ this session</h2><canvas id="c-coins"></canvas></section>

  <section class="card span7"><h2>Recent catches</h2><div class="scroll"><table>
    <thead><tr><th>Time</th><th>Fish</th><th>Rarity</th><th>Weight</th><th>Mutation</th><th>Odds</th><th>Where</th></tr></thead>
    <tbody id="recent"></tbody></table></div></section>
  <section class="card span5"><h2>This session by fish</h2><div id="byfish" class="scroll"></div></section>

  <section class="card span4"><h2>This session by rarity</h2><div id="byrarity"></div></section>
  <section class="card span4"><h2>Mutations this session</h2><div id="bymut"></div></section>
  <section class="card span4"><h2>Status</h2><dl id="status"></dl>
    <label class="sw"><input type="checkbox" id="helper"> AFK helper (focus Roblox briefly when it's idle and in the background)</label>
    <div class="dim" id="helper-s" style="font-size:12px"></div>
    <div class="dim" id="watch-s" style="font-size:12px;margin-top:6px"></div>
    <div class="dim" id="shot-s" style="font-size:12px"></div></section>

  <section class="card span6"><h2>All time (every catch logged by FischHub)</h2><div id="alltime"></div></section>
  <section class="card span6"><h2>Best catches, all time</h2><div class="scroll"><table>
    <thead><tr><th>When</th><th>Fish</th><th>Rarity</th><th>Weight</th><th>Mutation</th></tr></thead>
    <tbody id="best"></tbody></table></div></section>

  <section class="card span12"><h2>Log</h2><pre id="log"></pre></section>
</main>
<script>
const RARITY = ["Trash","Common","Uncommon","Unusual","Rare","Legendary","Mythical","Exotic","Secret","Divine Secret","Apex",
  "Extinct","Limited","Special","Relic","Fragment","Gemstone","Seed"];
const RCOLOR = { Trash:"#6e7681", Common:"#8b949e", Uncommon:"#3fb950", Unusual:"#2ea8a0", Rare:"#2f81f7", Legendary:"#e3872d",
  Mythical:"#db61a2", Exotic:"#a371f7", Secret:"#f85149", "Divine Secret":"#d4a72c", Apex:"#b62324", Extinct:"#9e6a03",
  Limited:"#1f9fbf", Special:"#bf8700", Relic:"#8957e5", Fragment:"#57606a", Gemstone:"#0fbf8f", Seed:"#5a9e32" };
const rank = r => { const i = RARITY.indexOf(r); return i < 0 ? -1 : (i <= 10 ? i : 7); };
const $ = id => document.getElementById(id);
const arr = v => Array.isArray(v) ? v : [];
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;" }[c]));
const num = n => (typeof n === "number" && isFinite(n)) ? Math.round(n).toLocaleString() : "-";
const big = n => { if (typeof n !== "number" || !isFinite(n)) return "-"; const a = Math.abs(n);
  return a >= 1e9 ? (n / 1e9).toFixed(3) + "B" : a >= 1e7 ? (n / 1e6).toFixed(2) + "M" : num(n); };
const signed = n => (typeof n === "number" && isFinite(n)) ? (n >= 0 ? "+" : "") + Math.round(n).toLocaleString() : "-";
const dur = s => { s = Math.max(0, Math.floor(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
  return (h ? h + "h " : "") + String(m).padStart(h ? 2 : 1, "0") + "m " + String(x).padStart(2, "0") + "s"; };
const clock = t => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const day = t => new Date(t * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
const tag = r => r ? `<span class="tag" style="background:${RCOLOR[r] || "#57606a"}">${esc(r)}</span>` : '<span class="dim">?</span>';
const kg = w => (typeof w === "number") ? (w >= 100 ? Math.round(w).toLocaleString() : w.toFixed(1)) + " kg" : "";
let rarityOf = {};
const fishLabel = c => `${c.tag ? '<span class="dim">' + esc(c.tag) + "</span> " : ""}${c.size ? '<span class="dim">' + esc(c.size.toLowerCase()) + "</span> " : ""}<b>${esc(c.name)}</b>` +
  ["shiny", "sparkling", "glitched"].filter(k => c[k]).map(k => ` <span class="mut">*${k}</span>`).join("");
let S = null;
let all = [];
let allFrom = 0;

function bars(el, items, color) {
  if (!items.length) { el.innerHTML = '<div class="empty">nothing yet</div>'; return; }
  const max = Math.max(...items.map(i => i.n));
  el.innerHTML = items.map(i => `<div class="row"><span class="lbl" title="${esc(i.label)}">${i.html || esc(i.label)}</span>
    <span class="track"><span class="fill" style="display:block;width:${(i.n / max * 100).toFixed(1)}%;background:${i.color || color}"></span></span>
    <span class="n">${num(i.n)}</span></div>`).join("");
}

function chart(canvas, pts, color) {
  const dpr = window.devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
  canvas.width = w * dpr; canvas.height = h * dpr;
  const g = canvas.getContext("2d");
  g.scale(dpr, dpr); g.clearRect(0, 0, w, h);
  const css = getComputedStyle(document.body);
  g.font = "11px system-ui"; g.fillStyle = css.getPropertyValue("--dim");
  if (pts.length < 2) { g.fillText("a point every 30 s - check back in a minute", 8, h / 2); return; }
  const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
  const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
  const L = 64, R = 10, T = 10, B = 22;
  const X = x => L + (x - x0) / Math.max(1, x1 - x0) * (w - L - R);
  const Y = y => T + (1 - (y - y0) / Math.max(1e-9, y1 - y0)) * (h - T - B);
  g.strokeStyle = css.getPropertyValue("--line"); g.lineWidth = 1;
  g.beginPath(); g.moveTo(L, T); g.lineTo(L, h - B); g.lineTo(w - R, h - B); g.stroke();
  g.fillText(big(y1), 4, T + 8); g.fillText(big(y0), 4, h - B - 4);
  g.fillText(clock(x0), L, h - 6); const e = clock(x1); g.fillText(e, w - R - g.measureText(e).width, h - 6);
  g.strokeStyle = color; g.lineWidth = 2; g.beginPath();
  pts.forEach((p, i) => i ? g.lineTo(X(p[0]), Y(p[1])) : g.moveTo(X(p[0]), Y(p[1])));
  g.stroke();
}

function render() {
  if (!S) return;
  const s = S, n = s.numbers || {}, b = s.base || {}, st = s.stats || {};
  $("who").textContent = `${s.player || ""} - v${s.v || "?"}`;
  $("phase").textContent = `${s.autoFish ? "Farming" : "Auto fish off"} - ${s.phase || ""}${s.note ? " - " + s.note : ""}`;
  const hrs = (s.farm || 0) / 3600;
  $("k-caught").textContent = num(st.caught);
  $("k-caught-s").textContent = `${hrs > 0.02 ? num(st.caught / hrs) + " / hr - " : ""}${st.bonus ? "+" + num(st.bonus) + " extra/duplicate - " : ""}lost ${num(st.lost)}${st.unreadFish ? " - " + st.unreadFish + " unread" : ""}`;
  const dc = (n.coins != null && b.coins != null) ? n.coins - b.coins : null;
  $("k-coins").textContent = big(n.coins); $("k-coins").title = num(n.coins) + " C$";
  $("k-coins-s").textContent = `${signed(dc)} this session${hrs > 0.02 && dc != null ? " - " + signed(dc / hrs) + " / hr" : ""}`;
  $("k-level").textContent = num(n.level);
  const dx = (n.xp != null && b.xp != null) ? n.xp - b.xp : null;
  $("k-level-s").textContent = `xp ${signed(dx)}${hrs > 0.02 && dx != null ? " - " + signed(dx / hrs) + " / hr" : ""}`;
  $("k-farm").textContent = dur(s.farm);
  $("k-farm-s").textContent = `script up ${dur(s.uptime)} - casts ${num(st.casts)}${st.lastCycle ? " - " + st.lastCycle.toFixed(1) + " s/fish" : ""}`;
  const d = k => (n[k] != null && b[k] != null) ? n[k] - b[k] : 0;
  $("k-special").textContent = num(d("mutations") + d("shiny") + d("sparkling"));
  $("k-special-s").textContent = `mutated ${num(d("mutations"))} - shiny ${num(d("shiny"))} - sparkling ${num(d("sparkling"))}`;
  const ic = s.ic || {};
  $("k-ic").textContent = s.instantCatch ? `${num(ic.acquired)}/${num(ic.reels)}` : "off";
  $("k-ic-s").textContent = s.instantCatch ? `reels hooked - ${ic.status || ""}` : "";

  const disc = s.disconnect;
  $("banner").style.display = disc ? "block" : "none";
  if (disc) $("banner").innerHTML = `<b>${esc(disc.title || "Disconnected")}</b> at ${clock(disc.t)} - ${esc(disc.message || "")}<div class="dim" style="font-size:12px;margin-top:4px">${esc(s.alertStatus || "")}</div>`;
  const r = s.reeling;
  $("reel").style.display = r ? "block" : "none";
  if (r) $("reel").innerHTML = `Reeling: ${r.mutation ? '<span class="mut">' + esc(r.mutation) + "</span> " : ""}<b>${esc(r.name)}</b> ${kg(r.weight)} ${tag(r.rarity || rarityOf[r.name])}`;

  const rows = arr(s.recent);
  $("recent").innerHTML = rows.length ? rows.map(c => `<tr><td>${clock(c.t)}</td><td class="name">${fishLabel(c)}</td>
    <td>${tag(c.rarity || rarityOf[c.name])}</td><td>${kg(c.weight)}</td><td class="mut">${esc(c.mutation || "")}</td><td class="dim">${esc(c.odds || "")}</td><td class="dim">${esc(c.spot || "")}</td></tr>`).join("")
    : '<tr><td colspan="7" class="empty">no catches read yet this session</td></tr>';

  bars($("byfish"), arr(s.counts).map(c => { const ra = c.rarity || rarityOf[c.name];
    return { label: c.name, n: c.n, color: RCOLOR[ra] || "var(--bar)", html: esc(c.name) }; }), "var(--bar)");
  const byR = {};
  arr(s.counts).forEach(c => { const ra = c.rarity || rarityOf[c.name] || "unknown"; byR[ra] = (byR[ra] || 0) + c.n; });
  bars($("byrarity"), Object.keys(byR).sort((a, c) => rank(c) - rank(a)).map(k => ({ label: k, n: byR[k], color: RCOLOR[k] || "#57606a" })));
  const byM = {};
  rows.forEach(c => { if (c.mutation) byM[c.mutation] = (byM[c.mutation] || 0) + 1; });
  bars($("bymut"), Object.keys(byM).sort((a, c) => byM[c] - byM[a]).slice(0, 12).map(k => ({ label: k, n: byM[k] })), "var(--warn)");

  const a = s.afk || {};
  const loc = s.location || {};
  const items = [
    ["Mode", `${s.mode || ""} - ${s.castStyle || ""} cast`], ["Rod", `${s.rod || "none"}${s.rodState ? " (" + s.rodState + ")" : ""}`],
    ["Instant catch", ic.status || "off"],
    ["Anti-AFK", a.on ? `${a.status || ""}${a.taps ? " - " + a.taps + " taps" : ""}` : "off"],
    ["Location", `${loc.spot || "-"}${loc.x != null ? "  (" + loc.x + ", " + loc.y + ", " + loc.z + ")" : ""}`],
    ["Webhook", s.hook || ""], ["Aurora totems", s.aurora || ""], ["Fish info", s.fishStatus || ""],
  ];
  if (s.manual) items.unshift(["Paused", s.manual]);
  if (s.blocked) items.unshift(["Blocked", s.blocked]);
  $("status").innerHTML = items.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("");

  $("log").textContent = arr(s.log).slice().reverse().join("\n");
  const smp = arr(s.samples);
  chart($("c-caught"), smp.filter(p => p.caught != null).map(p => [p.t, p.caught]), getComputedStyle(document.body).getPropertyValue("--accent"));
  chart($("c-coins"), smp.filter(p => p.coins != null).map(p => [p.t, p.coins]), getComputedStyle(document.body).getPropertyValue("--good"));
}

function renderAll() {
  const el = $("alltime");
  if (!all.length) { el.innerHTML = '<div class="empty">no catches logged yet - they are added as you fish</div>'; $("best").innerHTML = ""; return; }
  const named = all.filter(c => c.name && c.name !== "unknown");
  const species = {}; named.forEach(c => species[c.name] = (species[c.name] || 0) + 1);
  const byR = {}; named.forEach(c => { const r = c.rarity || rarityOf[c.name] || "unknown"; byR[r] = (byR[r] || 0) + 1; });
  const muts = named.filter(c => c.mutation).length;
  el.innerHTML = `<dl><dt>Catches logged</dt><dd>${num(all.length)} since ${day(all[0].t)}</dd>
    <dt>Different fish</dt><dd>${num(Object.keys(species).length)}</dd>
    <dt>Mutated</dt><dd>${num(muts)} (${named.length ? (muts / named.length * 100).toFixed(1) : 0}%)</dd></dl><div style="height:10px"></div><div id="allr"></div>
    <h2 style="margin-top:14px">Most caught</h2><div id="allf"></div>`;
  bars($("allr"), Object.keys(byR).sort((a, c) => rank(c) - rank(a)).map(k => ({ label: k, n: byR[k], color: RCOLOR[k] || "#57606a" })));
  bars($("allf"), Object.keys(species).sort((a, c) => species[c] - species[a]).slice(0, 10)
    .map(k => ({ label: k, n: species[k], color: RCOLOR[rarityOf[k]] || "var(--bar)" })));
  const best = named.slice().sort((x, y) => {
    const rx = rank(x.rarity || rarityOf[x.name]), ry = rank(y.rarity || rarityOf[y.name]);
    return (ry - rx) || ((y.mutation ? 1 : 0) - (x.mutation ? 1 : 0)) || ((y.weight || 0) - (x.weight || 0)); }).slice(0, 25);
  $("best").innerHTML = best.map(c => `<tr><td>${day(c.t)}</td><td class="name">${fishLabel(c)}</td><td>${tag(c.rarity || rarityOf[c.name])}</td>
    <td>${kg(c.weight)}</td><td class="mut">${esc(c.mutation || "")}</td></tr>`).join("");
}

async function pollState() {
  try {
    const res = await fetch("/state", { cache: "no-store" });
    const j = await res.json();
    const live = $("live");
    if (j.missing) { live.className = "pill dead"; live.textContent = "no data - is FischHub running with its dashboard feed on?"; }
    else if (j.state && j.state.unloaded) { live.className = "pill dead"; live.textContent = "FischHub unloaded"; }
    else {
      S = j.state;
      live.className = "pill " + (j.age < 8 ? "live" : j.age < 60 ? "stale" : "dead");
      live.textContent = j.age < 8 ? "live" : `last update ${dur(j.age)} ago`;
      render();
    }
  } catch (e) { /* the file was mid-write; next poll */ }
  setTimeout(pollState, 2000);
}

async function pollCatches() {
  try {
    const res = await fetch("/catches?from=" + allFrom, { cache: "no-store" });
    const next = Number(res.headers.get("X-Next") || 0);
    const text = await res.text();
    if (next < allFrom) { all = []; }
    const cut = text.lastIndexOf("\n");
    if (cut >= 0) {
      text.slice(0, cut).split("\n").forEach(l => { try { if (l.trim()) all.push(JSON.parse(l)); } catch (e) {} });
      allFrom = (next < allFrom ? 0 : allFrom) + new TextEncoder().encode(text.slice(0, cut + 1)).length;
    }
    renderAll();
  } catch (e) {}
  setTimeout(pollCatches, 10000);
}

async function pollInfo() {
  try { const j = await (await fetch("/fishinfo", { cache: "no-store" })).json(); rarityOf = j.rarity || {}; render(); renderAll(); } catch (e) {}
  setTimeout(pollInfo, 60000);
}

async function helper(on) {
  try {
    const j = await (await fetch("/helper" + (on == null ? "" : "?afk=" + (on ? 1 : 0)), { cache: "no-store" })).json();
    $("helper").checked = !!j.afk; $("helper-s").textContent = "AFK helper: " + (j.afkNote || "");
    $("watch-s").textContent = "Disconnect watchdog: " + (j.watch || "");
    $("shot-s").textContent = "Screenshots: " + (j.shot || "");
  } catch (e) {}
}
$("helper").addEventListener("change", e => helper(e.target.checked));
setInterval(() => helper(), 5000);
window.addEventListener("resize", render);
helper(); pollInfo(); pollState(); pollCatches();
</script>
</body>
</html>
'@
$HtmlBytes = [Text.Encoding]::UTF8.GetBytes($Html)

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

function Get-Roblox {
  return Get-Process -Name 'RobloxPlayerBeta' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}

# A JPEG of the Roblox window, or $null (the reason goes to the page).
function Take-Shot {
  if (-not $script:CanShot) { $script:ShotNote = 'not available on this PC'; return $null }
  $rb = Get-Roblox
  if (-not $rb) { $script:ShotNote = 'skipped - no Roblox window'; return $null }
  $img = [FHShot]::Capture($rb.MainWindowHandle, 1280)
  if (-not $img) { $script:ShotNote = 'skipped - ' + [FHShot]::Why; return $null }
  $script:ShotNote = 'last one ' + (Get-Date -Format 'HH:mm:ss') + ' (' + [int]($img.Length / 1024) + ' KB)'
  return ,$img
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

  if ($method -eq 'POST') { Relay $stream $path $query $body; return }
  if ($method -ne 'GET') { Send-Text $stream 404 'text/plain' 'GET or POST only'; return }
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
    '/fishinfo' {
      $r = Read-Shared $InfoFile
      if (-not $r) { Send-Text $stream 200 'application/json' '{}'; return }
      Send $stream 200 'application/json; charset=utf-8' $r.bytes
      return
    }
    '/helper' {
      if ($query -match '(^|&)afk=([01])') {
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
