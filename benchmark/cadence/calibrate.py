#!/usr/bin/env python3
"""Extract cadence profile parameters from CADENCE_CALIBRATION logs.

Usage:
    flutter run --dart-define=CADENCE_CALIBRATION=true   # talk for 30+ s
    adb logcat -d | grep CADENCE > /tmp/cadence.log      # Android
    # or copy from Xcode console on iOS
    python benchmark/cadence/calibrate.py /tmp/cadence.log

Output: percentile stats for partial / final intervals, silence-to-restart
gap, and a count of forced 50 s health-check restarts. Use these to fill in
benchmark/cadence/profiles/ios-on-device-15.yaml (or android-google.yaml).
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

LINE_RE = re.compile(r"CADENCE:\s*(\{.*\})")


def parse(path: Path) -> list[dict[str, Any]]:
    events = []
    for raw in path.read_text(errors="replace").splitlines():
        m = LINE_RE.search(raw)
        if not m:
            continue
        try:
            events.append(json.loads(m.group(1)))
        except json.JSONDecodeError:
            continue
    events.sort(key=lambda e: e["t"])
    return events


def pcts(xs: list[float]) -> dict[str, float]:
    if not xs:
        return {"n": 0}
    xs = sorted(xs)
    return {
        "n": len(xs),
        "median": xs[len(xs) // 2],
        "p10": xs[max(0, int(len(xs) * 0.10))],
        "p90": xs[min(len(xs) - 1, int(len(xs) * 0.90))],
        "min": xs[0],
        "max": xs[-1],
    }


def analyse(events: list[dict[str, Any]]) -> dict[str, Any]:
    # Bucket result events by epoch — that's what speech_to_text considers a session
    by_epoch: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for ev in events:
        if ev["kind"] == "result":
            by_epoch[ev["epoch"]].append(ev)

    partial_gaps_ms: list[float] = []
    final_gaps_ms: list[float] = []
    for epoch_events in by_epoch.values():
        prev_partial_t: int | None = None
        prev_final_t: int | None = None
        for ev in epoch_events:
            if ev["is_final"]:
                if prev_final_t is not None:
                    final_gaps_ms.append(ev["t"] - prev_final_t)
                prev_final_t = ev["t"]
                prev_partial_t = None
            else:
                if prev_partial_t is not None:
                    partial_gaps_ms.append(ev["t"] - prev_partial_t)
                prev_partial_t = ev["t"]

    # Silence trigger: time between last result of a session and the
    # `status: notListening` event that ends it.
    silence_gaps_ms: list[float] = []
    last_result_t: int | None = None
    for ev in events:
        if ev["kind"] == "result":
            last_result_t = ev["t"]
        elif ev["kind"] == "status" and ev.get("status") == "notListening":
            if last_result_t is not None and not ev.get("manual_restart"):
                silence_gaps_ms.append(ev["t"] - last_result_t)
                last_result_t = None

    health_check_restarts = sum(
        1 for ev in events if ev["kind"] == "health_check_restart"
    )
    auto_relistens = sum(
        1 for ev in events if ev["kind"] == "session_start"
        and ev.get("reason") == "auto_relisten"
    )
    manual_restarts = sum(
        1 for ev in events if ev["kind"] == "manual_restart_begin"
    )

    return {
        "session_count": len(by_epoch),
        "result_events": sum(len(v) for v in by_epoch.values()),
        "partial_interval_ms": pcts(partial_gaps_ms),
        "final_interval_ms": pcts(final_gaps_ms),
        "silence_trigger_ms": pcts(silence_gaps_ms),
        "health_check_50s_restarts": health_check_restarts,
        "auto_relisten_count": auto_relistens,
        "manual_restart_count": manual_restarts,
    }


def render_yaml_hint(stats: dict[str, Any]) -> str:
    p = stats["partial_interval_ms"]
    f = stats["final_interval_ms"]
    s = stats["silence_trigger_ms"]
    lines = [
        "# Suggested values for ios-on-device-15.yaml (verify and round)",
    ]
    if p.get("n"):
        lines.append(f"partial_interval_ms: {round(p['median'])}  "
                     f"# observed median {p['median']:.0f}, p10–p90 {p['p10']:.0f}–{p['p90']:.0f}")
    if f.get("n"):
        lines.append(f"final_interval_ms: [{round(f['p10'])}, {round(f['p90'])}]  "
                     f"# observed p10–p90 ms")
    lines.append("session_reset:")
    if s.get("n"):
        lines.append(f"  silence_trigger_ms: {round(s['median'])}  "
                     f"# observed median; p90 {s['p90']:.0f}")
    lines.append(f"  forced_restart_50s_observed: "
                 f"{stats['health_check_50s_restarts']}  "
                 f"# >0 confirms iOS 60s reset is real on this device")
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("log", type=Path,
                    help="path to file with CADENCE: lines (logcat / Xcode console)")
    ap.add_argument("--json", action="store_true",
                    help="machine-readable output only")
    args = ap.parse_args()

    events = parse(args.log)
    if not events:
        print("No CADENCE: events found. Did you build with "
              "--dart-define=CADENCE_CALIBRATION=true ?", file=sys.stderr)
        sys.exit(1)

    stats = analyse(events)
    if args.json:
        print(json.dumps(stats, indent=2))
        return

    print(f"Parsed {len(events)} CADENCE events across "
          f"{stats['session_count']} ASR session(s).")
    print()
    for label in ("partial_interval_ms", "final_interval_ms", "silence_trigger_ms"):
        d = stats[label]
        if not d.get("n"):
            print(f"  {label}: (no samples)")
            continue
        print(f"  {label}: n={d['n']} median={d['median']:.0f} "
              f"p10={d['p10']:.0f} p90={d['p90']:.0f} "
              f"min={d['min']:.0f} max={d['max']:.0f}")
    print(f"  health_check_50s_restarts: {stats['health_check_50s_restarts']}")
    print(f"  auto_relistens (silence): {stats['auto_relisten_count']}")
    print(f"  manual_restarts: {stats['manual_restart_count']}")
    print()
    print(render_yaml_hint(stats))


if __name__ == "__main__":
    main()
