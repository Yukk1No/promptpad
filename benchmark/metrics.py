#!/usr/bin/env python3
"""Compute Layer-1 / Layer-2 metrics from a replay trace, including the
spec's headline `cross_session_recovery_ms` indicator that captures the
V2 cross-session-contract failure mode.

Usage:
    python metrics.py --trace results/traces/jfk__ios-on-device-15__v2.json \
                      --gt    real_audio/jfk_gt.json
    python metrics.py compare jfk            # side-by-side V1 vs V2 on
                                              # all profiles for a clip
"""
from __future__ import annotations

import argparse
import bisect
import json
import statistics
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
TRACES_DIR = REPO / "benchmark" / "results" / "traces"
GT_DIR = REPO / "benchmark" / "real_audio"


# ---------------------------------------------------------------------------
# Script structure (Layer-3 prerequisite)
# ---------------------------------------------------------------------------

def script_word_to_paragraph(script_path: Path) -> list[int]:
    """Tokenize the script the same way Script.fromText does (whitespace
    split, markdown headings stripped) and return a list mapping word
    index → paragraph index. Paragraphs are separated by blank lines."""
    raw = script_path.read_text()
    # Match Script.fromText: drop heading lines (^#{1,6}) and metadata lines
    # (**Key:** Value) before first body, then collapse blank-line-separated
    # paragraphs.
    paragraphs: list[list[str]] = []
    current: list[str] = []
    seen_body = False
    metadata_re = __import__("re").compile(r"^\*\*[^*]+:\*\*")
    heading_re = __import__("re").compile(r"^#{1,6}\s+")
    for line in raw.splitlines():
        s = line.strip()
        if not s:
            if current:
                paragraphs.append(current)
                current = []
            continue
        if heading_re.match(s):
            continue
        if not seen_body and metadata_re.match(s):
            continue
        seen_body = True
        for tok in s.split():
            current.append(tok)
    if current:
        paragraphs.append(current)

    word_to_para: list[int] = []
    for pi, words in enumerate(paragraphs):
        for _ in words:
            word_to_para.append(pi)
    return word_to_para


# ---------------------------------------------------------------------------
# Ground truth
# ---------------------------------------------------------------------------

def load_gt(stem: str) -> tuple[list[int], list[int], dict]:
    p = GT_DIR / f"{stem}_gt.json"
    d = json.loads(p.read_text())
    samples = d["samples"]
    times = [int(s[0]) for s in samples]
    poses = [int(s[1]) for s in samples]
    return times, poses, d.get("stats", {})


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
    # Linear interp between i-1 and i.
    t0, t1 = times[i - 1], times[i]
    p0, p1 = poses[i - 1], poses[i]
    frac = (t - t0) / max(1, (t1 - t0))
    return int(round(p0 + frac * (p1 - p0)))


# ---------------------------------------------------------------------------
# Stats helpers
# ---------------------------------------------------------------------------

def percentile(xs: list[float], q: float) -> float:
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(q * (len(xs) - 1)))))
    return xs[k]


def fmt(x: float, unit: str = "") -> str:
    if x != x:           # NaN
        return "  n/a "
    if abs(x) >= 1000:
        return f"{x:5.0f}{unit}"
    if abs(x) >= 10:
        return f"{x:5.1f}{unit}"
    return f"{x:5.2f}{unit}"


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def compute(trace_path: Path, stem: str) -> dict[str, Any]:
    trace_doc = json.loads(trace_path.read_text())
    trace = trace_doc["trace"]
    gt_times, gt_poses, _ = load_gt(stem)
    script_path = trace_doc.get("script_path")
    word_to_para: list[int] = []
    if script_path:
        sp = Path(script_path)
        if not sp.is_absolute():
            sp = REPO / sp
        if sp.exists():
            word_to_para = script_word_to_paragraph(sp)

    # Walk trace, classifying entries.
    matches: list[dict[str, Any]] = []
    resets: list[dict[str, Any]] = []
    for e in trace:
        if e["kind"] == "match":
            matches.append(e)
        elif e["kind"] == "session_reset":
            resets.append(e)

    # Layer 1: position deviation
    lags = []          # max(0, gt - pred) — matcher behind GT
    overshoots = []    # max(0, pred - gt)  — highlight ahead of voice
    abs_errs = []
    match_us = []
    for m in matches:
        t = int(m["time_ms"])
        gt = gt_at(gt_times, gt_poses, t)
        pred = int(m["predicted_word_idx"])
        err = pred - gt
        abs_errs.append(abs(err))
        if err < 0:
            lags.append(-err)
            overshoots.append(0)
        else:
            lags.append(0)
            overshoots.append(err)
        match_us.append(int(m.get("match_us", 0)))

    overshoot_events = sum(1 for o in overshoots if o > 0)
    # Convert lag/overshoot from "words" to ms-equivalent using local GT slope
    # is fancy; for P0.5 we report in *words* and provide ms separately.
    # ms-equivalent: lag_ms = (gt_time_at_pred - pred_time) — i.e. how long
    # ago was GT at pred's position.
    lag_ms_list = []
    for m in matches:
        pred = int(m["predicted_word_idx"])
        t = int(m["time_ms"])
        # Find earliest GT time where pos >= pred.
        if pred <= gt_poses[0]:
            lag_ms_list.append(0)
            continue
        if pred > gt_poses[-1]:
            lag_ms_list.append(0)  # past end of GT, skip
            continue
        # Linear search backwards from end (poses are roughly monotonic).
        gt_t_at_pred = None
        for i in range(len(gt_poses)):
            if gt_poses[i] >= pred:
                gt_t_at_pred = gt_times[i]
                break
        if gt_t_at_pred is None:
            continue
        lag_ms_list.append(max(0, t - gt_t_at_pred))

    # Layer 2: trajectory stability
    poses_seq = [int(m["predicted_word_idx"]) for m in matches]
    times_seq = [int(m["time_ms"]) for m in matches]
    teleport_count = sum(
        1 for i in range(1, len(poses_seq))
        if poses_seq[i] - poses_seq[i - 1] > 5
    )
    backward_jumps = sum(
        1 for i in range(1, len(poses_seq))
        if poses_seq[i] < poses_seq[i - 1]
    )
    # max_stall_ms: longest run of consecutive matches where pos doesn't grow.
    max_stall_ms = 0
    stall_start = times_seq[0] if times_seq else 0
    last_pos = poses_seq[0] if poses_seq else 0
    for i in range(1, len(poses_seq)):
        if poses_seq[i] > last_pos:
            stall = times_seq[i] - stall_start
            if stall > max_stall_ms:
                max_stall_ms = stall
            stall_start = times_seq[i]
            last_pos = poses_seq[i]
    if times_seq and poses_seq[-1] == last_pos:
        # Trailing stall
        max_stall_ms = max(max_stall_ms, times_seq[-1] - stall_start)

    # Layer 3: boundary jumps. Classify each Δposition into a boundary class
    # using the script's paragraph structure (cross-section needs markdown
    # heading; JFK script has none, so cross_section is always 0 here).
    jump_class_counts = {
        "same_word": 0,
        "within_3w": 0,
        "same_para_far": 0,
        "cross_para": 0,
    }
    if word_to_para:
        for i in range(1, len(poses_seq)):
            d = poses_seq[i] - poses_seq[i - 1]
            if d == 0:
                jump_class_counts["same_word"] += 1
                continue
            cur, prev = poses_seq[i], poses_seq[i - 1]
            cur_p = word_to_para[min(cur, len(word_to_para) - 1)]
            prev_p = word_to_para[min(prev, len(word_to_para) - 1)]
            if cur_p != prev_p:
                jump_class_counts["cross_para"] += 1
            elif abs(d) <= 3:
                jump_class_counts["within_3w"] += 1
            else:
                jump_class_counts["same_para_far"] += 1

    # CROSS-SESSION RECOVERY — the headline metric
    cross_recovery_ms: list[int] = []
    cross_unrecovered = 0
    for r in resets:
        reset_t = int(r["time_ms"])
        baseline = int(r["predicted_word_idx_at_reset"])
        # Find next match after reset_t where pred > baseline.
        recovered = False
        for m in matches:
            mt = int(m["time_ms"])
            if mt < reset_t:
                continue
            if int(m["predicted_word_idx"]) > baseline:
                cross_recovery_ms.append(mt - reset_t)
                recovered = True
                break
        if not recovered:
            cross_unrecovered += 1

    duration_min = ((times_seq[-1] - times_seq[0]) / 60_000.0) if times_seq else 0.001

    return {
        "trace": str(trace_path.relative_to(REPO)),
        "matcher": trace_doc.get("matcher_version"),
        "match_calls": len(matches),
        "session_resets": len(resets),
        "duration_min": duration_min,
        "layer1": {
            "lag_words_p50": percentile(lags, 0.50),
            "lag_words_p95": percentile(lags, 0.95),
            "lag_words_p99": percentile(lags, 0.99),
            "lag_words_max": max(lags) if lags else 0,
            "lag_ms_p95": percentile(lag_ms_list, 0.95),
            "lag_ms_max": max(lag_ms_list) if lag_ms_list else 0,
            "overshoot_rate": overshoot_events / max(1, len(matches)),
            "max_overshoot_words": max(overshoots) if overshoots else 0,
            "index_mae": statistics.fmean(abs_errs) if abs_errs else float("nan"),
            "match_us_p95": percentile(match_us, 0.95),
        },
        "layer2": {
            "teleport_count_per_min": teleport_count / max(0.001, duration_min),
            "backward_jump_count": backward_jumps,
            "max_stall_ms": max_stall_ms,
            "cross_session_recovery_ms_p50": (percentile(cross_recovery_ms, 0.50)
                                              if cross_recovery_ms else 0),
            "cross_session_recovery_ms_p95": (percentile(cross_recovery_ms, 0.95)
                                              if cross_recovery_ms else 0),
            "cross_session_recovery_ms_max": (max(cross_recovery_ms)
                                              if cross_recovery_ms else 0),
            "cross_session_recovered_count": len(cross_recovery_ms),
            "cross_session_unrecovered_count": cross_unrecovered,
        },
        "layer3": {
            "cross_para_per_min": (jump_class_counts["cross_para"]
                                   / max(0.001, duration_min)),
            "same_para_far_per_min": (jump_class_counts["same_para_far"]
                                      / max(0.001, duration_min)),
            "within_3w_per_min": (jump_class_counts["within_3w"]
                                  / max(0.001, duration_min)),
            "jump_class_counts": jump_class_counts,
            "paragraph_count": (max(word_to_para) + 1) if word_to_para else 0,
        },
    }


# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------

def print_one(m: dict[str, Any]) -> None:
    print(f"\n=== {m['trace']} ({m['matcher']}, {m['duration_min']:.1f} min, "
          f"{m['match_calls']} matches, {m['session_resets']} resets) ===")
    L1 = m["layer1"]
    L2 = m["layer2"]
    print(f"  Layer 1 (position):")
    print(f"    lag_words p50/p95/p99/max  = {fmt(L1['lag_words_p50'])} / "
          f"{fmt(L1['lag_words_p95'])} / {fmt(L1['lag_words_p99'])} / "
          f"{fmt(L1['lag_words_max'])}")
    print(f"    lag_ms     p95/max         = {fmt(L1['lag_ms_p95'],'ms')} / "
          f"{fmt(L1['lag_ms_max'],'ms')}")
    print(f"    overshoot rate / max words = {L1['overshoot_rate']*100:5.1f}%  / "
          f"{fmt(L1['max_overshoot_words'])}")
    print(f"    index MAE / match_us p95   = {fmt(L1['index_mae'])} / "
          f"{fmt(L1['match_us_p95'],'µs')}")
    print(f"  Layer 2 (trajectory + cross-session):")
    print(f"    teleports/min / backward   = {fmt(L2['teleport_count_per_min'])} / "
          f"{L2['backward_jump_count']}")
    print(f"    max_stall_ms               = {fmt(L2['max_stall_ms'],'ms')}")
    print(f"    *** cross_session_recovery_ms p50/p95/max = "
          f"{fmt(L2['cross_session_recovery_ms_p50'],'ms')} / "
          f"{fmt(L2['cross_session_recovery_ms_p95'],'ms')} / "
          f"{fmt(L2['cross_session_recovery_ms_max'],'ms')}  "
          f"recovered={L2['cross_session_recovered_count']} "
          f"unrecovered={L2['cross_session_unrecovered_count']}")
    L3 = m["layer3"]
    print(f"  Layer 3 (boundary jumps, {L3['paragraph_count']} paragraphs):")
    print(f"    cross_para / same_para_far / within_3w  per min = "
          f"{fmt(L3['cross_para_per_min'])} / "
          f"{fmt(L3['same_para_far_per_min'])} / "
          f"{fmt(L3['within_3w_per_min'])}")


def print_compare(rows: list[dict[str, Any]]) -> None:
    # Group by profile.
    headers = ("profile", "matcher", "matches", "lag_p95(w)", "max_stall(ms)",
               "x-recover_p95(ms)", "x-recover_max(ms)", "unrecovered")
    print(f"\n{headers[0]:<22} {headers[1]:<4} {headers[2]:>8} "
          f"{headers[3]:>10} {headers[4]:>13} {headers[5]:>17} "
          f"{headers[6]:>17} {headers[7]:>11}")
    print("-" * 110)
    for r in rows:
        L1 = r["layer1"]
        L2 = r["layer2"]
        prof = Path(r["trace"]).stem.split("__")[1]
        print(f"{prof:<22} {r['matcher']:<4} {r['match_calls']:>8} "
              f"{L1['lag_words_p95']:>10.1f} "
              f"{L2['max_stall_ms']:>13.0f} "
              f"{L2['cross_session_recovery_ms_p95']:>17.0f} "
              f"{L2['cross_session_recovery_ms_max']:>17.0f} "
              f"{L2['cross_session_unrecovered_count']:>11}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    one = sub.add_parser("one")
    one.add_argument("--trace", type=Path, required=True)
    one.add_argument("--clip", required=True, help="GT stem, e.g. jfk")

    cmp = sub.add_parser("compare")
    cmp.add_argument("clip", help="GT stem (jfk)")

    # Default: if first positional arg looks like a clip name AND no subcommand,
    # treat as 'compare'.
    args = ap.parse_args()
    if args.cmd == "one":
        m = compute(args.trace, args.clip)
        print_one(m)
        return
    if args.cmd == "compare":
        clip = args.clip
        rows: list[dict[str, Any]] = []
        for trace in sorted(TRACES_DIR.glob(f"{clip}__*__*.json")):
            rows.append(compute(trace, clip))
        # Sort: clean-passthrough first, then ios-, by matcher v1->v2
        def key(r):
            stem = Path(r["trace"]).stem
            parts = stem.split("__")
            prof = parts[1] if len(parts) > 1 else ""
            return (0 if "clean" in prof else 1, prof, r["matcher"])
        rows.sort(key=key)
        for r in rows:
            print_one(r)
        print_compare(rows)
        return

    ap.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
