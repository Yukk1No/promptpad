#!/usr/bin/env python3
"""Run Vosk streaming ASR on a WAV file, save all partial/final events as JSON.

The resulting events list mirrors what an iOS SFSpeechRecognizer user
experiences in real-time: partial hypotheses churning forward, then a
final result when the recognizer decides a segment is stable.
"""
import json
import sys
import wave
from pathlib import Path

from vosk import Model, KaldiRecognizer, SetLogLevel

SetLogLevel(-1)

HERE = Path(__file__).parent
MODEL_DIR = HERE / "model"

# 125 ms chunks — close to real iOS partial cadence (100-300 ms).
CHUNK_MS = 125


def main():
    stem = sys.argv[1] if len(sys.argv) > 1 else "jfk"
    wav_path = HERE / f"{stem}.wav"
    out_path = HERE / f"{stem}_events.json"

    if not MODEL_DIR.exists():
        print(f"ERROR: model dir {MODEL_DIR} missing", file=sys.stderr)
        sys.exit(1)

    model = Model(str(MODEL_DIR))
    with wave.open(str(wav_path), "rb") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            print("ERROR: wav must be 16-bit mono", file=sys.stderr)
            sys.exit(1)
        sample_rate = wf.getframerate()
        frames_per_chunk = sample_rate * CHUNK_MS // 1000

        rec = KaldiRecognizer(model, sample_rate)
        rec.SetWords(True)

        events = []
        audio_offset_ms = 0
        last_partial_text = ""

        while True:
            data = wf.readframes(frames_per_chunk)
            if len(data) == 0:
                break
            audio_offset_ms += (len(data) // 2) * 1000 // sample_rate

            if rec.AcceptWaveform(data):
                # Final result for a segment
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
                # Partial — only emit when it changed, matching iOS behavior
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

    # Summary
    finals = sum(1 for e in events if e["is_final"])
    partials = len(events) - finals
    total_words = sum(len(e.get("words", [])) for e in events if e["is_final"])

    out_path.write_text(json.dumps(events, indent=2))
    print(f"Processed {wav_path.name}: {len(events)} events "
          f"({partials} partials + {finals} finals), "
          f"{total_words} recognized words")
    print(f"Wrote {out_path}")

    # Show final recognized text for sanity
    final_text = " ".join(
        e["text"] for e in events if e["is_final"]
    )
    print()
    print("=== Recognized final text ===")
    print(final_text)


if __name__ == "__main__":
    main()
