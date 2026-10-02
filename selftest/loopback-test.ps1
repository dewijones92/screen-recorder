param(
    [string]$OutDir = 'C:\Users\DewiJones\claude-html\selftest',
    [int]$SpeakerVolume = 70,
    [switch]$NoFlash
)

$ErrorActionPreference = 'Stop'
Add-Type 'using System; using System.Runtime.InteropServices; public static class SelfTestDpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }'
[SelfTestDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
Add-Type -AssemblyName System.Speech, System.Windows.Forms, System.Drawing
Import-Module AudioDeviceCmdlets

function Get-Volume { [double]((Get-AudioDevice -PlaybackVolume) -replace '[^0-9.]', '') }

function Say($m) { Write-Host ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m) }

$tool = 'C:\Users\DewiJones\Tools\ScreenRecorder'
$ff = (Get-Command ffmpeg).Source
New-Item -ItemType Directory -Force $OutDir | Out-Null
Get-ChildItem $OutDir -Filter 'rec-*' -ErrorAction SilentlyContinue | Remove-Item

$speech = Join-Path $OutDir 'reference-speech.wav'
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$pb = New-Object System.Speech.Synthesis.PromptBuilder
$pb.AppendText('This is a microphone self test. One, two, three, four, five.')
$pb.AppendBreak([TimeSpan]::FromSeconds(1.5))
$pb.AppendText('The quick brown fox jumps over the lazy dog.')
$pb.AppendBreak([TimeSpan]::FromSeconds(1.5))
$pb.AppendText('Checking for robotic or underwater sound, and for clipping on louder words.')
$pb.AppendBreak([TimeSpan]::FromSeconds(1.5))
$pb.AppendText('Six, seven, eight, nine, ten. Test complete.')
$synth.SetOutputToWaveFile($speech)
$synth.Speak($pb)
$synth.SetOutputToNull()
$synth.Dispose()
Say "reference speech written: $speech"

$click = Join-Path $OutDir 'click.wav'
& $ff -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=2000:duration=0.05:sample_rate=44100' -af 'volume=0.9' $click

$origDefault = Get-AudioDevice -Playback
$origComms = Get-AudioDevice -PlaybackCommunication
$speakers = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' -and $_.Name -like 'Speakers*' } | Select-Object -First 1
if (-not $speakers) { throw 'laptop speakers not found' }
Say "default playback was [$($origDefault.Name)]; switching to [$($speakers.Name)] for the test"

$rec = $null
try {
    Set-AudioDevice -ID $speakers.ID -DefaultOnly | Out-Null
    $origSpeakerVol = Get-Volume
    $origSpeakerMute = Get-AudioDevice -PlaybackMute
    Set-AudioDevice -PlaybackMute $false | Out-Null
    Set-AudioDevice -PlaybackVolume $SpeakerVolume | Out-Null
    Say "speaker volume $origSpeakerVol -> $SpeakerVolume%"

    Remove-Item "$tool\progress.txt" -ErrorAction SilentlyContinue
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$tool\ScreenRecorder.ps1`" -Headless -Seconds 55 -Quality Small -Webcam none -OutDir `"$OutDir`""
    $rec = Start-Process powershell.exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 200
        if ((Test-Path "$tool\progress.txt") -and ((Get-Content "$tool\progress.txt" -Raw) -match 'out_time_us=[1-9]')) { break }
    }
    Say 'recording live'
    Start-Sleep 1

    $player = New-Object System.Media.SoundPlayer $speech
    Say 'speech start'
    $player.PlaySync()
    Say 'speech end'
    Start-Sleep 1

    if (-not $NoFlash) {
        $clickPlayer = New-Object System.Media.SoundPlayer $click
        $clickPlayer.Load()
        $f = New-Object Windows.Forms.Form
        $f.FormBorderStyle = 'None'; $f.TopMost = $true; $f.StartPosition = 'Manual'; $f.ShowInTaskbar = $false
        $f.BackColor = [Drawing.Color]::Black
        $f.Location = New-Object Drawing.Point(0, 0); $f.Size = New-Object Drawing.Size(3840, 2160)
        $f.Show(); [Windows.Forms.Application]::DoEvents()
        foreach ($i in 1..3) {
            $end = (Get-Date).AddMilliseconds(1200); while ((Get-Date) -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            $f.BackColor = [Drawing.Color]::White; $f.Refresh(); $clickPlayer.Play()
            Say "flash+click $i"
            $end = (Get-Date).AddMilliseconds(600); while ((Get-Date) -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            $f.BackColor = [Drawing.Color]::Black; $f.Refresh()
        }
        $f.Close()
    }
} finally {
    try {
        Set-AudioDevice -ID $speakers.ID -DefaultOnly | Out-Null
        if ($null -ne $origSpeakerVol) { Set-AudioDevice -PlaybackVolume $origSpeakerVol | Out-Null; Set-AudioDevice -PlaybackMute $origSpeakerMute | Out-Null }
    } catch { Say "WARNING could not restore speaker volume: $_" }
    Set-AudioDevice -ID $origDefault.ID -DefaultOnly | Out-Null
    Set-AudioDevice -ID $origComms.ID -CommunicationOnly | Out-Null
    Say ("restored default=[{0}] comms=[{1}] speakers volume {2}%" -f (Get-AudioDevice -Playback).Name, (Get-AudioDevice -PlaybackCommunication).Name, $origSpeakerVol)
}

if ($rec) { $rec.WaitForExit() }
$file = Get-ChildItem $OutDir -Filter 'rec-*.mp4' | Sort-Object LastWriteTime | Select-Object -Last 1
Say "RESULT $($file.FullName)"
