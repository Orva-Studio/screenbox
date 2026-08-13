# ScreenBox

A tiny macOS menu bar app for drawing highlight boxes on screen while recording or presenting.

Press a hotkey, drag a box around whatever you're talking about, and it fades away on its own. No editing pass, no timeline annotations.

## Build

```bash
./build.sh
open build/ScreenBox.app
```

Requires the Swift toolchain (Xcode or Command Line Tools). No dependencies.

To keep it around: drag `build/ScreenBox.app` to `/Applications` and add it to
**System Settings → General → Login Items**.

## Use

**⌃⌥⌘B** toggles draw mode on whichever screen the mouse is on.

While drawing:

| Key | Action |
| --- | --- |
| drag | draw a box |
| `1`–`4` | blue / red / green / yellow |
| `[` `]` | thinner / thicker stroke |
| `−` `=` | less / more corner radius |
| `F` | toggle fade-out on/off |
| `⌘Z` | undo last box |
| `C` | clear all, stay in draw mode |
| `esc` | clear and exit draw mode |

## Preferences

Colour, thickness, corner radius, fade speed, and fade on/off all live in the
menu bar and are **saved automatically** — change them however you like and
they'll be the same next launch. Keyboard changes made mid-draw persist too.

Defaults: yellow, 4pt, square corners, fast fade.

Preferences are stored in `UserDefaults` under `local.screenbox`. To reset
everything:

```bash
defaults delete local.screenbox
```

### Adding a preference

`Sources/Prefs.swift` is the single source of truth. Add a `Key` case, a
computed property, and a default in `register(defaults:)`. Because every write
fires `onChange`, the menu re-ticks and the live overlay redraws with no extra
wiring.

## Notes

- The overlay window only exists while draw mode is active, so it never
  intercepts clicks when you're working normally.
- While draw mode *is* active the overlay swallows clicks on that screen — press
  `esc` before advancing slides.
- Boxes are stroked with a dark halo so they stay readable on light and dark
  backgrounds.
- Uses a Carbon hotkey, so no Accessibility permission is required.
- Draws over normal windows but not over fullscreen apps.

## Fade speed presets

| Preset | Hold | Fade |
| --- | --- | --- |
| Instant | 0s | 0.15s |
| Fast (default) | 0.15s | 0.2s |
| Medium | 0.35s | 0.4s |
| Slow | 1.0s | 0.8s |

Edit `Prefs.speedChoices` in `Sources/Prefs.swift` to change or add presets.
