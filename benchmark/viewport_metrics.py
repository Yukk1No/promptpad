#!/usr/bin/env python3
"""Layer 4 viewport metrics — off-screen duration, TTRV, unrecoverable count.

The teleprompter UI auto-scrolls so that the matcher's *predicted* word sits
at ~1/3 from the top of the screen. The user's *actual* reading position
(GT) is only visible if it falls within the viewport currently rendered
around the predicted position. When the matcher is wrong, the user can be
literally unable to see where they are on screen — the worst UX failure
mode this benchmark can capture.

This module is independent of metrics.py (Layer 1+2+3) so it can be
extended without churn. Run after metrics.py for any (trace, gt) pair.

Usage:
    python viewport_metrics.py \\
        --trace results/traces/jfk__ios-on-device-15__v2.json \\
        --gt    real_audio/jfk_gt.json \\
        --preset iphone-13-mini-fontsize-42

CAVEAT (per spec v0.2 §9 risk #1): the words_per_line approximation only
matches Flutter's real Wrap layout to ±20%. For ranking matchers (V2 vs
V3) on the same preset the relative ordering is reliable, but absolute
ms numbers should be cross-checked against a Flutter widget-test layout
oracle (P2 work).
"""
from __future__ import annotations

import argparse
import bisect
import json
import statistics
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------------------
# Viewport presets — derived from script_display.dart layout parameters:
#   horizontal padding=32, Wrap spacing=8, runSpacing=fontSize*0.4,
#   line height = fontSize*1.5, highlight anchor = screenHeight/3.
# words_per_line is computed from (screen_width - 2*padding) / avg_word_px
# where avg_word_px = (avg_word_chars * fontSize * 0.6) + spacing for bold.
# ---------------------------------------------------------------------------

PRESETS = {
    "iphone-13-mini-fontsize-42": {
        "screen_width_px": 375,
        "screen_height_px": 812,
        "horizontal_padding_px": 32,
        "vertical_padding_frac": 0.4,
        "font_size": 42,
        "spacing_px": 8,
        "avg_word_chars": 5,
        "char_to_font_ratio_bold": 0.6,
        "highlight_anchor_frac": 1.0 / 3.0,
    },
    "iphone-15-pro-fontsize-42": {
        "screen_width_px": 393,
        "screen_height_px": 852,
        "horizontal_padding_px": 32,
        "vertical_padding_frac": 0.4,
        "font_size": 42,
        "spacing_px": 8,
        "avg_word_chars": 5,
        "char_to_font_ratio_bold": 0.6,
        "highlight_anchor_frac": 1.0 / 3.0,
    },
    "ipad-mini-fontsize-42": {
        "screen_width_px": 744,
        "screen_height_px": 1133,
        "horizontal_padding_px": 32,
        "vertical_padding_frac": 0.4,
        "font_size": 42,
        "spacing_px": 8,
        "avg_word_chars": 5,
        "char_to_font_ratio_bold": 0.6,
        "highlight_anchor_frac": 1.0 / 3.0,
    },
    "pixel-6-fontsize-36": {
        "screen_width_px": 412,
        "screen_height_px": 915,
        "horizontal_padding_px": 32,
        "vertical_padding_frac": 0.4,
        "font_size": 36,
        "spacing_px": 8,
        "avg_word_chars": 5,
        "char_to_font_ratio_bold": 0.6,
        "highlight_anchor_frac": 1.0 / 3.0,
    },
}


def derive(preset: dict) -> dict:
    """Compute words_per_line + visible_lines from preset.

    NOTE: `vertical_padding_frac` in script_display.dart is the scroll
    container's content padding (so the first/last word can scroll to the
    1/3 highlight anchor), NOT the visible viewport size. The viewport is
    the full screen height; only horizontal_padding shrinks word area.
    """
    fs = preset["font_size"]
    avg_word_px = (preset["avg_word_chars"] * fs * preset["char_to_font_ratio_bold"]
                   + preset["spacing_px"])
    usable_width = preset["screen_width_px"] - 2 * preset["horizontal_padding_px"]
    words_per_line = max(1.0, usable_width / avg_word_px)
    line_height_px = fs * 1.5 + fs * 0.4   # font line-height + Wrap runSpacing
    visible_height = preset["screen_height_px"]   # full screen visible
    visible_lines = max(1, visible_height / line_height_px)
    return {
        "words_per_line": words_per_line,
        "line_height_px": line_height_px,
        "visible_lines": visible_lines,
        "highlight_anchor_frac": preset["highlight_anchor_frac"],
    }


def word_to_line(word_idx: int, derived: dict) -> int:
    return int(word_idx / derived["words_per_line"])


def gt_visible(pred_word_idx: int, gt_word_idx: int, derived: dict) -> bool:
    pred_line = word_to_line(pred_word_idx, derived)
    gt_line = word_to_line(gt_word_idx, derived)
    n = derived["visible_lines"]
    top = pred_line - n * derived["highlight_anchor_frac"]
    bot = pred_line + n * (1.0 - derived["highlight_anchor_frac"])
    return top <= gt_line <= bot


# ---------------------------------------------------------------------------
# GT lookup
# ---------------------------------------------------------------------------

def load_gt(gt_path: Path) -> tuple[list[int], list[int]]:
    d = json.loads(gt_path.read_text())
    samples = d["samples"]
    return [int(s[0]) for s in samples], [int(s[1]) for s in samples]


def gt_at(times: list[int], poses: list[int], t: int) -> int:
    if not times:
        return 0
    if t <= times[0]:
        return poses[0]
    if t >= times[-1]:
        return poses[-1]
    i = bisect.bisect_left(times, t)
    if times[i] == t:
        return poses[i]
    t0, t1 = times[i - 1], times[i]
    p0, p1 = poses[i - 1], poses[i]
    frac = (t - t0) / max(1, (t1 - t0))
    return int(round(p0 + frac * (p1 - p0)))


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def percentile(xs: list[float], q: float) -> float:
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(q * (len(xs) - 1)))))
    return xs[k]


def compute(trace_path: Path, gt_path: Path, preset_name: str) -> dict:
    preset = PRESETS[preset_name]
    derived = derive(preset)

    trace_doc = json.loads(trace_path.read_text())
    matches = [e for e in trace_doc["trace"] if e["kind"] == "match"]
    gt_times, gt_poses = load_gt(gt_path)

    # Walk match events; track viewport visibility episodes.
    off_screen_total_ms = 0
    episodes_ms: list[int] = []
    unrecoverable = 0
    UNRECOV_THRESHOLD_MS = 5000

    cur_off_screen_start: int | None = None
    prev_t: int | None = None

    for m in matches:
        t = int(m["time_ms"])
        pred = int(m["predicted_word_idx"])
        gt = gt_at(gt_times, gt_poses, t)
        visible = gt_visible(pred, gt, derived)

        if not visible:
            if cur_off_screen_start is None:
                cur_off_screen_start = t
            if prev_t is not None:
                off_screen_total_ms += t - prev_t
        else:
            if cur_off_screen_start is not None:
                ep_ms = t - cur_off_screen_start
                episodes_ms.append(ep_ms)
                if ep_ms >= UNRECOV_THRESHOLD_MS:
                    unrecoverable += 1
                cur_off_screen_start = None

        prev_t = t

    # Trailing off-screen — counts as unrecoverable if long enough.
    if cur_off_screen_start is not None and matches:
        ep_ms = int(matches[-1]["time_ms"]) - cur_off_screen_start
        episodes_ms.append(ep_ms)
        if ep_ms >= UNRECOV_THRESHOLD_MS:
            unrecoverable += 1

    duration_ms = (matches[-1]["time_ms"] - matches[0]["time_ms"]) if matches else 1

    return {
        "trace": str(trace_path.relative_to(REPO)) if trace_path.is_relative_to(REPO) else str(trace_path),
        "gt": str(gt_path.relative_to(REPO)) if gt_path.is_relative_to(REPO) else str(gt_path),
        "preset": preset_name,
        "derived": {k: round(v, 2) for k, v in derived.items()},
        "match_events": len(matches),
        "duration_ms": duration_ms,
        "off_screen_duration_ms": off_screen_total_ms,
        "off_screen_fraction": off_screen_total_ms / max(1, duration_ms),
        "off_screen_episodes": len(episodes_ms),
        "ttrv_p50_ms": round(percentile(episodes_ms, 0.50), 0) if episodes_ms else 0,
        "ttrv_p95_ms": round(percentile(episodes_ms, 0.95), 0) if episodes_ms else 0,
        "ttrv_max_ms": max(episodes_ms) if episodes_ms else 0,
        "unrecoverable_count": unrecoverable,
    }


def print_one(m: dict) -> None:
    print(f"\n=== Layer 4 viewport ({m['preset']}) ===")
    print(f"  trace            : {m['trace']}")
    print(f"  derived          : words_per_line={m['derived']['words_per_line']:.1f}  "
          f"visible_lines={m['derived']['visible_lines']:.1f}")
    print(f"  duration_ms      : {m['duration_ms']}")
    print(f"  off_screen_ms    : {m['off_screen_duration_ms']}  "
          f"({m['off_screen_fraction']*100:.1f}% of session)")
    print(f"  episodes         : {m['off_screen_episodes']}")
    print(f"  TTRV p50/p95/max : {m['ttrv_p50_ms']:.0f} / {m['ttrv_p95_ms']:.0f} / "
          f"{m['ttrv_max_ms']} ms")
    print(f"  unrecoverable    : {m['unrecoverable_count']}  "
          f"(off-screen episodes ≥ 5 s)")


def find_gt(stem: str) -> Path:
    return REPO / "benchmark" / "real_audio" / f"{stem}_gt.json"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    one = sub.add_parser("one", help="single trace")
    one.add_argument("--trace", type=Path, required=True)
    one.add_argument("--gt", type=Path, required=True)
    one.add_argument("--preset", default="iphone-13-mini-fontsize-42",
                     choices=sorted(PRESETS.keys()))
    one.add_argument("--json", action="store_true")

    cmp = sub.add_parser("compare",
                         help="all traces for a stem (jfk / tts_jfk / etc.)")
    cmp.add_argument("stem")
    cmp.add_argument("--preset", default="iphone-13-mini-fontsize-42",
                     choices=sorted(PRESETS.keys()))

    # Bare invocation: behave like `one` with required flags (back-compat).
    ap.add_argument("--trace", type=Path)
    ap.add_argument("--gt", type=Path)
    ap.add_argument("--preset", default="iphone-13-mini-fontsize-42",
                    choices=sorted(PRESETS.keys()))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if args.cmd == "compare":
        gt = find_gt(args.stem)
        if not gt.exists():
            raise SystemExit(f"no GT at {gt}")
        traces = sorted((REPO / "benchmark" / "results" / "traces").glob(
            f"{args.stem}__*.json"))
        rows = []
        for t in traces:
            try:
                rows.append(compute(t, gt, args.preset))
            except Exception as e:
                print(f"  ! skip {t.name}: {e}")

        # Sort: clean-passthrough first then ios-, by matcher v1→v2→v3
        def key(r):
            stem = Path(r["trace"]).stem
            parts = stem.split("__")
            prof = parts[1] if len(parts) > 1 else ""
            mat = parts[2] if len(parts) > 2 else ""
            return (0 if "clean" in prof else 1, prof, mat)
        rows.sort(key=key)
        for r in rows:
            print_one(r)
        # Compact summary table
        print(f"\nLayer 4 ({rows[0]['preset'] if rows else 'preset'}) summary:")
        h = ("profile", "matcher", "off%", "episodes", "TTRV p95",
             "unrecov")
        print(f"  {h[0]:<22} {h[1]:<4} {h[2]:>6} {h[3]:>9} {h[4]:>10} "
              f"{h[5]:>8}")
        print("  " + "-" * 70)
        for r in rows:
            stem = Path(r["trace"]).stem
            parts = stem.split("__")
            prof = parts[1] if len(parts) > 1 else "?"
            mat = parts[2] if len(parts) > 2 else "?"
            print(f"  {prof:<22} {mat:<4} "
                  f"{r['off_screen_fraction']*100:>5.1f}% "
                  f"{r['off_screen_episodes']:>9} "
                  f"{r['ttrv_p95_ms']:>8.0f}ms "
                  f"{r['unrecoverable_count']:>8}")
        return

    if args.cmd == "one" or args.trace:
        trace = args.trace if args.cmd != "one" else args.trace
        gt = args.gt if args.cmd != "one" else args.gt
        preset = args.preset
        as_json = args.json
        if args.cmd == "one":
            trace = args.trace
            gt = args.gt
            preset = args.preset
            as_json = args.json
        if not trace or not gt:
            ap.print_help()
            raise SystemExit(2)
        m = compute(trace, gt, preset)
        if as_json:
            print(json.dumps(m, indent=2))
        else:
            print_one(m)
        return

    ap.print_help()
    raise SystemExit(2)


if __name__ == "__main__":
    main()
