# FischHub

A Fisch script for the **Matcha** executor.

## Load it

Join Fisch, then run this in Matcha:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/j5cks/fischhub/main/fischhub.lua"))()
```

Running it again replaces the running copy, so reinjecting is safe.

**Auto-execute:** save that line as a `.lua` file in Matcha's auto-execute folder. It only runs in Fisch, and it waits for the game to finish loading.

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
  1. Paste the webhook URL into `workspace/FischHub/webhook.txt`.
  2. Press **Load URL from file**.
- **Settings:** unload the script, and change the theme and other UI options (gear tab).

Your settings save by themselves to Matcha's `workspace/FischHub` folder.
