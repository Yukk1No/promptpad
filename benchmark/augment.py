#!/usr/bin/env python3
"""Audio degradation augmenter.

Applies a named preset of audiomentations transforms to a WAV file and
writes the result to disk.  All presets produce 16-bit mono WAV output
so the result is drop-in for Vosk.

Library version: audiomentations==0.43.1

Presets
-------
clean               identity copy (no transform applied)
cafe-noise-snr-20   additive Gaussian noise at 20 dB SNR
cafe-noise-snr-10   additive Gaussian noise at 10 dB SNR
cafe-noise-snr-5    additive Gaussian noise at 5 dB SNR
reverb              room simulation (RoomSimulator default settings)
bandlimit           band-pass 300-3400 Hz (telephony style)
pitch-up-3          pitch shift +3 semitones
pitch-down-3        pitch shift -3 semitones

Usage
-----
    python3 benchmark/augment.py --wav INPUT.wav --preset cafe-noise-snr-10
    python3 benchmark/augment.py --wav INPUT.wav --preset reverb --out OUT.wav
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

REPO = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = REPO / "benchmark" / "results" / "audio"

PRESETS = {
    "clean",
    "cafe-noise-snr-20",
    "cafe-noise-snr-10",
    "cafe-noise-snr-5",
    "reverb",
    "bandlimit",
    "pitch-up-3",
    "pitch-down-3",
}


def _load_wav(path: Path) -> tuple[np.ndarray, int]:
    """Return (samples float32, sample_rate). Converts to mono if needed."""
    data, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if data.ndim == 2:
        data = data.mean(axis=1)
    return data, sr


def _save_wav(path: Path, samples: np.ndarray, sr: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Clip to [-1, 1] before writing to avoid clipping artifacts in soundfile
    samples = np.clip(samples, -1.0, 1.0)
    sf.write(str(path), samples, sr, subtype="PCM_16")


def _apply_simple_reverb(samples: np.ndarray, sr: int) -> np.ndarray:
    """Synthetic room reverb via exponential-decay IR convolution.

    Simulates a small-to-medium room with RT60 ≈ 200 ms.
    No pyroomacoustics dependency required.
    """
    from scipy.signal import fftconvolve

    rt60_ms = 200
    ir_len = int(sr * rt60_ms / 1000)
    rng = np.random.default_rng(42)
    ir = rng.standard_normal(ir_len).astype(np.float32)
    decay = np.exp(-np.linspace(0, 6.9, ir_len, dtype=np.float32))  # 6.9 → -60 dB
    ir *= decay
    ir /= np.abs(ir).max() + 1e-9

    wet = fftconvolve(samples, ir)[:len(samples)].astype(np.float32)
    # Mix 40% wet + 60% dry for intelligibility
    out = 0.6 * samples + 0.4 * wet
    return out


def apply_preset(samples: np.ndarray, sr: int, preset: str) -> np.ndarray:
    """Return augmented samples (float32, mono)."""
    if preset == "clean":
        return samples.copy()

    from audiomentations import (
        AddGaussianSNR,
        BandPassFilter,
        PitchShift,
    )

    if preset == "cafe-noise-snr-20":
        aug = AddGaussianSNR(min_snr_db=20.0, max_snr_db=20.0, p=1.0)
    elif preset == "cafe-noise-snr-10":
        aug = AddGaussianSNR(min_snr_db=10.0, max_snr_db=10.0, p=1.0)
    elif preset == "cafe-noise-snr-5":
        aug = AddGaussianSNR(min_snr_db=5.0, max_snr_db=5.0, p=1.0)
    elif preset == "reverb":
        # RoomSimulator requires pyroomacoustics (optional extra).
        # Fall back to a simple exponential-decay synthetic IR convolution
        # which models a small room (~200 ms RT60) without extra deps.
        return _apply_simple_reverb(samples, sr)
    elif preset == "bandlimit":
        aug = BandPassFilter(
            min_center_freq=1850.0,
            max_center_freq=1850.0,
            min_bandwidth_fraction=1.7,
            max_bandwidth_fraction=1.7,
            p=1.0,
        )
    elif preset == "pitch-up-3":
        aug = PitchShift(min_semitones=3.0, max_semitones=3.0, p=1.0)
    elif preset == "pitch-down-3":
        aug = PitchShift(min_semitones=-3.0, max_semitones=-3.0, p=1.0)
    else:
        raise ValueError(f"Unknown preset: {preset!r}")

    return aug(samples=samples, sample_rate=sr)


def augment(wav_path: Path, preset: str, out_path: Path | None = None) -> Path:
    if preset not in PRESETS:
        raise ValueError(f"Unknown preset {preset!r}. Choose from: {sorted(PRESETS)}")

    if out_path is None:
        stem = wav_path.stem
        out_path = DEFAULT_OUT_DIR / f"{stem}__{preset}.wav"

    samples, sr = _load_wav(wav_path)
    result = apply_preset(samples, sr, preset)
    _save_wav(out_path, result, sr)
    print(f"augment: {wav_path.name} --[{preset}]--> {out_path}")
    return out_path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--wav", required=True, type=Path, help="Input WAV file")
    ap.add_argument("--preset", required=True, choices=sorted(PRESETS),
                    help="Augmentation preset name")
    ap.add_argument("--out", type=Path, default=None,
                    help="Output WAV path (default: results/audio/<stem>__<preset>.wav)")
    args = ap.parse_args()

    if not args.wav.exists():
        sys.exit(f"ERROR: input WAV not found: {args.wav}")

    out = augment(args.wav, args.preset, args.out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
