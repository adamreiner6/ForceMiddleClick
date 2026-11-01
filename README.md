# ForceMiddleClick

Tiny menu bar app that turns a trackpad **force click** into a **middle click** (scroll-wheel click):
force click a link to open it in a new tab, force click a tab to close it.

One Swift file, no dependencies. Requires macOS 13 or later and a Force Touch trackpad.

## Install

1. Download `ForceMiddleClick.zip` from the [latest release](../../releases/latest), unzip it and move
   `ForceMiddleClick.app` to `/Applications`.
2. Open it. The app isn't notarized, so macOS blocks it the first time: go to
   **System Settings → Privacy & Security** and click **Open Anyway**. If that option doesn't appear, run:

   ```sh
   xattr -d com.apple.quarantine /Applications/ForceMiddleClick.app
   ```

3. Grant it **Accessibility** access when asked (System Settings → Privacy & Security → Accessibility).

The menu bar icon has Enabled, Launch at Login and Quit.

Keep **System Settings → Trackpad → Force Click and haptic feedback** on — without it the trackpad never reports a force click.

## Build from source

Needs the Xcode Command Line Tools.

```sh
./build.sh
cp -R ForceMiddleClick.app /Applications/
open /Applications/ForceMiddleClick.app
```

## How it works

A left mouse-down is held back for up to 0.4 s. If the press turns into a force click in that window, a middle-button
click is sent instead (drags become middle-drags). If you release, drag, or hold past 0.4 s, the original click is
replayed untouched. Normal clicks aren't noticeably delayed; a stationary press-and-hold starts 0.4 s late, and a force
click that takes longer than 0.4 s stays a regular force click.

## Notes

- The default ad-hoc signature changes on every build, so macOS drops the Accessibility grant after a rebuild.
  Remove the app from the Accessibility list and add it again, or build with a real identity:
  `SIGN_ID="Apple Development: …" ./build.sh`.
- Debug logging: `FMC_DEBUG=1 ./ForceMiddleClick.app/Contents/MacOS/ForceMiddleClick` and watch the event/stage log.

## License

[MIT](LICENSE)
