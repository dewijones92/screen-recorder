param(
    [switch]$Headless,
    [int]$Seconds = 10,
    [int]$ScreenIndex = 0,
    [string]$Mic,
    [string]$Webcam,
    [switch]$ForceGdi,
    [string]$Quality,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ToolDir 'ScreenRecorder.log'
if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('MyVideos') }
$SettingsFile = Join-Path $ToolDir 'settings.json'
$Presets = @(
    [pscustomobject]@{ Name = 'Small';    H = 720;  Fps = 15; Crf = 28; Label = 'Small - 720p, ~1 MB/min' }
    [pscustomobject]@{ Name = 'Balanced'; H = 1080; Fps = 15; Crf = 26; Label = 'Balanced - 1080p, ~1.5 MB/min' }
    [pscustomobject]@{ Name = 'Sharp';    H = 1440; Fps = 15; Crf = 24; Label = 'Sharp - 1440p, ~4.5 MB/min' }
    [pscustomobject]@{ Name = 'Smooth';   H = 1080; Fps = 30; Crf = 26; Label = 'Smooth - 1080p 30fps, ~1.5 MB/min' }
)
$DefaultPreset = 'Balanced'
$script:enc = $null
$CamMargin = 16
$ToggleFile = Join-Path $ToolDir 'toggle.request'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RecDpi {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
}
"@

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    if ($Headless) { Write-Host $line }
}

function Find-Ffmpeg {
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw 'ffmpeg.exe not found on PATH or in the winget packages folder'
}

function Get-DshowDevices([string]$ffmpeg) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = '-hide_banner -list_devices true -f dshow -i dummy'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $text = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $video = @(); $audio = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '\]\s+"([^"]+)"\s+\(([^)]+)\)') {
            $name = $matches[1]
            $kind = $matches[2]
            if ($kind -like '*video*') { $video += $name }
            if ($kind -like '*audio*') { $audio += $name }
        }
    }
    Write-Log ("devices video=[{0}] audio=[{1}]" -f ($video -join '; '), ($audio -join '; '))
    [pscustomobject]@{ Video = $video; Audio = $audio }
}

function Get-PhysicalScreens {
    $old = [RecDpi]::SetThreadDpiAwarenessContext([IntPtr](-4))
    try {
        $list = foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
            [pscustomobject]@{ Name = $s.DeviceName; Primary = $s.Primary; X = $s.Bounds.X; Y = $s.Bounds.Y; W = $s.Bounds.Width; H = $s.Bounds.Height }
        }
    } finally {
        [RecDpi]::SetThreadDpiAwarenessContext($old) | Out-Null
    }
    $sorted = @($list | Sort-Object @{ Expression = { -not $_.Primary } }, X, Y)
    $n = 1
    foreach ($s in $sorted) {
        $label = if ($s.Primary) { 'Main screen' } else { $n++; "Screen $n" }
        $s | Add-Member -NotePropertyName Label -NotePropertyValue ("{0} ({1}x{2})" -f $label, $s.W, $s.H)
        Write-Log ("screen {0} primary={1} x={2} y={3} w={4} h={5}" -f $s.Name, $s.Primary, $s.X, $s.Y, $s.W, $s.H)
    }
    $sorted
}

function Join-Args($list) {
    ($list | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
}

function Build-FfmpegArgs($screen, [bool]$useDda, [string]$mic, [string]$cam, [string]$outFile) {
    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]]@('-hide_banner', '-y'))
    $screenIdx = 0
    $parts = @()
    if ($cam) { $parts += "video=$cam" }
    if ($mic) { $parts += "audio=$mic" }
    if ($parts.Count -gt 0) {
        $a.AddRange([string[]]@('-thread_queue_size', '1024', '-f', 'dshow', '-rtbufsize', '256M'))
        if ($cam) { $a.AddRange([string[]]@('-vcodec', 'mjpeg', '-video_size', '640x480', '-framerate', '30')) }
        if ($mic) { $a.AddRange([string[]]@('-audio_buffer_size', '50')) }
        $a.AddRange([string[]]@('-i', ($parts -join ':')))
        $screenIdx = 1
    }
    if ($useDda) {
        $a.AddRange([string[]]@('-thread_queue_size', '1024', '-f', 'lavfi', '-i', ("ddagrab=output_idx=0:framerate={0}:video_size={1}x{2}" -f $script:enc.Fps, $screen.W, $screen.H)))
        $scr = "[${screenIdx}:v]hwdownload,format=bgra,scale=-2:$($script:enc.H)"
    } else {
        $a.AddRange([string[]]@('-thread_queue_size', '1024', '-f', 'gdigrab', '-framerate', "$($script:enc.Fps)", '-draw_mouse', '1',
                '-offset_x', "$($screen.X)", '-offset_y', "$($screen.Y)", '-video_size', ("{0}x{1}" -f $screen.W, $screen.H), '-i', 'desktop'))
        $scr = "[${screenIdx}:v]scale=-2:$($script:enc.H)"
    }
    if ($cam) {
        $fc = "$scr[scr];[0:v]fps=$($script:enc.Fps),crop='min(iw,ih)':'min(iw,ih)',scale=$($script:enc.Cam):$($script:enc.Cam)[cam];[scr][cam]overlay=W-w-${CamMargin}:H-h-${CamMargin},format=yuv420p[v]"
    } else {
        $fc = "$scr,format=yuv420p[v]"
    }
    $a.AddRange([string[]]@('-filter_complex', $fc, '-map', '[v]'))
    if ($mic) { $a.AddRange([string[]]@('-map', '0:a', '-c:a', 'aac', '-b:a', '64k', '-ac', '1')) }
    $a.AddRange([string[]]@('-c:v', 'libx264', '-preset', 'veryfast', '-crf', "$($script:enc.Crf)", '-r', "$($script:enc.Fps)", $outFile))
    , $a
}

function Start-Ffmpeg([string]$ffmpeg, $argList, [string]$reportPath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = Join-Args $argList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['FFREPORT'] = 'file=' + (($reportPath -replace '\\', '/') -replace ':', '\:') + ':level=32'
    Write-Log "ffmpeg start: $($psi.Arguments)"
    $p = [System.Diagnostics.Process]::Start($psi)
    Write-Log "ffmpeg pid=$($p.Id) report=$reportPath"
    $p
}

function Stop-Ffmpeg($p) {
    if ($null -eq $p) { return }
    if ($p.HasExited) { Write-Log "ffmpeg already exited code=$($p.ExitCode)"; return }
    try { $p.StandardInput.Write('q'); $p.StandardInput.Flush() } catch { Write-Log "sending q failed: $_" }
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    if (-not $p.HasExited) { Write-Log 'ffmpeg did not stop within 20s, killing it'; $p.Kill(); $p.WaitForExit() }
    Write-Log "ffmpeg exited code=$($p.ExitCode)"
}

function Convert-ToMp4([string]$ffmpeg, [string]$mkv) {
    if (-not (Test-Path $mkv) -or (Get-Item $mkv).Length -eq 0) { Write-Log "no recording to convert: $mkv"; return $null }
    $mp4 = [IO.Path]::ChangeExtension($mkv, '.mp4')
    $p = Start-Process -FilePath $ffmpeg -ArgumentList (Join-Args @('-hide_banner', '-loglevel', 'error', '-y', '-i', $mkv, '-c', 'copy', '-movflags', '+faststart', $mp4)) -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -eq 0 -and (Test-Path $mp4) -and (Get-Item $mp4).Length -gt 0) {
        Remove-Item $mkv
        Write-Log ("saved {0} ({1:N1} MB)" -f $mp4, ((Get-Item $mp4).Length / 1MB))
        return $mp4
    }
    Write-Log "mp4 conversion failed code=$($p.ExitCode), keeping $mkv"
    $mkv
}

function New-OutputPath { Join-Path $OutDir ('rec-{0:yyyy-MM-dd_HH-mm-ss}.mkv' -f (Get-Date)) }

if (-not $Headless) {
    $created = $false
    $script:mutex = New-Object System.Threading.Mutex($true, 'Local\ScreenRecorderSingleInstance', [ref]$created)
    if (-not $created) { Write-Log 'another instance is already running, exiting'; exit 0 }
    Remove-Item $ToggleFile -ErrorAction SilentlyContinue
}

$script:ffmpeg = Find-Ffmpeg
Write-Log "---- ScreenRecorder start headless=$Headless ffmpeg=$script:ffmpeg"
$script:screens = Get-PhysicalScreens
$script:devices = Get-DshowDevices $script:ffmpeg
$defaultMic = @($script:devices.Audio | Where-Object { $_ -match 'EPOS' }) + @($script:devices.Audio) | Select-Object -First 1
$defaultCam = @($script:devices.Video) | Select-Object -First 1

$script:proc = $null
$script:outFile = $null
$script:startedAt = $null
$script:config = $null

function Get-Preset([string]$name) {
    $p = $Presets | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($p) { $p } else { $Presets | Where-Object { $_.Name -eq $DefaultPreset } }
}

function Read-SavedPreset {
    try { (Get-Content $SettingsFile -Raw | ConvertFrom-Json).Quality } catch { $null }
}

function Save-Settings([string]$quality) {
    try { @{ Quality = $quality } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { Write-Log "saving settings failed: $_" }
}

function Start-Recording($screen, [string]$mic, [string]$cam, [bool]$forceGdi, [string]$quality) {
    $preset = Get-Preset $quality
    $h = [Math]::Min($preset.H, $screen.H)
    $h = $h - ($h % 2)
    $camSize = [int]($h / 5)
    $camSize = $camSize - ($camSize % 2)
    $script:enc = [pscustomobject]@{ Name = $preset.Name; H = $h; Fps = $preset.Fps; Crf = $preset.Crf; Cam = $camSize }
    Write-Log ("quality {0}: height={1} fps={2} crf={3} cam={4}" -f $preset.Name, $h, $preset.Fps, $preset.Crf, $camSize)
    $script:outFile = New-OutputPath
    $useDda = $screen.Primary -and -not $forceGdi
    $script:config = @{ Screen = $screen; Mic = $mic; Cam = $cam; UseDda = $useDda; Quality = $preset.Name }
    Write-Log ("record screen={0} dda={1} mic={2} cam={3} out={4}" -f $screen.Label, $useDda, $mic, $cam, $script:outFile)
    $report = Join-Path $ToolDir 'ffmpeg-last.log'
    $script:proc = Start-Ffmpeg $script:ffmpeg (Build-FfmpegArgs $screen $useDda $mic $cam $script:outFile) $report
    $script:startedAt = Get-Date
}

function Test-FallbackNeeded {
    if ($null -eq $script:proc -or -not $script:proc.HasExited) { return $false }
    $early = ((Get-Date) - $script:startedAt).TotalSeconds -lt 8
    if ($early -and $script:config.UseDda) {
        Write-Log "GPU capture exited early code=$($script:proc.ExitCode), retrying with gdigrab"
        Start-Recording $script:config.Screen $script:config.Mic $script:config.Cam $true $script:config.Quality
        return $true
    }
    return $false
}

if ($Headless) {
    $screen = $script:screens[$ScreenIndex]
    $micName = if ($Mic -eq 'none') { $null } elseif ($Mic) { $Mic } else { $defaultMic }
    $camName = if ($Webcam -eq 'none') { $null } elseif ($Webcam) { $Webcam } else { $defaultCam }
    Start-Recording $screen $micName $camName ([bool]$ForceGdi) $Quality
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 500
        if (Test-FallbackNeeded) { $end = (Get-Date).AddSeconds($Seconds) }
        elseif ($script:proc.HasExited) { Write-Log "ffmpeg exited unexpectedly code=$($script:proc.ExitCode)"; break }
    }
    Stop-Ffmpeg $script:proc
    $saved = Convert-ToMp4 $script:ffmpeg $script:outFile
    Write-Output "RESULT $saved"
    exit 0
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Screen Recorder'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.ClientSize = New-Object System.Drawing.Size(360, 232)

function Add-Row([string]$text, [int]$y) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text; $lbl.Location = New-Object System.Drawing.Point(14, ($y + 3)); $lbl.AutoSize = $true
    $form.Controls.Add($lbl)
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'; $cb.Location = New-Object System.Drawing.Point(80, $y); $cb.Width = 264
    $form.Controls.Add($cb)
    $cb
}

$cbScreen = Add-Row 'Screen' 14
foreach ($s in $script:screens) { [void]$cbScreen.Items.Add($s.Label) }
$cbScreen.SelectedIndex = 0

$cbMic = Add-Row 'Mic' 46
[void]$cbMic.Items.Add('(off)')
foreach ($m in $script:devices.Audio) { [void]$cbMic.Items.Add($m) }
$cbMic.SelectedIndex = if ($defaultMic) { $cbMic.Items.IndexOf($defaultMic) } else { 0 }

$cbCam = Add-Row 'Webcam' 78
[void]$cbCam.Items.Add('(off)')
foreach ($c in $script:devices.Video) { [void]$cbCam.Items.Add($c) }
$cbCam.SelectedIndex = if ($defaultCam) { $cbCam.Items.IndexOf($defaultCam) } else { 0 }

$cbQuality = Add-Row 'Quality' 110
foreach ($p in $Presets) { [void]$cbQuality.Items.Add($p.Label) }
$savedPreset = Get-Preset (Read-SavedPreset)
$cbQuality.SelectedIndex = [array]::IndexOf(@($Presets | ForEach-Object Name), $savedPreset.Name)

$btnRec = New-Object System.Windows.Forms.Button
$btnRec.Text = 'Record'; $btnRec.Location = New-Object System.Drawing.Point(80, 148); $btnRec.Size = New-Object System.Drawing.Size(84, 30)
$btnRec.ForeColor = [System.Drawing.Color]::DarkRed
$form.Controls.Add($btnRec)
$form.AcceptButton = $btnRec

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop'; $btnStop.Location = New-Object System.Drawing.Point(170, 148); $btnStop.Size = New-Object System.Drawing.Size(84, 30)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = 'Open folder'; $btnFolder.Location = New-Object System.Drawing.Point(260, 148); $btnFolder.Size = New-Object System.Drawing.Size(84, 30)
$form.Controls.Add($btnFolder)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(14, 192); $lblStatus.Size = New-Object System.Drawing.Size(330, 34)
$lblStatus.Text = 'Ready. Recordings go to your Videos folder.'
$form.Controls.Add($lblStatus)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

function Set-Idle([string]$status) {
    $timer.Stop()
    $btnRec.Enabled = $true; $btnStop.Enabled = $false
    $cbScreen.Enabled = $true; $cbMic.Enabled = $true; $cbCam.Enabled = $true; $cbQuality.Enabled = $true
    $form.Text = 'Screen Recorder'
    $form.WindowState = 'Normal'
    $form.Activate()
    $lblStatus.Text = $status
}

function Complete-Recording {
    if ($script:busy) { return }
    $script:busy = $true
    $btnStop.Enabled = $false
    $lblStatus.Text = 'Saving...'
    $form.Refresh()
    Stop-Ffmpeg $script:proc
    $saved = Convert-ToMp4 $script:ffmpeg $script:outFile
    $script:proc = $null
    if ($saved) {
        Set-Idle ("Saved {0} ({1:N1} MB)" -f (Split-Path $saved -Leaf), ((Get-Item $saved).Length / 1MB))
    } else {
        Set-Idle 'Nothing was recorded. See ScreenRecorder.log next to the app.'
    }
    $script:busy = $false
}

$script:busy = $false

function Invoke-Record {
        try {
            $screen = $script:screens[$cbScreen.SelectedIndex]
            $mic = if ($cbMic.SelectedIndex -gt 0) { [string]$cbMic.SelectedItem } else { $null }
            $cam = if ($cbCam.SelectedIndex -gt 0) { [string]$cbCam.SelectedItem } else { $null }
            $quality = $Presets[$cbQuality.SelectedIndex].Name
            Save-Settings $quality
            Start-Recording $screen $mic $cam $false $quality
            $btnRec.Enabled = $false; $btnStop.Enabled = $true
            $cbScreen.Enabled = $false; $cbMic.Enabled = $false; $cbCam.Enabled = $false; $cbQuality.Enabled = $false
            $lblStatus.Text = 'Recording... 00:00'
            $form.Text = 'REC - Screen Recorder'
            $timer.Start()
            $form.WindowState = 'Minimized'
        } catch {
            Write-Log "start failed: $_"
            Set-Idle "Could not start: $_"
        }
}

$btnRec.Add_Click({ Invoke-Record })

$btnStop.Add_Click({ Complete-Recording })

$btnFolder.Add_Click({ Start-Process explorer.exe $OutDir })

$timer.Add_Tick({
        if (Test-FallbackNeeded) { return }
        if ($script:proc.HasExited) {
            Write-Log "ffmpeg exited unexpectedly code=$($script:proc.ExitCode)"
            Complete-Recording
            $lblStatus.Text = 'Recording stopped unexpectedly. ' + $lblStatus.Text
            return
        }
        $elapsed = (Get-Date) - $script:startedAt
        $mb = if (Test-Path $script:outFile) { (Get-Item $script:outFile).Length / 1MB } else { 0 }
        $lblStatus.Text = ('Recording... {0:mm\:ss}  ({1:N1} MB)' -f $elapsed, $mb)
    })

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 200
$poll.Add_Tick({
        if (-not (Test-Path $ToggleFile)) { return }
        Remove-Item $ToggleFile -ErrorAction SilentlyContinue
        if ($script:busy) { Write-Log 'hotkey: ignored, still saving' }
        elseif ($script:proc -and -not $script:proc.HasExited) { Write-Log 'hotkey: stop'; Complete-Recording }
        elseif ($btnRec.Enabled) { Write-Log 'hotkey: record'; Invoke-Record }
        else { Write-Log 'hotkey: ignored, not ready' }
    })
$poll.Start()

$form.Add_FormClosing({
        if ($script:proc -and -not $script:proc.HasExited) { Complete-Recording }
    })

[void]$form.ShowDialog()
Write-Log '---- ScreenRecorder closed'
