# Changelog

Both versions were built on game version 2.31.

## 1.0.1 - 2026-11-01
### Fixed
- Items were used by themselves. CET's `ImGui.Selectable` returns the row's selected state on every frame, not "was clicked"; 1.0.0 treated it as a click. Rows now count only a real, new click, and no click counts in the first 0.25 seconds after the overlay opens.
### Changed
- The same "not used" message for the same item is logged and shown at most every 2 seconds.
- The "Used" log line names the item record.
### Added
- Console commands `find` and `restore` to give back items that the 1.0.0 fault used up.

Not run in game.

## 1.0.0 - 2026-11-01
- First version: overlay window and on-screen list to use backpack items without pausing the game.

Failed in game: items were used by themselves.
