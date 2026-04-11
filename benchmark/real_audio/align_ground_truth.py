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


if __name__ == "__main__":
    stems = sys.argv[1:] or ["jfk"]
    for stem in stems:
        align(stem)
