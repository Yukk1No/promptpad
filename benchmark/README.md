# PromptPad Benchmark Framework

Python-driven benchmark harness for the script-following matcher. The
matcher state machine lives in Dart
(`lib/services/script_matcher{,_v2,_v3}.dart`) and is invoked through a
thin replay shell — everything else is Python.

See `.omc/plans/benchmark-framework-spec.md` (§2 architecture) for the
3-axis design (audio × ASR × cadence) and §4 for the 4-layer metrics.
See `.omc/plans/spec-v0.3-changes.md` for the in-flight v0.3 spec update.

## Layout

```
benchmark/
├── word_timings.py            # legacy events.json → canonical word_timings.json
├── augment.py                 # WAV → augmented WAV (cafe-noise/reverb/bandlimit/pitch)
├── asr/
│   └── vosk_runner.py         # WAV → events.json (replaces legacy real_audio/run_vosk.py)
├── cadence/
│   ├── simulator.py           # word_timings.json + profile.yaml → events.json
│   ├── calibrate.py           # parse CADENCE: log lines from speech_service.dart
│   └── profiles/
│       ├── clean-passthrough.yaml    # control: 1 final per word, no cadence
│       └── ios-on-device-15.yaml     # iOS-like: cumulative partials + session_reset
├── replay/
│   └── replay.dart            # Dart shell — runs events through V1 / V2 / V3
├── metrics.py                 # Layer 1+2+3 (lag, stall, cross_session_recovery, boundary jumps)
├── viewport_metrics.py        # Layer 4 — off-screen duration, TTRV, unrecoverable count
├── make_tts_baseline.py       # piper-tts → tts_jfk fixtures (high-alignment GT baseline)
├── run.py                     # one-command orchestrator (--augments, --matchers)
└── results/
    ├── audio/<stem>__<augment>.wav
    ├── events_raw/<stem>__<augment>.json   # Vosk events on augmented audio
    ├── word_timings/<stem>.json
    ├── events/<stem>__<profile>.json
    ├── traces/<stem>__<profile>__<matcher>.json
    └── *.md                                # reports (kept in git)
```

## Matchers

| Matcher | File | Triggers |
|---|---|---|
| **V1** | `lib/services/script_matcher.dart` | classic char/word greedy + tail-match + sentence resync |
| **V2** | `lib/services/script_matcher_v2.dart` | V1 + tail-trim + beam recovery + stable-prefix buffer |
| **V3** 🆕 | `lib/services/script_matcher_v3.dart` | V2 + `onSessionReset()` hook + post-reset partial-recovery budget. Activates only on session_reset events with stale ASR; byte-identical to V2 on clean inputs. **10× MAE improvement** on noisy real-Vosk JFK ios profile. |

`replay.dart --matcher v1|v2|v3` selects.

Legacy `benchmark/{matcher_benchmark,real_audio_benchmark}.dart` are kept as
smoke tests but are NOT updated for new matcher work — the new framework
above is the single source of truth.

## Quick start

```bash
# Full pipeline on existing JFK Vosk events:
python3 benchmark/run.py jfk

# Only V2, only ios profile:
python3 benchmark/run.py jfk --profiles ios-on-device-15 --matchers v2

# Re-compute metrics without redoing the slow Dart replay:
python3 benchmark/run.py jfk --skip-replay
# (or directly: python3 benchmark/metrics.py compare jfk)
```

## Adding a new clip

1. Drop `<clip>_events.json` (Vosk format) and `<clip>_script.txt` into
   `benchmark/real_audio/`.
2. Run `python3 benchmark/real_audio/align_ground_truth.py <clip>` to make
   `<clip>_gt.json` (legacy format, currently consumed by `metrics.py`).
3. `python3 benchmark/run.py <clip>` does the rest.

**Quality gate**: clips with `alignment_rate < 30%` or `gap_words_p90 > 10`
are unfit for Layer 4 metrics. JFK at 46% is usable for Layer 1/2/3; FDR
at 18% is excluded (see spec §7 oracle pool).

## Adding a new cadence profile

Drop a YAML in `benchmark/cadence/profiles/`. Schema reference: spec §6 + the
two existing profiles. Two simulator branches today: `one_final_per_word: true`
(clean-passthrough flavor) vs default ios-like.

## Calibrating the iOS profile against your real device

1. `flutter run --dart-define=CADENCE_CALIBRATION=true`
2. Talk into the running app for 1+ minute (include 2-3 natural pauses to
   trigger `silence-restart`, and continuous talking past 50s to confirm
   `forced_restart_50s_observed > 0`).
3. Capture logs: `adb logcat -d | grep CADENCE > /tmp/cadence.log`
   (Android) or copy from the Xcode console (iOS).
4. `python3 benchmark/cadence/calibrate.py /tmp/cadence.log`
5. Replace the placeholder values in `cadence/profiles/ios-on-device-15.yaml`
   with the printed `# Suggested values`.

The calibration hook is gated by a compile-time const in
`lib/services/speech_service.dart` — flag-off builds carry zero cost.

## Metrics (current)

| Layer | Metric | What it tells you |
|---|---|---|
| 1 | `lag_words p50/p95/p99/max` | Position deviation in word-index space |
| 1 | `lag_ms p95/max` | Same but in time units (more user-relatable) |
| 1 | `overshoot_rate`, `max_overshoot_words` | Highlight running ahead of voice |
| 1 | `index_mae`, `match_us_p95` | Average error and per-call cost |
| 2 | `teleport_count_per_min`, `backward_jump_count` | Trajectory stability |
| 2 | `max_stall_ms` | Longest no-progress window |
| 2 | **`cross_session_recovery_ms_p50/p95/max`** | **Headline diagnostic for the V2 cumulative-text-contract failure mode** — see spec §4 Layer 2 |
| 2 | `cross_session_unrecovered_count` | Resets after which matcher never re-advanced (worst case) |
| 3 | `cross_para_per_min` | Jumps that crossed a paragraph (severe UX hit) |
| 3 | `same_para_far_per_min` | Same-paragraph jumps > 3 words (noticeable) |
| 3 | `within_3w_per_min` | Tiny jumps (mostly OK) |
| 4 🆕 | `off_screen_fraction`, `off_screen_duration_ms` | Time during which GT highlight falls outside what the rendered viewport would show, given the matcher's predicted scroll position |
| 4 🆕 | `ttrv_p50/p95/max` ms | Time to recover visibility — per off-screen episode, how long until back on-screen |
| 4 🆕 | `unrecoverable_count` | Episodes lasting ≥ 5 s (worst UX failures) |

Layer 4 was advanced from P2 to P0.5 — see `viewport_metrics.py compare <stem>`.
Caveat: words_per_line is approximated from script_display.dart layout to ±20%;
absolute ms numbers must be quoted only on `usable_for_layer4: true` clips
(alignment_rate ≥ 80%; tts_jfk @ 92% qualifies, jfk Vosk @ 46% does not).

## What's intentionally not here yet

- faster-whisper / cloud ASR runners — spec §5 P1
- Flutter widget-test layout oracle (replace Layer 4 approximation with
  real Wrap layout) — spec §5 P2
- sweep.py / regression.py / plot.py — spec §5 P1+P2
- L2-Arctic / accent corpora — spec §5 P3
- SJS user-study weight calibration — spec §5 P3
- Real-device cadence calibration (hook shipped; pending user run on
  iOS device) — spec §5 P0.0

P0.5 + V3 + TTS baseline + Layer 4 viewport are shipped. Layer 1 audio
degradation in flight. Integration in `results/ultrawork-integration.md`.
Per-track reports:
- `results/jfk-p0.5-report.md` — original cross_session_recovery_ms reproduction
- `results/v3-vs-v2-report.md` — V3 matcher A/B (10× MAE win on noisy real audio)
- `results/tts-true-baseline-report.md` — TTS 92%-aligned baseline (matcher core sound)
- `results/layer1-audio-degradation-report.md` — pending Layer 1 sweep agent
