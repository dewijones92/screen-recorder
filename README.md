# screen-recorder

A small Windows screen recorder: pick a screen, a mic and a webcam, press Record. Built on the
ffmpeg already installed through winget, so nothing else to install.

- Screen at 1280x720 (scaled from the real resolution), 15 fps, H.264 CRF 28: roughly 1 MB per
  minute for a mostly still screen.
- Mic as 64 kbps mono AAC.
- Webcam cropped to a square, 1/5 of the frame height, in the bottom-right corner.
- Saved to `Videos\rec-<date>_<time>.mp4`. It records to `.mkv` first, so a crash still leaves a
  usable file, then remuxes to `.mp4` on stop.

## Use

- **Ctrl+Alt+R**: opens the app; press again to start recording; again to stop.
- Or the **Screen Recorder** shortcut on the desktop.

- A live webcam square sits in the bottom-right corner of the chosen screen, exactly where it will
  appear in the video. **Drag it** anywhere, before or during recording; the recording follows.
- Record starts a **3-2-1 countdown** in the middle of the screen. The camera and mic open during
  the countdown, so the video starts within about half a second of "1".
- The app window, the webcam square and the countdown are all excluded from capture
  (`SetWindowDisplayAffinity` with `WDA_EXCLUDEFROMCAPTURE`), so none of them appear in the video.
  The webcam in the video is ffmpeg's own overlay, in sync with the mic.
- Pressing the hotkey during the countdown cancels the recording.

The window minimises while recording.

## Install / update

```bash
./install.sh
```

Copies the app to `C:\Users\DewiJones\Tools\ScreenRecorder` (AutoHotkey is unreliable reading
from `\\wsl$`), creates the desktop shortcut, adds one `#Include` line to
`Documents\AutoHotkey\capsesc.ahk` (backing it up first), and restarts that AutoHotkey v1 script.

## How it captures

- Main screen: `ddagrab` (Desktop Duplication, GPU). Falls back to `gdigrab` automatically if it
  fails to start.
- Other screens: `gdigrab` with the screen's physical-pixel bounds. `ddagrab` cannot reach a screen
  driven by the other GPU on this laptop.
- Mic and webcam come in as one DirectShow input so they share a clock.
- The live preview is a second ffmpeg output (MJPEG on stdout) read by a small C# window. Before
  recording, a separate preview-only ffmpeg feeds it; it hands the camera over on Record.
- Dragging the square sends `overlay@cam` x/y commands to the running ffmpeg on stdin (`c` key).
- Recording counts as started when ffmpeg's `-progress` output reports `out_time_us > 0`. The
  file size is no use for this: ffmpeg buffers the first 32 KB, so the file reads as empty for seconds.
- The hotkey does not click the window: it drops `toggle.request` next to the app, which polls for
  it every 200 ms. AutoHotkey's ControlClick does not reach a minimised WinForms window.

## Testing without the GUI

```powershell
powershell -ExecutionPolicy Bypass -File ScreenRecorder.ps1 -Headless -Seconds 8 -ScreenIndex 0 [-Mic none] [-Webcam none] [-ForceGdi]
```

## Logs

Next to the deployed app: `ScreenRecorder.log` (decisions, overlay positions, preview frame counts, full ffmpeg command line),
`ffmpeg-last.log` (ffmpeg's own report for the last recording), `hotkey.log`.
