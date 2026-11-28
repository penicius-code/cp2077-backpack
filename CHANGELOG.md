# Changelog

1.0.0 and 1.0.1 were built on game version 2.31; 1.1.0 and later are for 2.5.

## 1.2.2 - 2026-11-26
### Added
- Notes and the Medical > Mind and humanity group for the humanity items of Cyberslop Merc Stims; Rejectol's note reads "-15 % humanity damage".

## 1.2.1 - 2026-11-26
### Added
- The hover box shows the same effect lines as the inventory tooltip (the item's OnAttach / OnEquip UI data with its numbers filled in), above the flavour text. Lines with a negative number are red, so a side effect like "-40 Energy" stands out before use.

## 1.2.0 - 2026-11-26
### Added
- All and Boosters tabs side by side at the top of the window; the Boosters tab shows its count. The All tab leaves boosters out; a search in All still finds them.
- Notes for the Cyberslop Merc Stims items.
### Fixed
- Street drugs that are long-lasting items (Crank, Black Lace and others) landed in the wrong group.

## 1.1.0 - 2026-11-25
### Added
- Items grouped under collapsible headers: Medical (clinic cures, injury care, mind and humanity, addiction and recovery, boosters, other medicine), Vices (smokes, alcohol, street drugs, drug-making materials), Drinks, Food (by nutrition tier), other consumables, shards and recipes, eddie shards. Groups come from the item record (tags, consumable base, item type), not from name guessing.
- A grey note per row on what the item is for; the category box selects a section; search also matches notes and group names.
- Open / closed state of each header is saved; Options has "Open all groups", "Close all groups" and "Show what each item is for".
### Changed
- Sort (Name / Count) applies inside each group. An old config's categories and sort fall back to All and Name.

1.1.0 to 1.2.2 are for game version 2.5. Installed in the author's game; no written test record. Offline mock test: 55 of 55 (1.2.2).

## 1.0.1 - 2026-11-01
### Fixed
- Items were used by themselves. CET's `ImGui.Selectable` returns the row's selected state on every frame, not "was clicked"; 1.0.0 treated it as a click. Rows now count only a real, new click, and no click counts in the first 0.25 seconds after the overlay opens.
### Changed
- The same "not used" message for the same item is logged and shown at most every 2 seconds.
- The "Used" log line names the item record.
### Added
- Console commands `find` and `restore` to give back items that the 1.0.0 fault used up.

In use in the author's game and working; no written test record.

## 1.0.0 - 2026-11-01
- First version: overlay window and on-screen list to use backpack items without pausing the game.

Failed in game: items were used by themselves.
