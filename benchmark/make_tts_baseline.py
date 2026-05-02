#!/usr/bin/env python3
"""Generate TTS true-baseline fixtures for the PromptPad benchmark.

Steps:
  1. Synthesize first 280 words of jfk_script.txt with piper-tts
     (en_US-amy-medium, 22050 Hz) → tts_jfk.wav at 16000 Hz mono
  2. Run Vosk on tts_jfk.wav → word timings (engine: vosk-on-tts)
  3. Write canonical fixtures:
       benchmark/real_audio/tts_jfk_script.txt
       benchmark/results/word_timings/tts_jfk.json
       benchmark/real_audio/tts_jfk_gt.json

Usage:
    python3 benchmark/make_tts_baseline.py [--words N] [--force]

Requirements:
    pip install piper-tts vosk
    Voice model: /tmp/piper_voices/en_US-amy-medium.onnx
      (downloaded automatically if --download flag given or first run)
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import wave
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
REAL_AUDIO = REPO / "benchmark" / "real_audio"
WT_DIR = REPO / "benchmark" / "results" / "word_timings"
VOICE_DIR = Path("/tmp/piper_voices")
VOICE_NAME = "en_US-amy-medium"
VOICE_MODEL = VOICE_DIR / f"{VOICE_NAME}.onnx"
TARGET_SAMPLE_RATE = 16000
VOSK_MODEL_DIR = REAL_AUDIO / "model"
NON_ALNUM = re.compile(r"[^a-z0-9]")


# ---------------------------------------------------------------------------
# Step 1: Synthesize TTS audio
# ---------------------------------------------------------------------------

def get_first_n_words(script_path: Path, n: int) -> tuple[str, list[str]]:
    """Return (text_for_tts, raw_word_list) for first n words of script."""
    raw = script_path.read_text()
    words = raw.split()
    truncated = words[:n]
    # Rebuild text preserving paragraph structure
    # Re-join: find position of nth word in original text and slice
    pos = 0
    for i, w in enumerate(truncated):
        idx = raw.find(w, pos)
        if idx == -1:
            break
        pos = idx + len(w)
        if i == len(truncated) - 1:
            text = raw[:pos]
    return text, truncated


def resample_22050_to_16000(audio_int16: np.ndarray) -> np.ndarray:
    """Downsample 22050 Hz → 16000 Hz using polyphase rational approximation.

    22050:16000 = 441:320. We approximate with a simple decimation:
    upsample by 320 then downsample by 441 using numpy interp (linear).
    This gives acceptable quality for ASR — Vosk doesn't need studio quality.
    """
    src_rate = 22050
    dst_rate = 16000
    n_src = len(audio_int16)
    n_dst = int(n_src * dst_rate / src_rate)
    src_times = np.arange(n_src)
    dst_times = np.linspace(0, n_src - 1, n_dst)
    resampled = np.interp(dst_times, src_times, audio_int16.astype(np.float64))
    return np.clip(resampled, -32768, 32767).astype(np.int16)


def synthesize_tts(text: str, out_wav: Path) -> int:
    """Synthesize text with piper, save 16kHz mono WAV. Returns sample_rate."""
    from piper.voice import PiperVoice
    from piper.download_voices import download_voice

    if not VOICE_MODEL.exists():
        print(f"Downloading {VOICE_NAME}...")
        VOICE_DIR.mkdir(parents=True, exist_ok=True)
        download_voice(VOICE_NAME, VOICE_DIR)

    print(f"Loading piper voice {VOICE_NAME}...")
    voice = PiperVoice.load(str(VOICE_MODEL))
    src_rate = voice.config.sample_rate  # 22050

    print("Synthesizing speech...")
    all_samples: list[np.ndarray] = []
    for chunk in voice.synthesize(text):
        # audio_float_array is float32 in [-1, 1]
        int16_arr = (chunk.audio_float_array * 32767).astype(np.int16)
        all_samples.append(int16_arr)

    combined = np.concatenate(all_samples)
    print(f"  Synthesized {len(combined)/src_rate:.1f}s at {src_rate} Hz")

    # Resample to 16000 Hz
    resampled = resample_22050_to_16000(combined)
    duration_s = len(resampled) / TARGET_SAMPLE_RATE
    print(f"  Resampled to {TARGET_SAMPLE_RATE} Hz: {duration_s:.1f}s")

    out_wav.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out_wav), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_SAMPLE_RATE)
        wf.writeframes(resampled.tobytes())

    print(f"Wrote {out_wav}")
    return TARGET_SAMPLE_RATE


# ---------------------------------------------------------------------------
# Step 2: Run Vosk ASR on TTS audio
# ---------------------------------------------------------------------------

def run_vosk(wav_path: Path, out_events: Path) -> list[dict]:
    """Run Vosk on wav_path, emit streaming events, return list of events."""
    from vosk import Model, KaldiRecognizer, SetLogLevel
    SetLogLevel(-1)

    if not VOSK_MODEL_DIR.exists():
        raise FileNotFoundError(f"Vosk model not found at {VOSK_MODEL_DIR}")

    model = Model(str(VOSK_MODEL_DIR))
    CHUNK_MS = 125

    with wave.open(str(wav_path), "rb") as wf:
        assert wf.getnchannels() == 1, "Must be mono"
        assert wf.getsampwidth() == 2, "Must be 16-bit"
        sample_rate = wf.getframerate()
        frames_per_chunk = sample_rate * CHUNK_MS // 1000

        rec = KaldiRecognizer(model, sample_rate)
        rec.SetWords(True)

        events = []
        audio_offset_ms = 0
        last_partial_text = ""

        while True:
            data = wf.readframes(frames_per_chunk)
            if not data:
                break
            audio_offset_ms += (len(data) // 2) * 1000 // sample_rate

            if rec.AcceptWaveform(data):
                res = json.loads(rec.Result())
                text = res.get("text", "").strip()
                if text:
                    events.append({
                        "time_ms": audio_offset_ms,
                        "text": text,
                        "is_final": True,
                        "words": res.get("result", []),
                    })
                    last_partial_text = ""
            else:
                res = json.loads(rec.PartialResult())
                ptext = res.get("partial", "").strip()
                if ptext and ptext != last_partial_text:
                    events.append({
                        "time_ms": audio_offset_ms,
                        "text": ptext,
                        "is_final": False,
                        "words": [],
                    })
                    last_partial_text = ptext

        res = json.loads(rec.FinalResult())
        text = res.get("text", "").strip()
        if text:
            events.append({
                "time_ms": audio_offset_ms,
                "text": text,
                "is_final": True,
                "words": res.get("result", []),
            })

    finals = sum(1 for e in events if e["is_final"])
    total_words = sum(len(e.get("words", [])) for e in events if e["is_final"])
    print(f"Vosk: {len(events)} events ({finals} finals), {total_words} words")

    out_events.parent.mkdir(parents=True, exist_ok=True)
    out_events.write_text(json.dumps(events, indent=2) + "\n")
    print(f"Wrote events → {out_events.relative_to(REPO)}")
    return events


# ---------------------------------------------------------------------------
# Step 3: Build word_timings.json from Vosk events
# ---------------------------------------------------------------------------

def build_word_timings(events: list[dict], stem: str, wav_path: Path) -> dict:
    """Build canonical word_timings.json from Vosk events on TTS audio."""
    audio_duration_ms = max(ev["time_ms"] for ev in events)

    words = []
    for ev in events:
        if not ev.get("is_final"):
            continue
        for w in ev.get("words", []) or []:
            word = (w.get("word") or "").strip()
            if not word:
                continue
            words.append({
                "word": word,
                "start_ms": int(round(w["start"] * 1000)),
                "end_ms": int(round(w["end"] * 1000)),
                "confidence": round(float(w.get("conf", 1.0)), 4),
            })
    words.sort(key=lambda w: w["start_ms"])

    return {
        "clip_id": stem,
        "engine": "vosk-on-tts",
        "audio_duration_ms": audio_duration_ms,
        "source_events_path": f"benchmark/real_audio/{stem}_events.json",
        "words": words,
    }


# ---------------------------------------------------------------------------
# Step 4: Build ground truth gt.json (exact alignment since TTS is clean)
# ---------------------------------------------------------------------------

def normalize(w: str) -> str:
    return NON_ALNUM.sub("", w.lower())


def build_gt(events: list[dict], script_words_raw: list[str], stem: str) -> dict:
    """Align Vosk stream (on TTS) to script words, produce gt.json.

    Because TTS input is clean speech, alignment_rate should be >90%.
    All matched words get confidence='anchor'.
    """
    vosk_stream = []
    for ev in events:
        if not ev.get("is_final"):
            continue
        for w in ev.get("words", []):
            word = normalize(w["word"])
            if not word:
                continue
            vosk_stream.append((int(w["start"] * 1000), word))

    if not vosk_stream:
        raise ValueError("No Vosk words found — ASR failed")

    script_norm = [normalize(w) for w in script_words_raw]
    vosk_words = [w for _, w in vosk_stream]
    vosk_times = [t for t, _ in vosk_stream]

    sm = SequenceMatcher(a=vosk_words, b=script_norm, autojunk=False)
    blocks = sm.get_matching_blocks()

    anchors = []
    for blk in blocks:
        if blk.size == 0:
            continue
        for k in range(blk.size):
            vi = blk.a + k
            si = blk.b + k
            anchors.append([vosk_times[vi], si])

    anchors.sort(key=lambda p: (p[0], p[1]))

    total_ms = max(ev["time_ms"] for ev in events)
    extended = [[0, 0]] + anchors + [[total_ms, anchors[-1][1]]]

    samples = []
    for i in range(len(extended) - 1):
        t0, p0 = extended[i]
        t1, p1 = extended[i + 1]
        if t1 <= t0:
            continue
        step = 100
        t = t0
        while t < t1:
            frac = (t - t0) / (t1 - t0)
            pos = round(p0 + frac * (p1 - p0))
            samples.append([t, pos])
            t += step
    samples.append([total_ms, extended[-1][1]])

    alignment_rate = round(len(anchors) / max(1, len(vosk_stream)), 3)
    stats = {
        "total_vosk_words": len(vosk_stream),
        "matched_vosk_words": len(anchors),
        "alignment_rate": alignment_rate,
        "script_words": len(script_norm),
        "last_gt_position": anchors[-1][1],
        "total_audio_ms": total_ms,
        "note": "Vosk on clean piper-TTS audio; near-perfect word-level alignment",
    }

    print(f"GT alignment: {len(anchors)}/{len(vosk_stream)} words "
          f"({alignment_rate*100:.0f}%) → last pos {anchors[-1][1]}/{len(script_norm)}")

    return {
        "anchors": anchors,
        "samples": samples,
        "stats": stats,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--words", type=int, default=280,
                    help="Number of script words to synthesize (default: 280)")
    ap.add_argument("--force", action="store_true",
                    help="Re-synthesize even if tts_jfk.wav already exists")
    ap.add_argument("--skip-synth", action="store_true",
                    help="Skip synthesis, use existing tts_jfk.wav")
    ap.add_argument("--skip-vosk", action="store_true",
                    help="Skip Vosk, use existing tts_jfk_events.json")
    args = ap.parse_args()

    stem = "tts_jfk"
    script_path = REAL_AUDIO / "jfk_script.txt"
    out_wav = REAL_AUDIO / f"{stem}.wav"
    out_script = REAL_AUDIO / f"{stem}_script.txt"
    out_events = REAL_AUDIO / f"{stem}_events.json"
    out_wt = WT_DIR / f"{stem}.json"
    out_gt = REAL_AUDIO / f"{stem}_gt.json"

    # --- Step 1: Get truncated text ---
    print(f"\n=== Step 1: Prepare script ({args.words} words) ===")
    text, raw_words = get_first_n_words(script_path, args.words)
    print(f"  Script: {len(raw_words)} words")
    print(f"  First 10: {raw_words[:10]}")
    print(f"  Last 5: {raw_words[-5:]}")
    out_script.write_text(text)
    print(f"  Wrote {out_script.relative_to(REPO)}")

    # --- Step 2: Synthesize ---
    print(f"\n=== Step 2: Synthesize TTS audio ===")
    if not args.skip_synth and (args.force or not out_wav.exists()):
        synthesize_tts(text, out_wav)
    else:
        print(f"  Skipping synthesis, using existing {out_wav.name}")

    # Get duration
    with wave.open(str(out_wav), "rb") as wf:
        n_frames = wf.getnframes()
        sr = wf.getframerate()
        duration_s = n_frames / sr
    print(f"  WAV: {duration_s:.1f}s @ {sr}Hz")

    # --- Step 3: Vosk ASR ---
    print(f"\n=== Step 3: Run Vosk on TTS audio ===")
    if not args.skip_vosk and (args.force or not out_events.exists()):
        events = run_vosk(out_wav, out_events)
    else:
        print(f"  Loading existing {out_events.name}")
        events = json.loads(out_events.read_text())

    # --- Step 4: word_timings.json ---
    print(f"\n=== Step 4: Build word_timings.json ===")
    wt = build_word_timings(events, stem, out_wav)
    # Patch audio_duration_ms to actual WAV duration
    wt["audio_duration_ms"] = int(duration_s * 1000)
    WT_DIR.mkdir(parents=True, exist_ok=True)
    out_wt.write_text(json.dumps(wt, indent=2) + "\n")
    print(f"  {len(wt['words'])} words, {wt['audio_duration_ms']/1000:.1f}s")
    print(f"  Wrote {out_wt.relative_to(REPO)}")

    # --- Step 5: gt.json ---
    print(f"\n=== Step 5: Build ground truth gt.json ===")
    gt = build_gt(events, raw_words, stem)
    out_gt.write_text(json.dumps(gt, indent=2) + "\n")
    print(f"  Wrote {out_gt.relative_to(REPO)}")

    print("\n=== Summary ===")
    print(f"  TTS engine:       piper-tts {VOICE_NAME}")
    print(f"  ASR for timings:  vosk-on-tts (Vosk on clean TTS audio)")
    print(f"  Audio duration:   {duration_s:.1f}s")
    print(f"  Words synthesized:{len(raw_words)}")
    print(f"  Alignment rate:   {gt['stats']['alignment_rate']*100:.0f}%")
    print(f"\nNext: run pipeline with:")
    print(f"  python3 benchmark/cadence/simulator.py {stem} clean-passthrough")
    print(f"  python3 benchmark/cadence/simulator.py {stem} ios-on-device-15")
    print(f"  dart run benchmark/replay/replay.dart ...")
    print(f"  python3 benchmark/metrics.py compare {stem}")


if __name__ == "__main__":
    main()
