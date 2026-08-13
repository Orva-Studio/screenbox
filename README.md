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
| `F` | toggle fade-out on/off |
| `⌘Z` | undo last box |
| `C` | clear all, stay in draw mode |
| `esc` | clear and exit draw mode |

With fade on (the default) a box holds briefly then eases out. With it off, boxes
persist until you clear them. The setting lives in the menu bar and persists
across restarts.

## Notes

- The overlay window only exists while draw mode is active, so it never
  intercepts clicks when you're working normally.
- While draw mode *is* active the overlay swallows clicks on that screen — press
  `esc` before advancing slides.
- Boxes are stroked with a dark halo so they stay readable on light and dark
  backgrounds.
- Uses a Carbon hotkey, so no Accessibility permission is required.
- Draws over normal windows but not over fullscreen apps.

## Tuning

Fade timings are constants at the top of `OverlayView` in `Sources/main.swift`:

```swift
var holdDuration: TimeInterval = 0.35
var fadeDuration: TimeInterval = 0.4
```
