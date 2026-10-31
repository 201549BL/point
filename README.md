# Point

<p align="center">
  <img src="Resources/AppIconArtwork.png" width="160" alt="Point app icon">
</p>

Point is a fast, clipboard-first screenshot and annotation tool for macOS. It
lives in the menu bar and turns a captured region into a polished image without
opening a separate editor.

## Features

- A customizable global keyboard shortcut
- An optional three-finger double-tap trackpad gesture
- Exact native-resolution captures across Retina and mixed-scale displays
- Arrows, captions, irregular mosaic blur, and opaque redaction
- Screenshot backgrounds: desktop wallpaper, other locally available macOS wallpapers, built-in Aurora/Ocean/Sunset gradients, or a custom image
- Background choice and visibility remembered across captures and launches; custom images are stored by Point
- A customizable glass border and annotation styling
- Moving, resizing, deleting, undo, and redo
- Flattened clipboard output and explicit PNG saving
- No screenshot persistence by default

## Download

Download the latest notarized build from
[GitHub Releases](../../releases/latest), unzip it, and move **Point.app** to your
Applications folder. Point requires macOS 14 or later.

On first launch, Point guides you through enabling Screen Recording access in
macOS. Setup resumes after reopening Point if a restart is needed. You can
finish later from **Finish Setup…** in the menu bar. Point takes screenshots
when you start a capture and does not capture audio.

## Use Point

Press the configured shortcut, use the optional three-finger double-tap, or
choose **Capture Region** from the menu-bar item. Select a region, annotate it,
then press `Return` to copy and close, returning focus to your previous app
so you can paste immediately. A small tilted thumbnail peeks in from the bottom
left edge of that screen; hover to slide it fully into view. Choose **Save…**
to save the PNG, then **Show in Finder** to reveal it. Drag the thumbnail into an image or file input to attach the PNG.
The preview closes after six seconds away from the pointer; hovering
or using the save dialog or dragging pauses the timer.

Canvas shortcuts:

- `A`: arrow
- `B`: mosaic blur
- `R`: opaque redaction
- `G`: toggle backdrop
- `Command-Z` / `Command-Shift-Z`: undo / redo
- `Delete`: delete the selected annotation
- `Return`: copy and close when not editing text
- `Command-S`: save a flattened PNG
- `Escape`: cancel the current operation; press again within 2.5 seconds to discard

Drag a selected arrow’s diamond along and away from the arrow to position its curve. Drag it back near the straight line to snap it straight. Double-click an arrow to add or edit its caption. While editing a caption,
`Return` finishes, `Option-Return` inserts a line, and `Command-Return` copies.
Selected text and captions have direct handles for changing width and font size.

Choose **Settings…** from the Point menu to customize the global shortcut,
trackpad gesture, annotation and border colors, arrow size, text size, and
backdrop. Choose **Color mood** from Sunset (peach and violet), Lagoon (mint and
teal), or Twilight (blue and purple). The wash automatically softens in dark
mode and stays outside the clear selected region while dragging. Use **Overlay strength** to adjust its
intensity from 0–100%; the default is 45% and your choice is remembered across
launches. A crosshair and capture hint indicate readiness immediately, and
dimensions follow the dragged corner. Reduce Motion skips the entrance fade.
The screen freezes when capture starts. Selection and the finished screenshot
use that same frame, so video cannot advance while you choose a region.

## Develop

Point requires macOS 14 or later and Xcode 15 or later.

Open `Point.xcodeproj`, select the Point target, and choose your Apple Development
team under **Signing & Capabilities**. Debug builds appear as **Point Dev** with
the bundle identifier `com.eirikbjorndal.point.dev`, keeping their Screen
Recording permission separate from the installed release app.

Run the test suite with:

```sh
swift test
```

To create and install a local Release build with the same Developer ID signing
identity as published releases:

```sh
Scripts/install-local.sh
```

### Screen Recording recovery

If Point is enabled in Settings but asks again after a rebuild, run
`Scripts/install-local.sh --repair-permissions`, then allow Point once and reopen
it if macOS asks. Normal installs preserve the signing identity and never reset
permissions. See [the diagnosis and recovery guide](docs/screen-recording-permissions.md).

## Create a release

Public releases require a paid Apple Developer Program membership, a
**Developer ID Application** certificate, and notarization credentials stored in
the keychain under the `point-notary` profile.

```sh
xcrun notarytool store-credentials "point-notary"
Scripts/release.sh
Scripts/publish-release.sh 0.2.0
```

`release.sh` tests, archives, Developer-ID-signs, notarizes, staples, packages,
checksums, and Gatekeeper-verifies the universal app. `publish-release.sh`
revalidates the result before attaching it to a GitHub Release.

## Privacy

Point processes captures locally and copies the finished image to the clipboard.
It does not persist screenshots by default and contains no analytics or account
system.

## Compatibility note

The optional three-finger gesture uses macOS's private MultitouchSupport
framework. Apple may change this framework without notice. The configurable
keyboard shortcut remains the supported fallback.
