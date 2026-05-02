#!/usr/bin/env python3
"""One-command pipeline driver.

  python run.py jfk                              # all profiles × v1+v2
  python run.py jfk --profiles ios-on-device-15  # subset
  python run.py jfk --matchers v2
  python run.py jfk --augments clean cafe-noise-snr-10 reverb

Steps (no --augments):
  1. word_timings.py <stem>                                # legacy → canonical
  2. cadence/simulator.py <stem> <profile>  for each profile
  3. dart run benchmark/replay/replay.dart   for each (profile × matcher)
  4. metrics.py compare <stem>                             # report

Steps (with --augments):
  For each augment:
    1a. augment.py → results/audio/<stem>__<augment>.wav
    1b. asr/vosk_runner.py → results/events_raw/<stem>__<augment>.json
    1c. word_timings.py --events-path → results/word_timings/<stem>__<augment>.json
    2.  cadence/simulator.py for each profile (using augmented word_timings)
    3.  dart replay for each (augment × profile × matcher)
  4. metrics.py compare <stem> for each augment-stem

Outputs land in benchmark/results/{word_timings, events, events_raw, audio, traces}/.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent
PROFILES_DIR = HERE / "cadence" / "profiles"
REAL_AUDIO_DIR = HERE / "real_audio"
RESULTS_DIR = HERE / "results"

# Use the venv python when available (it has both vosk and audiomentations).
_VENV_PY = HERE / ".venv" / "bin" / "python3"
PYTHON = str(_VENV_PY) if _VENV_PY.exists() else sys.executable


def run(cmd: list[str], cwd: Path = REPO) -> None:
    print(f"\n$ {' '.join(str(c) for c in cmd)}")
    r = subprocess.run(cmd, cwd=cwd)
    if r.returncode != 0:
        sys.exit(f"command failed (exit {r.returncode}): {' '.join(str(c) for c in cmd)}")


def run_augment_pipeline(
    stem: str,
    augments: list[str],
    profiles: list[str],
    matchers: list[str],
    skip_replay: bool,
) -> None:
    """Run the full augment sweep: augment → ASR → word_timings → cadence → replay → metrics."""
    wav_path = REAL_AUDIO_DIR / f"{stem}.wav"
    if not wav_path.exists():
        sys.exit(f"ERROR: WAV not found: {wav_path}")

    for augment in augments:
        aug_stem = f"{stem}__{augment}"
        audio_out = RESULTS_DIR / "audio" / f"{aug_stem}.wav"
        events_raw_out = RESULTS_DIR / "events_raw" / f"{aug_stem}.json"
        word_timings_out = RESULTS_DIR / "word_timings" / f"{aug_stem}.json"

        # 1a. Audio augmentation
        print(f"\n=== augment: {augment} ===")
        run([
            PYTHON, str(HERE / "augment.py"),
            "--wav", str(wav_path),
            "--preset", augment,
            "--out", str(audio_out),
        ])

        # 1b. Vosk ASR on degraded audio
        run([
            PYTHON, str(HERE / "asr" / "vosk_runner.py"),
            "--wav", str(audio_out),
            "--out", str(events_raw_out),
        ])

        # 1c. Convert events → word_timings
        run([
            PYTHON, str(HERE / "word_timings.py"),
            aug_stem,
            "--events-path", str(events_raw_out),
            "--out", str(word_timings_out),
        ])

        # 1d. Build ground-truth alignment for this augmented events
        gt_out = REAL_AUDIO_DIR / f"{aug_stem}_gt.json"
        script_path = REAL_AUDIO_DIR / f"{stem}_script.txt"
        run([
            PYTHON, str(REAL_AUDIO_DIR / "align_ground_truth.py"),
            aug_stem,
            "--events-path", str(events_raw_out),
            "--script-path", str(script_path),
            "--out", str(gt_out),
        ])

        # 2. Cadence simulator for each profile
        for profile in profiles:
            events_out = RESULTS_DIR / "events" / f"{aug_stem}__{profile}.json"
            run([
                PYTHON, str(HERE / "cadence" / "simulator.py"),
                aug_stem, profile,
                "--out", str(events_out),
            ])

        # 3. Dart replay for each profile × matcher
        if not skip_replay:
            script = REAL_AUDIO_DIR / f"{stem}_script.txt"
            for profile in profiles:
                for matcher in matchers:
                    events = RESULTS_DIR / "events" / f"{aug_stem}__{profile}.json"
                    trace = RESULTS_DIR / "traces" / f"{aug_stem}__{profile}__{matcher}.json"
                    run([
                        "dart", "run", "benchmark/replay/replay.dart",
                        "--script", str(script.relative_to(REPO)),
                        "--events", str(events.relative_to(REPO)),
                        "--matcher", matcher,
                        "--out", str(trace.relative_to(REPO)),
                    ])

    # 4. Metrics for each augment-stem
    for augment in augments:
        aug_stem = f"{stem}__{augment}"
        run([PYTHON, str(HERE / "metrics.py"), "compare", aug_stem])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("stem", help="audio stem, e.g. jfk")
    ap.add_argument("--profiles", nargs="+", default=None,
                    help="cadence profile name(s); default = all in profiles/")
    ap.add_argument("--matchers", nargs="+", default=["v1", "v2"])
    ap.add_argument("--skip-replay", action="store_true",
                    help="skip Dart replay step (use cached traces)")
    ap.add_argument("--augments", nargs="+", default=None,
                    help="audio augmentation preset(s) to sweep; "
                         "if omitted the legacy single-axis flow runs unchanged")
    args = ap.parse_args()

    if args.profiles is None:
        args.profiles = sorted(p.stem for p in PROFILES_DIR.glob("*.yaml"))

    if not shutil.which("dart") and not args.skip_replay:
        sys.exit("dart not found in PATH; install Flutter SDK or pass "
                 "--skip-replay to reuse existing traces")

    # -----------------------------------------------------------------------
    # Augment sweep path
    # -----------------------------------------------------------------------
    if args.augments:
        run_augment_pipeline(
            stem=args.stem,
            augments=args.augments,
            profiles=args.profiles,
            matchers=args.matchers,
            skip_replay=args.skip_replay,
        )
        return

    # -----------------------------------------------------------------------
    # Legacy single-axis flow (unchanged behaviour when no --augments given)
    # -----------------------------------------------------------------------

    # 1. word_timings
    run([PYTHON, str(HERE / "word_timings.py"), args.stem])

    # 2. cadence simulator for each profile
    for profile in args.profiles:
        run([PYTHON, str(HERE / "cadence" / "simulator.py"),
             args.stem, profile])

    # 3. replay (Dart) for each profile × matcher
    if not args.skip_replay:
        for profile in args.profiles:
            for matcher in args.matchers:
                events = (REPO / "benchmark" / "results" / "events"
                          / f"{args.stem}__{profile}.json")
                trace = (REPO / "benchmark" / "results" / "traces"
                         / f"{args.stem}__{profile}__{matcher}.json")
                script = (REPO / "benchmark" / "real_audio"
                          / f"{args.stem}_script.txt")
                run([
                    "dart", "run", "benchmark/replay/replay.dart",
                    "--script", str(script.relative_to(REPO)),
                    "--events", str(events.relative_to(REPO)),
                    "--matcher", matcher,
                    "--out", str(trace.relative_to(REPO)),
                ])

    # 4. metrics report
    run([PYTHON, str(HERE / "metrics.py"), "compare", args.stem])


if __name__ == "__main__":
    main()
