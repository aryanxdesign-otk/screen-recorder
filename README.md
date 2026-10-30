# Scouter

A native macOS screen recorder with an editor for polished product videos: automatic zooms on clicks with subtle motion blur, wallpapers/gradients behind the recording, rounded corners and shadow, a Loom-style webcam bubble, trimming and cuts, and MP4/GIF export at 720p or 1080p.

Built with Swift, SwiftUI/AppKit, ScreenCaptureKit, AVFoundation and Core Image. Requires **macOS 15 or newer** (built and tested against the macOS 26 SDK).

## Build and run

1. Open `Scouter.xcodeproj` in Xcode 16 or newer.
2. Select the **Scouter** scheme and press **⌘R**.
3. Recommended: in *Scouter target → Signing & Capabilities*, pick your Apple ID under **Team** (a free Personal Team is fine) and set **Signing Certificate** to *Development*. Without a team the app is signed "to run locally", and macOS asks for Screen Recording permission again after every rebuild.

On first use macOS asks for:

| Permission | When | Why |
| --- | --- | --- |
| Screen & System Audio Recording | First time you pick Display / Window / Area | Capturing the screen and computer sound. After granting it, quit and reopen Scouter. |
| Microphone | When you choose a microphone | Recording your voice |
| Camera | When you choose a camera | The webcam bubble |

**Installing a new build over an old one.** Builds that aren't signed with an Apple Developer certificate look like a different app to macOS each time, so the Screen Recording toggle in System Settings can show *on* while Scouter is still asked for permission. Reset Scouter's permissions once per new build:

```bash
tccutil reset All app.scouter.Scouter
```

Then open Scouter and allow Screen Recording (and Camera/Microphone) again. Building it yourself in Xcode with your Apple ID as the Team avoids this.

## Using it

**Recording bar.** Opening Scouter (Spotlight, Finder, Dock) shows the bar at the bottom of the screen:

- **Display**: hover a screen and click to record it.
- **Window**: hover a window and click to record just that window.
- **Area**: drag a rectangle, then press **Start recording** (or Return). Esc cancels.
- **Camera / Microphone**: both default to off. Pick any connected device from the drop-downs.
- **Computer sound**: toggles recording of your Mac's audio.

A 3-2-1 countdown runs, then a small pill with the timer, **pause/resume**, **stop** and **discard** appears. Scouter's own windows (bar, pill, countdown, camera bubble) never show up in the recording.

**Editor.** Stopping opens the editor:

- **Timeline**: drag the ends of a clip to trim. **✂ / ⌘B** splits at the playhead. Select a piece and press **⌫** to cut it out.
- **Zoom track**: each click becomes an automatic zoom (*Auto* follows your clicks and cursor). Drag a zoom to move it, drag its edges to resize it, click empty space (or press **Z**) to add one, and **⌫** to delete it. In the Zoom panel you can set its level and switch the focus to *Manual* to pick the spot yourself.
- **Background panel**: wallpapers, gradient, solid color or your own image, plus padding, corners and shadow sliders.
- **Zoom panel**: default zoom level (1.7× by default, which shows about 35% of the screen), re-detect zooms from clicks, and motion blur strength.
- **Camera panel**: show or hide the bubble, size, corner and mirroring.
- **Audio panel**: mute or keep the microphone and computer sound separately, with a volume for each.
- **Aspect ratio**: Auto, 16:9, 9:16, 1:1 or 4:3 (top-left of the canvas). **Crop** cuts the recording itself.
- **Presets**: save the current look, set one as the default for new recordings, and apply it in one click.
- **Export (⌘E)**: MP4 (30 or 60 fps) or GIF, at 720p or 1080p. Files are saved to Downloads, and the sheet offers *Show in Finder* and *Copy to Clipboard*.

Edits save automatically, and undo/redo works with ⌘Z / ⇧⌘Z.

## Where things are stored

- Recordings: `~/Movies/Scouter/<name>.scouter`. Each one is a folder holding `screen.mov` (HEVC), `camera.mov`, `microphone.m4a`, `system-audio.m4a`, `recording.json` (cursor and click data) and `project.json` (your edits). Open them again with **File → Open Recording…** or by double-clicking in Finder.
- Presets: `~/Library/Application Support/Scouter/presets.json`.

## How it works

| Area | Files |
| --- | --- |
| Capture flow (bar → selection → countdown → controls) | `Scouter/Recording/RecorderController.swift`, `RecorderBar.swift`, `SelectionOverlay.swift`, `RecordingPanels.swift` |
| ScreenCaptureKit capture, audio writers | `Scouter/Recording/ScreenCapture.swift` |
| Webcam capture | `Scouter/Recording/CameraCapture.swift` |
| Shared clock for pause/resume and sync | `Scouter/Recording/RecordingClock.swift` |
| Cursor and click tracking (120 Hz polling, no extra permission) | `Scouter/Recording/MouseTracker.swift` |
| Auto zoom detection | `Scouter/Model/AutoZoom.swift` |
| Camera motion (spring-smoothed zoom and cursor follow) | `Scouter/Model/CameraPath.swift` |
| Frame rendering: background, shadow, corners, zoom, motion blur, webcam | `Scouter/Rendering/FrameRenderer.swift` |
| Custom AVFoundation compositor (shared by preview and export) | `Scouter/Rendering/Compositor.swift`, `CompositionBuilder.swift` |
| Export | `Scouter/Rendering/Exporter.swift` |
| Editor UI | `Scouter/Editor/*` |

The recorded cursor is the real macOS cursor, captured in the video, so it always has the right shape (arrow, I-beam, hand). Zooms and motion blur are applied in the editor and are never baked into the raw recording, so you can change them at any time.
