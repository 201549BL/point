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
- A desktop-wallpaper backdrop that never exposes neighboring windows
- A customizable glass border and annotation styling
- Moving, resizing, deleting, undo, and redo
- Flattened clipboard output and explicit PNG saving
- No screenshot persistence by default

## Download

Download the latest notarized build from
[GitHub Releases](../../releases/latest), unzip it, and move **Point.app** to your
Applications folder. Point requires macOS 14 or later.

On the first capture, macOS asks for Screen Recording access. Point uses this
permission only to capture the region you select.

## Use Point

Press the configured shortcut, use the optional three-finger double-tap, or
choose **Capture Region** from the menu-bar item. Select a region, annotate it,
then press `Return` to copy and close.

Canvas shortcuts:

- `A`: arrow
- `B`: mosaic blur
- `R`: opaque redaction
- `Command-Z` / `Command-Shift-Z`: undo / redo
- `Delete`: delete the selected annotation
- `Return`: copy and close when not editing text
- `Command-S`: save a flattened PNG
- `Escape`: cancel the current operation; press again within 2.5 seconds to discard

Double-click an arrow to add or edit its caption. While editing a caption,
`Return` finishes, `Option-Return` inserts a line, and `Command-Return` copies.
Selected text and captions have direct handles for changing width and font size.

Choose **Settings…** from the Point menu to customize the global shortcut,
trackpad gesture, annotation and border colors, arrow size, text size, and
backdrop.

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

To create and install a signed local Release build:

```sh
Scripts/install-local.sh
```

## Create a release

Public releases require a paid Apple Developer Program membership, a
**Developer ID Application** certificate, and notarization credentials stored in
the keychain under the `point-notary` profile.

```sh
xcrun notarytool store-credentials "point-notary"
Scripts/release.sh
Scripts/publish-release.sh 0.1.0
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
