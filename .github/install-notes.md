Unzip and drag **ScreenBox.app** to `/Applications`.

ScreenBox isn't notarised yet, so macOS refuses to open it on first launch.
Either right-click the app and choose **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/ScreenBox.app
```

Then add it to **System Settings → General → Login Items** to have it start with
your Mac. Press **⌃⌥⌘B** to draw.
