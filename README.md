# Deep Fishing hub

A Matcha script for Deep Fishing, using the [INSUI](https://github.com/neaxusxgod-png/INS-ui) menu.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Sxowy/fish/main/main.lua"))()
```

`P` opens the menu. `F6` toggles auto cast.

## Features

**Fishing**
- Auto cast: holds the throw for exactly the Perfect (or Good) zone, then waits a cooldown and casts again.
- Auto fight: clicks through catch fights at up to 12 clicks a second, which is the game's cap.
- Auto steer: moves the bait under the rarest fish in the school, ranked by the odds in the Index. It can also chase item drops (enchant stones, baits, chests) and avoid junk.
- Fish ESP: name and odds over every fish in the school, colored by rarity.

**Session**
- Casts, catches, fights won, money earned and spent, per-hour rates, best catch and a rarity breakdown.
- Alerts when an event starts and when you land a rare fish.
- A floating stats box that stays on screen with the menu closed.

## Notes

- Automation only runs while the menu is closed and Roblox is the focused window. The menu holds game input back while it is open.
- If throws keep landing Good instead of Perfect, adjust **Timing offset**: raise it if the throws are early, lower it if they are late.
- Running it again unloads the previous copy first.
- AutoSell currently doesnt work. Im working on seeing if im able to get that working without having to buy the gamepass
