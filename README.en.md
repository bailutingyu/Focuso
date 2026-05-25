<div align="center">

<img src="assets/appicon-1024.png" width="128" alt="Focuso icon" />

# Focuso

**Screen recording + webcam overlay + auto-editing, all-in-one for macOS**

Records your screen and webcam as two independent layers, then drops you into a CapCut-style editor where mouse clicks are automatically turned into "click-to-zoom" animations. Inspired by Screen Studio / Focusee.

Built entirely in native Swift + AppKit, with zero third-party dependencies.

[简体中文](README.md) · **English**

</div>

---

## ✨ Features

- 🎥 **Circular webcam bubble**: drag, scroll-to-resize, switch device, mirror, toggle on/off
- 🖥 **Screen recording**: full screen, or a fixed aspect ratio (**16:9 / 9:16 / 4:3 / 3:4**), multi-display
- 🎬 **Two-layer recording**: screen layer (excludes the bubble) + webcam layer, fully independent
- ✨ **Auto-opens the editor** after recording, generating "click-to-zoom" segments from your mouse clicks
- ✂️ **CapCut-style timeline**: add / remove / drag zoom segments, tweak scale & focus, trim head/tail (`Delete` to remove a segment)
- 🖼 **Wallpaper background + rounded corners**: 5 gradient presets + custom image
- 📷 **Webcam layer editing**: drag to reposition, resize, shape (circle / rounded rect), white border, brightness / saturation
- 🔊 **System audio + microphone** (with software gain)
- 📌 **Lives in the menu bar**; "Turn off camera" to save power
- 📂 **Project folder** (`screen.mov` + `camera.mov` + `project.json`), reopenable for further editing

## 💻 Requirements

- macOS 13 Ventura or later (macOS 14+ recommended; some device enumeration needs 14)
- On first launch, grant **Screen Recording, Camera, and Microphone** in System Settings → Privacy & Security

## 🛠 Build & Run

```bash
git clone https://github.com/bailutingyu/Focuso.git
cd Focuso
./build.sh
open Focuso.app
```

`build.sh` compiles directly with `swiftc` (no Xcode project), generates the app icon from `assets/appicon-1024.png` via `sips` + `iconutil`, and ad-hoc signs the app. The first launch requests Camera / Microphone / Screen Recording permissions — grant them, then quit and relaunch.

## 🚀 Usage

1. Click the **Focuso menu bar icon** (or right-click the webcam bubble)
2. Pick **Aspect ratio → Display → Start recording**
3. For a fixed ratio, a draggable / resizable region box appears; a red dashed outline marks the area while recording
4. After stopping, the **editor** opens automatically — adjust zoom segments, webcam, background, then **Export**
5. Projects & exports are saved under `~/Downloads/Focuso/录制-<timestamp>/`

## 🧱 Architecture

Native, zero dependencies:

| File | Responsibility |
|---|---|
| `main.swift` | Webcam bubble, menu bar, recording coordination; contains `ScreenRecorder` (ScreenCaptureKit + system audio + mic) |
| `MouseTracker.swift` | Records global mouse events during capture (for click-to-zoom) |
| `ZoomProject.swift` | Project model (zoom segments / trim / background / camera params), serializable |
| `ZoomCompositor.swift` | Custom `AVVideoCompositing` two-layer compositing + HEVC export (shared by preview & export) |
| `EditorWindow.swift` | CapCut-style editor: timeline, preview, webcam layer interaction |
| `RegionSelector.swift` | Region picker for fixed-ratio recording |

Stack: `AppKit` · `ScreenCaptureKit` · `AVFoundation` · `CoreImage`.

## 🌐 Web Version (focuso-web.html)

The repo also ships a pure **web version** `focuso-web.html` (the project's earliest prototype): an in-browser "present + webcam + teleprompter + record" tool using `getDisplayMedia` + `getUserMedia` + `MediaRecorder`. No install needed — just open it in a modern browser (Chrome / Edge).

> It's the web ancestor of Focuso, focused on live presenting; the native macOS version adds two-layer recording and post-recording auto-editing.

## 📄 License

MIT. Free to use, modify, and distribute, but **please keep the original copyright and license notice** (see [LICENSE](LICENSE)).

## 🙏 Credits

Inspired by [Screen Studio](https://screen.studio/), Focusee, and other great screen recorders.
