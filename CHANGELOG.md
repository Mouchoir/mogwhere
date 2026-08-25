# Changelog

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
