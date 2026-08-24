# ScreenBox

## Contributing

- **Never commit directly to `main`.** Always branch and open a PR, even for
  one-line or docs-only changes. Merge through the PR.

## Design assets

`design/` holds the assets the build and README actually consume:

- `design/ScreenBox.icns` / `ScreenBox.iconset` — app bundle icon
- `design/dmg-background.tiff` — DMG window background (`scripts/make-dmg.sh`)
- `design/icons/appicon-256.png` — README header image
- `design/icons/appicon-master.png` — full-resolution icon source

Don't commit intermediate or alternate renders here; pull them from history if
they're ever needed again.
