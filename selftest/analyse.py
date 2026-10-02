import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def load_wav(path):
    with wave.open(str(path)) as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(float) / 32768
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def envelope(x, sr, ms=10):
    b = int(sr * ms / 1000)
    n = len(x) // b
    return np.sqrt(np.mean(x[:n * b].reshape(n, b) ** 2, axis=1)) + 1e-9


def block_db(x, sr, ms=20):
    return 20 * np.log10(envelope(x, sr, ms))


def screen_luma(video, tmp):
    csv = Path(tmp) / 'luma.csv'
    with open(csv, 'w') as fh:
        subprocess.run(['ffprobe', '-v', 'error', '-f', 'lavfi',
                        f"movie='{video}',crop=600:300:0:0,signalstats",
                        '-show_entries', 'frame=pts_time:frame_tags=lavfi.signalstats.YAVG', '-of', 'csv=p=0'],
                       check=True, stdout=fh)
    rows = []
    for line in open(csv):
        parts = line.strip().split(',')
        if len(parts) >= 2 and parts[0] and parts[-1]:
            rows.append((float(parts[0]), float(parts[-1])))
    return rows


def main(video, reference):
    with tempfile.TemporaryDirectory() as tmp:
        rec_wav = Path(tmp) / 'rec.wav'
        ref_wav = Path(tmp) / 'ref.wav'
        run(['ffmpeg', '-y', '-i', video, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(rec_wav)])
        run(['ffmpeg', '-y', '-i', reference, '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(ref_wav)])
        rec, sr = load_wav(rec_wav)
        ref, _ = load_wav(ref_wav)
        luma = screen_luma(video, tmp)

    er, ef = envelope(rec, sr), envelope(ref, sr)
    lr, lf = np.log(er), np.log(ef)
    lr_n = (lr - lr.mean()) / lr.std()
    lf_n = (lf - lf.mean()) / lf.std()
    corr = np.correlate(lr_n, lf_n, mode='valid') / len(lf_n)
    lag = int(np.argmax(corr))
    start = lag * sr // 100
    seg = rec[start:start + len(ref)]
    print(f'speech found at {start / sr:.2f}s in the recording, envelope match {corr[lag]:.2f} (1.0 = identical shape)')

    db = block_db(seg, sr)
    ref_db = block_db(ref, sr)
    n = min(len(db), len(ref_db))
    db, ref_db = db[:n], ref_db[:n]
    pauses = ref_db < -60
    speech = ~pauses
    print(f'during reference pauses: recording median {np.median(db[pauses]):.1f} dB, '
          f'{100 * np.mean(db[pauses] < -90):.0f}% of blocks at digital silence (robotic/gating sign if high)')
    print(f'during speech: recording median {np.median(db[speech]):.1f} dB, '
          f'{100 * np.mean(db[speech] < -90):.0f}% of speech blocks at digital silence (speech being gated out)')
    print(f'clipped samples in whole recording: {int(np.sum(np.abs(rec) > 0.99))}, peak {np.max(np.abs(rec)):.2f}')

    nfft = 512
    def spec(x):
        frames = [x[i:i + nfft] * np.hanning(nfft) for i in range(0, len(x) - nfft, nfft // 2)]
        return np.log10(np.mean([np.abs(np.fft.rfft(f)) ** 2 for f in frames], axis=0) + 1e-12)
    sr_, sf_ = spec(seg), spec(ref)
    freqs = np.fft.rfftfreq(nfft, 1 / sr)
    band = (freqs > 200) & (freqs < 7000)
    shape = np.corrcoef(sr_[band] - sr_[band].mean(), sf_[band] - sf_[band].mean())[0, 1]
    print(f'spectral shape match 200-7000 Hz: {shape:.2f} (speaker+room colour it; compare runs, not absolute)')

    whites = [t for (t, y), (_, prev) in zip(luma[1:], luma[:-1]) if y > 200 and prev < 50]
    if not whites:
        print('no screen flashes found')
        return
    b = int(sr * 0.005)
    lv = 20 * np.log10(envelope(rec, sr, 5))
    offsets = []
    for w in whites:
        lo, hi_i = int((w - 0.3) * 200), int((w + 1.0) * 200)
        quiet = np.median(lv[lo:int(w * 200)])
        idx = np.where(lv[lo:hi_i] > quiet + 30)[0]
        if len(idx):
            offsets.append((lo + idx[0]) / 200 - w)
    print('screen flash -> click heard in mic: ' + ', '.join(f'{o * 1000:+.0f} ms' for o in offsets)
          + '  (positive = voice LATE vs screen; includes ~20-60 ms speaker output latency)')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
