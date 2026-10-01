^!r::
    SetTitleMatchMode, 2
    if WinExist("Screen Recorder ahk_exe powershell.exe")
    {
        FileAppend,, C:\Users\DewiJones\Tools\ScreenRecorder\toggle.request
        FileAppend, %A_Now% hotkey: toggle requested`n, C:\Users\DewiJones\Tools\ScreenRecorder\hotkey.log
    }
    else
    {
        Run, powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\DewiJones\Tools\ScreenRecorder\ScreenRecorder.ps1",, Hide
        FileAppend, %A_Now% hotkey: launched app`n, C:\Users\DewiJones\Tools\ScreenRecorder\hotkey.log
    }
return
