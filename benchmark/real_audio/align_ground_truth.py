#!/usr/bin/env python3
"""Build a (time_ms → script_word_idx) ground truth trace.

We use Vosk's word-level timings (which are reasonably accurate for
alignment even when the *word identity* is wrong) and fuzzy-align
them to the real script using difflib.SequenceMatcher for a globally
optimal alignment. Interpolation fills gaps for times between aligned
anchors.

Output: `{audio}_gt.json` with:
  {
    "anchors": [[time_ms, script_word_idx], ...],  // matched words
    "samples": [[time_ms, script_word_idx], ...],  // interpolated continuous
    "stats":   {alignment_rate, total_vosk_words, matched_vosk_words}
  }
"""
import json
import re
import sys
from difflib import SequenceMatcher
from pathlib import Path

HERE = Path(__file__).parent

NON_ALNUM = re.compile(r"[^a-z0-9]")


def normalize(w: str) -> str:
    return NON_ALNUM.sub("", w.lower())


def phonetic_key(w: str) -> str:
    """Very coarse phonetic hash — keeps first letter + consonants."""
    s = normalize(w)
    if not s:
        return ""
    out = [s[0]]
    for ch in s[1:]:
        if ch not in "aeiou":
            out.append(ch)
        if len(out) >= 4:
            break
    return "".join(out)


def align(audio_stem: str, script_cap_words: int | None = None) -> None:
    """Align Vosk stream to the first N words of the script.

    For a 120-s clip at ~1.5–2 wps the speaker reaches at most ~250 words,
    so the cap defaults to 280. You can override per-stem below.
    """
    per_stem_cap = {
        "jfk": 280,
        "fdr": 220,
    }
    if script_cap_words is None:
        script_cap_words = per_stem_cap.get(audio_stem, 280)
    events_path = HERE / f"{audio_stem}_events.json"
    script_path = HERE / f"{audio_stem}_script.txt"
    out_path = HERE / f"{audio_stem}_gt.json"

    events = json.loads(events_path.read_text())
    script_words_raw = script_path.read_text().split()
    script_words = [normalize(w) for w in script_words_raw]
    script_sub = script_words[:script_cap_words]

    # Extract (time_ms, word_norm) sequence from Vosk finals in order.
    vosk_stream = []
    for ev in events:
        if not ev.get("is_final"):
            continue
        for w in ev.get("words", []):
            word = normalize(w["word"])
            if not word:
                continue
            time_ms = int(w["start"] * 1000)
            vosk_stream.append((time_ms, word))

    if not vosk_stream:
        print(f"No word timings in {events_path}", file=sys.stderr)
        sys.exit(1)

    vosk_words = [w for _, w in vosk_stream]
    vosk_times = [t for t, _ in vosk_stream]

    # Globally optimal word alignment: treat each word as an "autojunk"-
    # safe hashable token and find the longest common subsequence.
    # autojunk=False ensures common words (the/and/of) aren't discarded.
    sm = SequenceMatcher(a=vosk_words, b=script_sub, autojunk=False)
    blocks = sm.get_matching_blocks()

    anchors = []
    for blk in blocks:
        if blk.size == 0:
            continue
        for k in range(blk.size):
            vosk_i = blk.a + k
            script_i = blk.b + k
            anchors.append([vosk_times[vosk_i], script_i])

    if len(anchors) < 2:
        print(f"Only {len(anchors)} anchors — alignment failed", file=sys.stderr)
        sys.exit(1)

    # Enforce monotonicity (should already be from SequenceMatcher).
    anchors.sort(key=lambda p: (p[0], p[1]))

    # Build dense samples by linear interpolation between anchors.
    # Also extrapolate to cover [0, last_event_time_ms].
    total_ms = max(ev["time_ms"] for ev in events)
    samples = []
    # Prepend (0, 0) as an anchor before first detected word
    extended = [[0, 0]] + anchors + [[total_ms, anchors[-1][1]]]

    for i in range(len(extended) - 1):
        t0, p0 = extended[i]
        t1, p1 = extended[i + 1]
        if t1 <= t0:
            continue
        # Sample every 100 ms
        step = 100
        t = t0
        while t < t1:
            frac = (t - t0) / (t1 - t0)
            pos = round(p0 + frac * (p1 - p0))
            samples.append([t, pos])
            t += step
    samples.append([total_ms, extended[-1][1]])

    stats = {
        "total_vosk_words": len(vosk_stream),
        "matched_vosk_words": len(anchors),
        "alignment_rate": round(len(anchors) / max(1, len(vosk_stream)), 3),
        "script_words": len(script_words),
        "last_gt_position": anchors[-1][1],
        "total_audio_ms": total_ms,
    }

    out_path.write_text(json.dumps({
        "anchors": anchors,
        "samples": samples,
        "stats": stats,
    }, indent=2))

    print(f"Wrote {out_path.name}")
    print(f"  Vosk words:      {stats['total_vosk_words']}")
    print(f"  Aligned:         {stats['matched_vosk_words']} "
          f"({stats['alignment_rate'] * 100:.0f}%)")
    print(f"  Last GT position: {stats['last_gt_position']} / "
          f"{stats['script_words']} words "
          f"@ {anchors[-1][0] / 1000:.1f} s")


def align_with_paths(
    audio_stem: str,
    events_path: "Path",
    script_path: "Path",
    out_path: "Path",
    script_cap_words: int | None = None,
) -> None:
    """Align arbitrary events JSON against an arbitrary script file.

    Equivalent to align() but with explicit path overrides — used by the
    augment sweep so each aug-stem gets its own GT file without requiring
    the augmented events to live in real_audio/.
    """
    per_stem_base = {"jfk": 280, "fdr": 220}
    base_stem = audio_stem.split("__")[0]
    if script_cap_words is None:
        script_cap_words = per_stem_base.get(base_stem, 280)

    events = json.loads(events_path.read_text())
    script_words_raw = script_path.read_text().split()
    script_words = [normalize(w) for w in script_words_raw]
    script_sub = script_words[:script_cap_words]

    vosk_stream = []
    for ev in events:
        if not ev.get("is_final"):
            continue
        for w in ev.get("words", []):
            word = normalize(w["word"])
            if not word:
                continue
            time_ms = int(w["start"] * 1000)
            vosk_stream.append((time_ms, word))

    if not vosk_stream:
        print(f"No word timings in {events_path} — skipping GT", file=sys.stderr)
        # Write a minimal stub GT so metrics.py doesn't crash.
        total_ms = max((ev["time_ms"] for ev in events), default=0)
        out_path.write_text(json.dumps({
            "anchors": [[0, 0], [total_ms, 0]],
            "samples": [[0, 0], [total_ms, 0]],
            "stats": {
                "total_vosk_words": 0, "matched_vosk_words": 0,
                "alignment_rate": 0.0, "script_words": len(script_words),
                "last_gt_position": 0, "total_audio_ms": total_ms,
            },
        }, indent=2))
        print(f"Wrote stub {out_path.name} (0 words)")
        return

    vosk_words = [w for _, w in vosk_stream]
    vosk_times = [t for t, _ in vosk_stream]

    sm = SequenceMatcher(a=vosk_words, b=script_sub, autojunk=False)
    blocks = sm.get_matching_blocks()

    anchors = []
    for blk in blocks:
        if blk.size == 0:
            continue
        for k in range(blk.size):
            anchors.append([vosk_times[blk.a + k], blk.b + k])

    if len(anchors) < 2:
        # Fallback stub
        total_ms = max((ev["time_ms"] for ev in events), default=0)
        out_path.write_text(json.dumps({
            "anchors": [[0, 0], [total_ms, 0]],
            "samples": [[0, 0], [total_ms, 0]],
            "stats": {
                "total_vosk_words": len(vosk_stream), "matched_vosk_words": len(anchors),
                "alignment_rate": 0.0, "script_words": len(script_words),
                "last_gt_position": 0, "total_audio_ms": total_ms,
            },
        }, indent=2))
        print(f"Wrote stub {out_path.name} ({len(anchors)} anchors only)")
        return

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

    stats = {
        "total_vosk_words": len(vosk_stream),
        "matched_vosk_words": len(anchors),
        "alignment_rate": round(len(anchors) / max(1, len(vosk_stream)), 3),
        "script_words": len(script_words),
        "last_gt_position": anchors[-1][1],
        "total_audio_ms": total_ms,
    }

    out_path.write_text(json.dumps({"anchors": anchors, "samples": samples, "stats": stats}, indent=2))
    print(f"Wrote {out_path.name}")
    print(f"  Vosk words: {stats['total_vosk_words']}  "
          f"Aligned: {stats['matched_vosk_words']} ({stats['alignment_rate']*100:.0f}%)  "
          f"Last GT pos: {stats['last_gt_position']}")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("stems", nargs="*", default=["jfk"],
                    help="audio stem(s), e.g. jfk (legacy positional mode)")
    ap.add_argument("--events-path", type=Path, default=None,
                    help="explicit events JSON (overrides default HERE/<stem>_events.json)")
    ap.add_argument("--script-path", type=Path, default=None,
                    help="explicit script TXT (overrides default HERE/<stem>_script.txt)")
    ap.add_argument("--out", type=Path, default=None,
                    help="explicit output GT path (overrides default HERE/<stem>_gt.json)")
    args = ap.parse_args()

    if args.events_path or args.script_path or args.out:
        # Explicit-path mode: single stem required.
        if len(args.stems) != 1:
            sys.exit("Exactly one stem required when using --events-path/--script-path/--out")
        stem = args.stems[0]
        base_stem = stem.split("__")[0]
        ev_p = args.events_path or HERE / f"{stem}_events.json"
        sc_p = args.script_path or HERE / f"{base_stem}_script.txt"
        ou_p = args.out or HERE / f"{stem}_gt.json"
        align_with_paths(stem, ev_p, sc_p, ou_p)
    else:
        for stem in args.stems:
            align(stem)
