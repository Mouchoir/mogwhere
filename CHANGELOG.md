# Changelog

## 0.3.0

### Quiet mode

AllTheThings is an excellent collection tracker and a dense one. Somebody who
installs MogWhere for the wardrobe panel gets the minimap button, the world map
button, tooltip lines on every item, windows and sounds along with it.

- `/mw quiet` silences all of that, `/mw quiet on` and `/mw quiet off` state it
  explicitly, and there is a checkbox in `/mw options`.
- **Your AllTheThings settings are never modified.** Quiet mode copies your
  current profile into one named MogWhere, switches to it, and only then mutes
  anything. Every write lands in that profile. Yours stays exactly as it was, is
  still listed in ATT's own settings, and coming back is a single profile switch.
- The question is asked once, the first time AllTheThings is detected, with both
  consequences spelled out. `/mw quiet ask` reopens it.
- The current state is read from AllTheThings rather than remembered, so the
  checkbox cannot disagree with ATT's own profile page, on any character.

### Fixed

- The slash parser only ever read the first word, so every command argument was
  silently discarded.

## 0.2.1

- The package no longer ships `docs/`. The CurseForge description travelled
  inside 0.2.0 and landed in every player's AddOns folder, which is a marketing
  document in a place nobody asked for one.

## 0.2.0

### The star follows what you have to kill

- Creature ids were only ever exposed on recipe offers, so a rare holding the
  appearance itself was never marked. They are now on every offer, and the star
  falls back to the first one when there is no vendor or quest giver to aim at.
- Nothing cleared the star on a kill. The five interaction events are all
  conversations, so the marker hung around until the poll gave up a quarter of an
  hour later. `UNIT_DIED` from the combat log closes it, matched on the creature
  id inside `destGUID`.

### The panel names the kill

- A boss inside an instance was named twice over, by the client drop lines and by
  the place. A rare standing in a field was in neither, so the panel printed its
  coordinates without ever saying whose they were. It now reads "dropped by Go
  Kan", and stays quiet when an encounter is already named.

### Packaging

- The CurseForge project id is declared in the toc, so a tagged release publishes
  there as well as on GitHub.

## 0.1.0

First release. Mists of Pandaria Classic.

### The panel

- Source detail on hover in the Appearances tab, in a frame of its own rather
  than injected into `GameTooltip`.
- Follows the client's own Tab selection between the items sharing an appearance.
- Boss drops: instance, encounter and every difficulty, not just the first.
- Vendors: name, zone, coordinates and price in gold, currency or items, with
  names resolved rather than ids printed.
- Quests: title and quest giver.
- Professions: recipe, required skill level, and the creature that drops the
  recipe when it is not sold.
- Achievements: name, description and live progress, listing the criteria still
  missing rather than the ones already earned.
- Reputation gates stated with both halves, the requirement and where you stand.
- Faction handling: the other side is hidden when your own is available, and
  named with its equivalent when it is not.

### Actions

- Alt click sets a TomTom waypoint on your own faction's source.
- Middle click gives the Wowhead link for the right flavor and locale.
- A star marks the target's nameplate, and clears itself on interaction.
- A notice when the destination is on another continent, where TomTom can give
  no bearing.

### Around it

- `/mw census` measures which layer can locate each appearance on your account.
- Optional dependencies are detected in three states, absent, disabled or
  present, with an enable and reload button for the middle one.
- Options panel with a standing reminder for anything missing.
