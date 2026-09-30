# FischHub

A Fisch script for the **Matcha** executor.

## Load it

Join Fisch, then run this in Matcha:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/adorablewhale/fischhub/main/fischhub.lua"))()
```

Running it again replaces the running copy, so reinjecting is safe.

**Auto-execute:** save that line as a `.lua` file in Matcha's auto-execute folder. It only runs in Fisch, and it waits for the game to finish loading. Or use the INSUI loader: put `loader.lua` from [adorablewhale/insui](https://github.com/adorablewhale/insui) in the auto-execute folder once, and switch scripts on or off in the gear tab > **Auto-execute**.

## Keys

| Key | Action |
|---|---|
| `P` | open or close the menu |
| `F1` | Auto Fish |
| `F2` | Instant Catch |

- **Rebind:** click the key chip on a toggle to change its key (Esc clears it).
- **Key mode:** right-click the chip to pick **Hold**, **Toggle** or **Always**.

## Tabs

- **Fishing**
  - Auto Fish casts, shakes and recasts on its own.
  - Instant Catch lands the fish about 2 s into the reel.
  - **Mode:**
    - **Hybrid** needs Matcha's Hybrid Mode on.
    - **Non-hybrid** uses mouse and keyboard only. Keep Roblox focused and the menu closed while it farms.
- **Teleports:** a checked spot for every area in the game, filtered by region, plus spots you save yourself. Teleports are blocked while Auto Fish runs.
- **Totems:** Aurora Totem ESP, and Auto Buy for Aurora Totems.
  - Each totem costs **500,000 C$**, and Auto Buy is off every time the script loads.
  - Set **Keep at least** so it never spends money you want to keep.
- **Webhook:** posts your session stats to a Discord channel.
  1. Paste the webhook URL into `workspace/Fisch/FischHub/webhook.txt`.
  2. Press **Load URL from file**.
- **Settings:** Anti-AFK, the dashboard feed, unloading the script, and the theme and other UI options (gear tab).

Your settings save by themselves to Matcha's `workspace/Fisch/FischHub` folder (the menu's look goes to `workspace/INSUI/FischHub`). Updating from an older version copies your settings over from `workspace/FischHub` once; the old folder is left alone and can be deleted.

**Menu:** `P` opens and closes it. The minimize button hides it completely, and `P` brings it back.

## What you caught

Every fish is logged with its name, size, mutation, weight, rarity and odds, as the game announces it,
for example `caught extra: giant Soultorn Petal Ray 572.2kg [mythical] (1/3)`. The Fishing tab and the
on-screen box show your last catch.

- One cast can give up to three fish: the catch, a **Duplicate!** copy and an **Extra!** fish. All of
  them are logged. The *Caught* number is the game's own counter, which counts only the first.
- The first time you catch something, the script looks up fish rarities once. The game pauses for a few
  seconds while it does; after that they're saved and it doesn't happen again.

## Anti-AFK

Roblox disconnects you after 20 minutes without any key press or click. In Hybrid mode the script casts
without clicking, so a long session can look idle. **Anti-AFK** (Settings tab, on by default) taps
**O then I** (the camera zooms out a notch and back) when nothing has reached Roblox for a few minutes.

- It only works while Roblox is the focused window.
- For Roblox in the background, turn on the **AFK helper** in the FischHub helper (below).

## FischHub helper (optional)

Download [`fischhub-helper.bat`](fischhub-helper.bat) from this repo (open it, press **Raw**, then save).
Double-click it and leave its window open while you play. It only listens on your own PC (127.0.0.1).

- **Dashboard:** your browser opens `http://127.0.0.1:47210`. It shows fish this session and per hour
  with a live chart, C$/XP gained, the fish on the line, and your rarest and heaviest catch. It also
  has a filterable list of every fish (size, rarity, mutation, weight, odds), rarity and mutation
  breakdowns, and all-time stats from every session. Dark and light themes.
- **Settings from the page:** turn Auto Fish and Instant Catch on or off, and change every FischHub
  setting (fishing, webhook, totems, anti-AFK). Changes apply right away and are saved, just like the
  menu. You can also paste your webhook URL there, since Matcha's menus can't paste.
- **Roblox view:** a live picture of your Roblox window on the page, every 3 s (you can pause it). It
  only ever captures the Roblox window, never anything else on your screen. Only the page the helper
  opens can change settings or take pictures; other websites can't.
- **Webhook edits:** keeps updating one Discord message instead of posting a new one each time.
- **Screenshots:** with **Screenshot in webhook** on (Webhook tab), each message gets a picture of your
  Roblox window. It only ever captures Roblox.
- **Disconnect alert:** if Roblox or Matcha closes or crashes while you're farming, it posts to your
  webhook.
- **AFK helper:** off by default; switch it on in the dashboard page. When Roblox is idle in the
  background, it briefly brings Roblox to the front, taps O/I and switches back. It only does this while
  you're not typing or moving the mouse, and at most once a minute.

If your Matcha workspace isn't `C:\matcha\workspace`, drag the workspace folder onto the .bat. It
replaces the old `webhook-relay.bat`, so close that one first.

## Webhook

By default the webhook keeps editing **one** Discord message instead of posting a new one every update.

- **Needs the helper:** Discord only edits messages with a PATCH request, and Matcha can't send one. The
  [FischHub helper](#fischhub-helper-optional) turns the script's request into that PATCH. Without it,
  every update posts a new message.
- **Checking it:** in the Webhook tab, **Check relay** shows whether the helper is running, and **Start a
  new message** begins a fresh one.
- **Disconnect alerts:** when Roblox shows its "Disconnected" or kick message, the script posts a new
  message with the reason, so Discord notifies you. Turn it off with **Alert on disconnect**.
- **Pings:** put your Discord user ID (or `everyone`) in **Ping on alerts** to be pinged. Pasting doesn't
  work in the menu, so you can also add a line `ping: <your id>` to `webhook.txt` and press **Load URL
  from file**. **Test alert** sends a sample.

## If Roblox or Fisch updates

Instant Catch reads a few memory positions that can move after an update. They're saved in `workspace/Fisch/FischHub/offsets.json` with the Roblox version they were checked on. After a Roblox update, the script checks them once, fixes any that moved, and saves them again. You don't need to do anything. The Debug tab shows the status, and **Recheck offsets** forces a new check.
