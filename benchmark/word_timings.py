#!/usr/bin/env python3
"""Convert Vosk-style ASR event log into the canonical word_timings.json
described in the spec §7. Word_timings.json is the input to the cadence
simulator — it represents the ground-truth time axis of the speaker.

We use Vosk's `words` field on isFinal=true events; each word entry has
`{word, start, end, conf}` with seconds-valued timestamps. Output is a
flat sequence sorted by start_ms.

Usage:
    python word_timings.py jfk          # benchmark/real_audio/jfk_events.json
                                        # → benchmark/results/word_timings/jfk.json
    python word_timings.py jfk --engine vosk-small-en
    python word_timings.py jfk --events-path /path/to/events.json --out /path/to/out.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LEGACY_EVENTS_DIR = REPO / "benchmark" / "real_audio"
OUT_DIR = REPO / "benchmark" / "results" / "word_timings"


def convert(stem: str, engine: str, events_path: Path | None = None) -> dict:
    if events_path is not None:
        src = events_path
    else:
        src = LEGACY_EVENTS_DIR / f"{stem}_events.json"
    if not src.exists():
        raise FileNotFoundError(src)
    raw = json.loads(src.read_text())

    audio_duration_ms = max(int(ev["time_ms"]) for ev in raw)

    words = []
    for ev in raw:
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
                "confidence": round(float(w.get("conf", 0.0)), 4),
            })
    words.sort(key=lambda w: w["start_ms"])

    try:
        src_rel = str(src.relative_to(REPO))
    except ValueError:
        src_rel = str(src)

    return {
        "clip_id": stem,
        "engine": engine,
        "audio_duration_ms": audio_duration_ms,
        "source_events_path": src_rel,
        "words": words,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("stem", help="audio stem, e.g. jfk")
    ap.add_argument("--engine", default="vosk-small-en")
    ap.add_argument("--events-path", type=Path, default=None,
                    help="explicit events JSON path (overrides default legacy path)")
    ap.add_argument("--out", type=Path, default=None,
                    help="output path (default: results/word_timings/<stem>.json)")
    args = ap.parse_args()

    payload = convert(args.stem, args.engine, events_path=args.events_path)
    out = args.out or (OUT_DIR / f"{args.stem}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {out.relative_to(REPO)}  "
          f"({len(payload['words'])} words, "
          f"{payload['audio_duration_ms']/1000:.1f}s)")


if __name__ == "__main__":
    main()
