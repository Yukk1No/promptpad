#!/usr/bin/env python3
"""Generalized Vosk ASR runner — CLI wrapper around the legacy run_vosk logic.

Run Vosk streaming ASR on any WAV file and write all partial/final events
as a JSON array in the same schema as ``benchmark/real_audio/jfk_events.json``:

    [{time_ms, text, is_final, words}, ...]

Usage
-----
    python3 benchmark/asr/vosk_runner.py --wav INPUT.wav --out events.json
    python3 benchmark/asr/vosk_runner.py --wav INPUT.wav \\
        --out events.json --model path/to/vosk-model

The ``--model`` flag defaults to ``benchmark/real_audio/model`` which is
where the legacy ``run_vosk.py`` loads its model from.
"""
from __future__ import annotations

import argparse
import json
import sys
import wave
from pathlib import Path

from vosk import KaldiRecognizer, Model, SetLogLevel

SetLogLevel(-1)

REPO = Path(__file__).resolve().parents[2]
DEFAULT_MODEL = REPO / "benchmark" / "real_audio" / "model"

# 125 ms chunks — close to real iOS partial cadence (100-300 ms).
CHUNK_MS = 125


def run_vosk(wav_path: Path, model_dir: Path, out_path: Path) -> None:
    if not model_dir.exists():
        sys.exit(f"ERROR: Vosk model dir not found: {model_dir}")
    if not wav_path.exists():
        sys.exit(f"ERROR: WAV file not found: {wav_path}")

    model = Model(str(model_dir))

    with wave.open(str(wav_path), "rb") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            sys.exit("ERROR: wav must be 16-bit mono")
        sample_rate = wf.getframerate()
        frames_per_chunk = sample_rate * CHUNK_MS // 1000

        rec = KaldiRecognizer(model, sample_rate)
        rec.SetWords(True)

        events: list[dict] = []
        audio_offset_ms = 0
        last_partial_text = ""

        while True:
            data = wf.readframes(frames_per_chunk)
            if len(data) == 0:
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

        # Flush tail
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
    partials = len(events) - finals
    total_words = sum(len(e.get("words", [])) for e in events if e["is_final"])

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(events, indent=2))

    print(f"vosk_runner: {wav_path.name}: {len(events)} events "
          f"({partials} partials + {finals} finals), {total_words} recognized words")
    print(f"wrote {out_path}")

    final_text = " ".join(e["text"] for e in events if e["is_final"])
    print()
    print("=== Recognized final text (first 300 chars) ===")
    print(final_text[:300])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--wav", required=True, type=Path, help="Input WAV file (16-bit mono)")
    ap.add_argument("--out", required=True, type=Path, help="Output events JSON path")
    ap.add_argument("--model", type=Path, default=DEFAULT_MODEL,
                    help=f"Vosk model directory (default: {DEFAULT_MODEL})")
    args = ap.parse_args()

    run_vosk(args.wav, args.model, args.out)


if __name__ == "__main__":
    main()
