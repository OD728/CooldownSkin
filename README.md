# Cooldown Skin

**A cleaner look for the game's Cooldown Manager**, made for WoW: Forever.

- Square, cropped icons in a black border for Essential, Utility and Tracked Buff icons.
- While your debuff (or buff) is up, the yellow wash is gone: the icon stays bright, the
  border takes your class color, and a dark swipe grows as it runs out.
- A thin class-colored timer bar above the icon while the debuff is up.
- Outlined timer numbers sized to the icon.

The Cooldown Manager's layout, spells and Edit Mode settings stay the game's own.
Nothing secret is read: the game client fills the swipe and the timer bar itself.

## Install

Copy this repository's files into a folder named `CooldownSkin` inside
`World of Warcraft\_forever_\Interface\AddOns\`.

## Commands

| Command | What it does |
| --- | --- |
| `/cskin` | List the options |
| `/cskin color class` | Border in your class color while the debuff is up |
| `/cskin color 150 80 230` | A color of your own instead |
| `/cskin border 0-4` | Border thickness in pixels |
| `/cskin bar top \| bottom \| off` | Where the timer bar goes, or none |
| `/cskin barheight 1-12` | Timer bar height in pixels |
| `/cskin reverse` | Flip which way the debuff swipe runs |
| `/cskin dark 0-1` | Swipe darkness while the debuff is up |
| `/cskin text 0.2-0.8` | Timer number size |
| `/cskin reset` | Back to the defaults |

Space between the icons is the game's own setting: in Edit Mode, select the
cooldown row and change its Icon Padding.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
