#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_DIR="/mnt/c/Users/DewiJones/Tools/ScreenRecorder"
WIN_DIR_W='C:\Users\DewiJones\Tools\ScreenRecorder'
AHK_SCRIPT="/mnt/c/Users/DewiJones/Documents/AutoHotkey/capsesc.ahk"
AHK_SCRIPT_W='C:\Users\DewiJones\Documents\AutoHotkey\capsesc.ahk'
AHK_EXE='C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe'
INCLUDE_LINE="#Include $WIN_DIR_W\\screen-recorder-hotkey.ahk"

mkdir -p "$WIN_DIR"
cp "$HERE/ScreenRecorder.ps1" "$WIN_DIR/"
mkdir -p "$WIN_DIR/selftest" && cp "$HERE/selftest/loopback-test.ps1" "$WIN_DIR/selftest/"
sed 's/$/\r/' "$HERE/screen-recorder-hotkey.ahk" > "$WIN_DIR/screen-recorder-hotkey.ahk"
echo "deployed -> $WIN_DIR_W"

powershell.exe -NoProfile -Command "
  \$s = (New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop') + '\Screen Recorder.lnk')
  \$s.TargetPath = 'powershell.exe'
  \$s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"$WIN_DIR_W\ScreenRecorder.ps1\"'
  \$s.WorkingDirectory = '$WIN_DIR_W'
  \$s.IconLocation = 'shell32.dll,203'
  \$s.Save()
" >/dev/null
echo "desktop shortcut -> Screen Recorder.lnk"

if ! grep -qF "$INCLUDE_LINE" "$AHK_SCRIPT"; then
  cp "$AHK_SCRIPT" "$AHK_SCRIPT.bak-$(date +%F)"
  printf '\r\n%s\r\n' "$INCLUDE_LINE" >> "$AHK_SCRIPT"
  echo "added #Include to capsesc.ahk (backup: capsesc.ahk.bak-$(date +%F))"
fi

powershell.exe -NoProfile -Command "Start-Process -FilePath '$AHK_EXE' -ArgumentList '/restart','\"$AHK_SCRIPT_W\"'" >/dev/null
echo "restarted capsesc.ahk - Ctrl+Alt+R opens / starts / stops the recorder"
