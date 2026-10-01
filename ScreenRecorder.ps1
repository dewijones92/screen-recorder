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
$PreviewSize = 240
$script:bubble = $null
$ToggleFile = Join-Path $ToolDir 'toggle.request'
$ProgressFile = Join-Path $ToolDir 'progress.txt'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$NativeCode = @'
using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class RecDpi {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr h, uint affinity);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    public static bool ExcludeFromCapture(IntPtr h) { return SetWindowDisplayAffinity(h, 0x11); }

    public static void PlacePhysical(IntPtr h, int x, int y, int w, int height) {
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { SetWindowPos(h, new IntPtr(-1), x, y, w, height, 0x0010); }
        finally { SetThreadDpiAwarenessContext(old); }
    }

    public static int[] RectPhysical(IntPtr h) {
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            RECT r;
            GetWindowRect(h, out r);
            return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
        }
        finally { SetThreadDpiAwarenessContext(old); }
    }
}

public class CamBubble : Form {
    readonly PictureBox box = new PictureBox();
    volatile bool pending;
    long frames;
    long badFrames;
    public string LastError = "";
    public event EventHandler DragEnded;
    public long Frames { get { return Interlocked.Read(ref frames); } }
    public long BadFrames { get { return Interlocked.Read(ref badFrames); } }

    public CamBubble() {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        BackColor = Color.Black;
        box.Dock = DockStyle.Fill;
        box.SizeMode = PictureBoxSizeMode.Zoom;
        box.Cursor = Cursors.SizeAll;
        box.MouseDown += OnBoxMouseDown;
        Controls.Add(box);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        RecDpi.ExcludeFromCapture(Handle);
    }

    void OnBoxMouseDown(object sender, MouseEventArgs e) {
        if (e.Button != MouseButtons.Left) return;
        RecDpi.ReleaseCapture();
        RecDpi.SendMessage(Handle, 0xA1, new IntPtr(2), IntPtr.Zero);
        EventHandler handler = DragEnded;
        if (handler != null) handler(this, EventArgs.Empty);
    }

    public void Attach(Stream stream) {
        Thread t = new Thread(() => ReadLoop(stream));
        t.IsBackground = true;
        t.Start();
    }

    void ReadLoop(Stream stream) {
        byte[] buf = new byte[4 << 20];
        int len = 0;
        try {
            while (true) {
                if (len == buf.Length) len = 0;
                int n = stream.Read(buf, len, buf.Length - len);
                if (n <= 0) break;
                len += n;
                int pos = 0;
                while (true) {
                    int start = Find(buf, pos, len, 0xD8);
                    if (start < 0) { pos = Math.Max(pos, len - 1); break; }
                    int end = Find(buf, start + 2, len, 0xD9);
                    if (end < 0) { pos = start; break; }
                    int frameLen = end + 2 - start;
                    byte[] jpg = new byte[frameLen];
                    Buffer.BlockCopy(buf, start, jpg, 0, frameLen);
                    pos = end + 2;
                    Deliver(jpg);
                }
                if (pos > 0) {
                    Buffer.BlockCopy(buf, pos, buf, 0, len - pos);
                    len -= pos;
                }
            }
            LastError = "preview stream ended";
        } catch (Exception ex) {
            LastError = "preview read: " + ex.GetType().Name + ": " + ex.Message;
        }
    }

    static int Find(byte[] b, int from, int to, byte marker) {
        for (int i = from; i < to - 1; i++) if (b[i] == 0xFF && b[i + 1] == marker) return i;
        return -1;
    }

    void Deliver(byte[] jpg) {
        Interlocked.Increment(ref frames);
        if (pending || IsDisposed || !IsHandleCreated) return;
        Bitmap bmp;
        try {
            using (MemoryStream ms = new MemoryStream(jpg))
            using (Image img = Image.FromStream(ms)) {
                bmp = new Bitmap(img);
            }
        } catch (Exception ex) {
            Interlocked.Increment(ref badFrames);
            LastError = "bad frame: " + ex.Message;
            return;
        }
        pending = true;
        try {
            BeginInvoke((MethodInvoker)delegate {
                Image old = box.Image;
                box.Image = bmp;
                if (old != null) old.Dispose();
                pending = false;
            });
        } catch (Exception ex) {
            pending = false;
            bmp.Dispose();
            LastError = "preview invoke: " + ex.Message;
        }
    }
}

public class CountdownForm : Form {
    readonly Label label = new Label();

    public CountdownForm() {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        BackColor = Color.Black;
        Opacity = 0.8;
        label.Dock = DockStyle.Fill;
        label.ForeColor = Color.White;
        label.TextAlign = ContentAlignment.MiddleCenter;
        label.Font = new Font("Segoe UI", 72, FontStyle.Bold);
        Controls.Add(label);
    }

    public string Value { get { return label.Text; } set { label.Text = value; } }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        RecDpi.ExcludeFromCapture(Handle);
    }
}
'@
Add-Type -TypeDefinition $NativeCode -ReferencedAssemblies System.Windows.Forms, System.Drawing

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
    $e = $script:enc
    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]]@('-hide_banner', '-y', '-progress', $ProgressFile))
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
        $camChain = "[0:v]fps=$($e.Fps),crop='min(iw,ih)':'min(iw,ih)'"
        if ($e.Preview) {
            $camChain += ",split=2[c1][c2];[c1]scale=$($e.Cam):$($e.Cam)[cam];[c2]scale=${PreviewSize}:${PreviewSize},format=yuvj420p[prev]"
        } else {
            $camChain += ",scale=$($e.Cam):$($e.Cam)[cam]"
        }
        $fc = "$scr[scr];$camChain;[scr][cam]overlay@cam=x=$($e.OX):y=$($e.OY),format=yuv420p[v]"
    } else {
        $fc = "$scr,format=yuv420p[v]"
    }
    $a.AddRange([string[]]@('-filter_complex', $fc, '-map', '[v]'))
    if ($mic) { $a.AddRange([string[]]@('-map', '0:a', '-c:a', 'aac', '-b:a', '64k', '-ac', '1')) }
    $a.AddRange([string[]]@('-c:v', 'libx264', '-preset', 'veryfast', '-crf', "$($script:enc.Crf)", '-r', "$($script:enc.Fps)", $outFile))
    if ($cam -and $e.Preview) { $a.AddRange([string[]]@('-map', '[prev]', '-c:v', 'mjpeg', '-q:v', '5', '-f', 'mjpeg', 'pipe:1')) }
    , $a
}

function Start-Ffmpeg([string]$ffmpeg, $argList, [string]$reportPath, [bool]$readStdout) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = Join-Args $argList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $readStdout
    if ($reportPath) { $psi.EnvironmentVariables['FFREPORT'] = 'file=' + (($reportPath -replace '\\', '/') -replace ':', '\:') + ':level=32' }
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

function Get-OutWidth($screen, [int]$outH) {
    $w = [int][Math]::Round($screen.W * $outH / $screen.H)
    $w - ($w % 2)
}

function Get-OverlayXY($screen, [int]$outH, [int]$camSize) {
    $outW = Get-OutWidth $screen $outH
    $r = [RecDpi]::RectPhysical($script:bubble.Handle)
    $x = [int](($r[0] - $screen.X) * $outW / $screen.W)
    $y = [int](($r[1] - $screen.Y) * $outH / $screen.H)
    $x = [Math]::Max(0, [Math]::Min($x, $outW - $camSize))
    $y = [Math]::Max(0, [Math]::Min($y, $outH - $camSize))
    Write-Log ("bubble rect={0},{1} {2}x{3} -> overlay {4},{5} in {6}x{7}" -f $r[0], $r[1], $r[2], $r[3], $x, $y, $outW, $outH)
    @($x, $y)
}

function Test-RecordingLive {
    try {
        $fs = [IO.File]::Open($ProgressFile, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch {
        return $false
    }
    $m = [regex]::Matches($text, 'out_time_us=(\d+)')
    if ($m.Count -eq 0) { return $false }
    [long]$m[$m.Count - 1].Groups[1].Value -gt 0
}

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
    $preview = [bool]($cam -and $script:bubble -and $script:bubble.Visible)
    $margin = [int]($h * $CamMargin / 720)
    if ($preview) {
        $xy = Get-OverlayXY $screen $h $camSize
        $ox = $xy[0]; $oy = $xy[1]
    } else {
        $ox = "W-w-$margin"; $oy = "H-h-$margin"
    }
    $script:enc = [pscustomobject]@{ Name = $preset.Name; H = $h; Fps = $preset.Fps; Crf = $preset.Crf; Cam = $camSize; OX = $ox; OY = $oy; Preview = $preview }
    Write-Log ("quality {0}: height={1} fps={2} crf={3} cam={4} overlay={5},{6} preview={7}" -f $preset.Name, $h, $preset.Fps, $preset.Crf, $camSize, $ox, $oy, $preview)
    $script:outFile = New-OutputPath
    $useDda = $screen.Primary -and -not $forceGdi
    $script:config = @{ Screen = $screen; Mic = $mic; Cam = $cam; UseDda = $useDda; Quality = $preset.Name }
    Write-Log ("record screen={0} dda={1} mic={2} cam={3} out={4}" -f $screen.Label, $useDda, $mic, $cam, $script:outFile)
    $report = Join-Path $ToolDir 'ffmpeg-last.log'
    Remove-Item $ProgressFile -ErrorAction SilentlyContinue
    $script:proc = Start-Ffmpeg $script:ffmpeg (Build-FfmpegArgs $screen $useDda $mic $cam $script:outFile) $report $script:enc.Preview
    if ($script:enc.Preview) { $script:bubble.Attach($script:proc.StandardOutput.BaseStream) }
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

$script:bubble = New-Object CamBubble
$script:countdown = New-Object CountdownForm
$script:preview = $null
$script:counting = $false
$script:countStart = $null

$cdTimer = New-Object System.Windows.Forms.Timer
$cdTimer.Interval = 100

function Get-SelectedScreen { $script:screens[$cbScreen.SelectedIndex] }

function Get-SelectedCam { if ($cbCam.SelectedIndex -gt 0) { [string]$cbCam.SelectedItem } else { $null } }

function Move-BubbleHome($screen) {
    $size = [int]($screen.H / 5)
    $margin = [int]($screen.H * $CamMargin / 720)
    [RecDpi]::PlacePhysical($script:bubble.Handle, $screen.X + $screen.W - $size - $margin, $screen.Y + $screen.H - $size - $margin, $size, $size)
    Write-Log ("bubble placed on {0} size={1}" -f $screen.Label, $size)
}

function Start-Preview {
    if ($script:preview -and -not $script:preview.HasExited) { return }
    $cam = Get-SelectedCam
    if (-not $cam) { $script:bubble.Hide(); Write-Log 'preview off: no webcam selected'; return }
    $argList = @('-hide_banner', '-loglevel', 'error', '-f', 'dshow', '-rtbufsize', '64M', '-vcodec', 'mjpeg', '-video_size', '640x480', '-framerate', '30',
        '-i', "video=$cam", '-vf', "fps=15,crop='min(iw,ih)':'min(iw,ih)',scale=${PreviewSize}:${PreviewSize},format=yuvj420p",
        '-c:v', 'mjpeg', '-q:v', '5', '-f', 'mjpeg', 'pipe:1')
    $script:preview = Start-Ffmpeg $script:ffmpeg $argList $null $true
    $script:bubble.Attach($script:preview.StandardOutput.BaseStream)
    if (-not $script:bubble.Visible) {
        $script:bubble.Show()
        Move-BubbleHome (Get-SelectedScreen)
    }
}

function Stop-Preview {
    if ($script:preview) {
        Stop-Ffmpeg $script:preview
        Write-Log ("preview stopped frames={0} bad={1} last={2}" -f $script:bubble.Frames, $script:bubble.BadFrames, $script:bubble.LastError)
        $script:preview = $null
    }
}

function Send-OverlayMove {
    if (-not $script:proc -or $script:proc.HasExited -or -not $script:config.Cam -or -not $script:enc.Preview) { return }
    $xy = Get-OverlayXY $script:config.Screen $script:enc.H $script:enc.Cam
    try {
        $script:proc.StandardInput.Write('c')
        $script:proc.StandardInput.Write("overlay@cam -1 x $($xy[0])`n")
        $script:proc.StandardInput.Write('c')
        $script:proc.StandardInput.Write("overlay@cam -1 y $($xy[1])`n")
        $script:proc.StandardInput.Flush()
        Write-Log ("overlay moved to {0},{1}" -f $xy[0], $xy[1])
    } catch {
        Write-Log "overlay move failed: $_"
    }
}

function Set-Idle([string]$status) {
    $timer.Stop()
    $btnRec.Enabled = $true; $btnStop.Enabled = $false
    $cbScreen.Enabled = $true; $cbMic.Enabled = $true; $cbCam.Enabled = $true; $cbQuality.Enabled = $true
    $form.Text = 'Screen Recorder'
    $form.WindowState = 'Normal'
    $form.Activate()
    $lblStatus.Text = $status
}

function Stop-Countdown {
    $cdTimer.Stop()
    $script:countdown.Hide()
    $script:counting = $false
}

function Complete-Recording {
    if ($script:busy) { return }
    $script:busy = $true
    $cancelled = $script:counting
    if ($script:counting) { Stop-Countdown }
    $btnStop.Enabled = $false
    $lblStatus.Text = if ($cancelled) { 'Cancelling...' } else { 'Saving...' }
    $form.Refresh()
    Stop-Ffmpeg $script:proc
    if ($script:enc.Preview) { Write-Log ("recording preview frames={0} bad={1} last={2}" -f $script:bubble.Frames, $script:bubble.BadFrames, $script:bubble.LastError) }
    $script:proc = $null
    if ($cancelled) {
        Remove-Item $script:outFile -ErrorAction SilentlyContinue
        Write-Log 'cancelled during countdown, file removed'
        Set-Idle 'Cancelled.'
    } else {
        $saved = Convert-ToMp4 $script:ffmpeg $script:outFile
        if ($saved) {
            Set-Idle ("Saved {0} ({1:N1} MB)" -f (Split-Path $saved -Leaf), ((Get-Item $saved).Length / 1MB))
        } else {
            Set-Idle 'Nothing was recorded. See ScreenRecorder.log next to the app.'
        }
    }
    Start-Preview
    $script:busy = $false
}

$script:busy = $false

function Start-Countdown($screen) {
    $script:counting = $true
    $script:countStart = Get-Date
    $size = [int]($screen.H / 5)
    $script:countdown.Value = '3'
    $script:countdown.Show()
    [RecDpi]::PlacePhysical($script:countdown.Handle, [int]($screen.X + ($screen.W - $size) / 2), [int]($screen.Y + ($screen.H - $size) / 2), $size, $size)
    $lblStatus.Text = 'Starting...'
    $cdTimer.Start()
}

function Invoke-Record {
    try {
        $screen = Get-SelectedScreen
        $mic = if ($cbMic.SelectedIndex -gt 0) { [string]$cbMic.SelectedItem } else { $null }
        $cam = Get-SelectedCam
        $quality = $Presets[$cbQuality.SelectedIndex].Name
        Save-Settings $quality
        Stop-Preview
        Start-Recording $screen $mic $cam $false $quality
        $btnRec.Enabled = $false; $btnStop.Enabled = $true
        $cbScreen.Enabled = $false; $cbMic.Enabled = $false; $cbCam.Enabled = $false; $cbQuality.Enabled = $false
        $form.Text = 'REC - Screen Recorder'
        Start-Countdown $screen
    } catch {
        Write-Log "start failed: $_"
        Set-Idle "Could not start: $_"
        Start-Preview
    }
}

$cdTimer.Add_Tick({
        if ($script:proc.HasExited) {
            if (Test-FallbackNeeded) { return }
            Write-Log "ffmpeg exited during countdown code=$($script:proc.ExitCode)"
            Stop-Countdown
            Complete-Recording
            $lblStatus.Text = 'Could not start recording. See ScreenRecorder.log.'
            return
        }
        $elapsed = ((Get-Date) - $script:countStart).TotalSeconds
        $live = Test-RecordingLive
        if ($elapsed -lt 3) {
            $script:countdown.Value = [string](3 - [int][Math]::Floor($elapsed))
        } elseif (-not $live) {
            $script:countdown.Value = '...'
        } else {
            Write-Log ("countdown done, recording live {0:N1}s after Record" -f $elapsed)
            Stop-Countdown
            $script:startedAt = Get-Date
            $lblStatus.Text = 'Recording... 00:00'
            $timer.Start()
            $form.WindowState = 'Minimized'
        }
    })

$script:bubble.Add_DragEnded({
        Write-Log 'bubble dragged'
        Send-OverlayMove
    })

$cbScreen.Add_SelectedIndexChanged({ if ($script:bubble.Visible) { Move-BubbleHome (Get-SelectedScreen) } })

$cbCam.Add_SelectedIndexChanged({
        if ($script:proc) { return }
        Stop-Preview
        Start-Preview
    })

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

$form.Add_Shown({
        Write-Log ("main window excluded from capture={0}" -f [RecDpi]::ExcludeFromCapture($form.Handle))
        Start-Preview
    })

$form.Add_FormClosing({
        if ($script:proc -and -not $script:proc.HasExited) { Complete-Recording }
        Stop-Preview
        $script:bubble.Close()
        $script:countdown.Close()
    })

[void]$form.ShowDialog()
Write-Log '---- ScreenRecorder closed'
