# Backpack

Use food, drinks, boosters, skill shards, recipes and eddie shards in Cyberpunk 2077 from an overlay list, without the backpack screen that pauses the game. Single-player only.
Version 1.0.1 | Built on game version 2.31 | Status: 1.0.0 failed its in-game test (items were used by themselves); 1.0.1 fixes that cause and is in use in my game and working; no written test record

> This is an unofficial fan work and is not approved/endorsed by CD PROJEKT RED. No game files are included.

## The problem

Eating or drinking through the backpack screen pauses the game and takes several clicks. Doing it on the move, in a car or between two fights means opening a full-screen menu each time.

## What I built

A Cyber Engine Tweaks script (719 lines of Lua) that lists every item the backpack lets you "Use" and uses one on click, while the game keeps running. It changes: nothing in the game's data. It uses items through the backpack's own path, and it adds an on-screen list that hotkeys can step through with the overlay closed.

## How it works

- **Which items.** The same test the backpack uses for its "Use" button: the item has a Consume, Eat, Drink, Learn or DownloadFunds action. Inhalers and injectors are left out, as in the backpack. Stacks of the same item are merged; each item record is classified once and cached.
- **Using an item.** `ItemActionsHelper.PerformItemAction`, the call the backpack makes. Mods that react to consumed items, such as Dark Future, see the use as usual. A short pause between uses (default 0.6 s) stops a double click from using two.
- **In the CET overlay.** Window "Backpack" with category, sort and search; click an item to use it. The overlay takes the mouse, so the player stands still while it is open, but the world does not pause.
- **With the overlay closed.** Hotkeys show a list and step through it, use the selected item or switch category. The list takes no input, so you keep moving, aiming and driving. It hides in menus and scenes.
- **Rules.** "Follow the backpack's use rules" asks the game the same question the backpack asks before using an item (in the base game: no consumables in combat; Dark Future replaces that rule with its own). If that call fails from CET, a Lua copy of the base game's combat rule is used. "World checks" also blocks use while carrying a body, during a melee attack or in a fist fight. Use is always blocked with no game loaded, in menus and in scenes.
- Nothing here changes time dilation.

```text
package/
  bin/x64/plugins/cyber_engine_tweaks/mods/CyberslopBackpack/init.lua
```

## Requirements

| Requirement | Version | Link |
|---|---|---|
| Cyberpunk 2077 | built on 2.31; not tested on 2.5 | |
| Cyber Engine Tweaks | a build for your game version | [Nexus Mods, mod 107](https://www.nexusmods.com/cyberpunk2077/mods/107) |
| Dark Future (optional) | | [Nexus Mods, mod 16300](https://www.nexusmods.com/cyberpunk2077/mods/16300) |

With Dark Future installed, its rules decide what may be used in combat. Requirements are not bundled. Install them first.

## Install

1. Install the requirements above.
2. Copy the contents of `package/` into the game folder, so that `bin\x64\plugins\cyber_engine_tweaks\mods\CyberslopBackpack\init.lua` exists.
3. Start the game, load a save and open the CET overlay: the "Backpack" window lists your usable items.

## Uninstall / roll back

1. Close the game.
2. Delete `bin\x64\plugins\cyber_engine_tweaks\mods\CyberslopBackpack\` (also removes `config.json` and `CyberslopBackpack.log`).
3. Saves are not affected: the mod stores nothing in the save.

## Configuration

In the window, saved in `config.json` next to `init.lua`:

| Option | Default (range) |
|---|---|
| Follow the backpack's use rules (combat, Dark Future) | on |
| World checks (carrying a body, melee attack, fist fight) | on |
| Play the backpack's eat sound | on |
| Show the item name on screen after use | on |
| Close the on-screen list after a use | off |
| Show this window when the CET overlay opens | on |
| On-screen list rows | 10 (3 to 30) |
| On-screen list background | 0.55 (0 to 1) |
| Seconds between uses | 0.6 (0 to 3) |

Hotkeys in CET > Bindings, all unbound by default: "Backpack list on/off", "Backpack list: next item (opens the list)", "Backpack list: previous item (opens the list)", "Backpack list: use selected item (opens the list)", "Backpack list: next category (opens the list)".

Console commands in the CET console: `GetMod("CyberslopBackpack").list()`, `.use("name part")`, `.status()`. Two more were added in 1.0.1 to give back items that the 1.0.0 fault used up: `.find("exact name")` lists the item records with that name, and `.restore("exact name", count)` adds that many to the inventory (with several records of the same name, pass the number from `.find` as a third value).

## Status

| Version | Game | Result |
|---|---|---|
| 1.0.0 | 2.31 | Failed in game, 2026-11-01: items were used by themselves (45 uses in about one minute). |
| 1.0.1 | 2.31 | Fix for that cause. In use in the author's game and working (author's statement, 2026-11-24). No written test record. An offline mock test with 61 checks passed at the time; that test script was a temporary file and is not part of this repository. |

Not tested on game version 2.5.

## Known issues

- Version 1.0.1 has no written in-game test record; the fix rests on the author's use in game.
- Every use and every refused use is written to `CyberslopBackpack.log`. Repeated refusals for the same item are written at most every 2 seconds.
- Not proven before an in-game run: whether the game's own use-rule check can be called from CET (there is a fallback), and whether the on-screen list really takes no input.

## Engineering notes

**Problem.** In the first in-game test of 1.0.0, items were used by themselves. Right after loading a save, the first item in the list (alphabetical) was used as soon as the overlay opened. Clicking another item moved the repeating use to that item. The log showed 45 uses in a little over a minute, each about 1.5 seconds apart.

**Diagnosis.** CET's `ImGui.Selectable(label, selected)` returns the row's selected state on every frame, not "was clicked". 1.0.0 passed "this is the selected row" as `selected`, so the selected row reported a click on every frame. The uses were 1.5 seconds apart only because the eating animation counts as a scene, which correctly held the next use back until it ended. The mock test of 1.0.0 had stubbed `Selectable` as click-only, so it missed this.

**Fix.** Rows always pass `false`, so `Selectable` is true only on the frame of a click, and the selected row is shown by text colour instead. A click must also be a new press (a row that reports a click on consecutive frames counts once). No click counts in the first 0.25 seconds after the overlay opens. The same "not used" message for the same item is logged and shown at most every 2 seconds (1.0.0 wrote 814 such lines in that minute).

**Check.** The mock test was changed to stub `Selectable` as CET behaves. 1.0.1 passed all 61 checks; the same test on 1.0.0 failed exactly the new checks for uses without a click.

**Rollback.** 1.0.0 was installed with a backup. For a user: delete the mod folder.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Latest: 1.0.1 (2026-11-01): items are used only on a real click.

## Credits and licence

Runs on Cyber Engine Tweaks, which is not included here.

MIT, see [LICENSE](LICENSE). The licence covers my code only. Game names and trademarks belong to their owners.

Built with AI assistance (Claude); designed, tested and maintained by me.
