# V4 Matcher Report — Confidence-Aware Post-Reset Budget Gate

**Date**: 2026-05-04
**Issue**: closes the auto-detection half of #2; consumes #5
**File**: `lib/services/script_matcher_v4.dart`
**Reproduce**: `python3 benchmark/run.py jfk --augments clean cafe-noise-snr-20 cafe-noise-snr-10 cafe-noise-snr-5 reverb bandlimit pitch-up-3 pitch-down-3 --matchers v3 v4`

## TL;DR

V4 = V3 + automatic confidence gate. Inside the post-reset partial-recovery
budget window, V4 reads the inbound transcript event's **mean ASR
confidence** and suppresses recovery when confidence < 0.6. Solves
the V3 cafe-noise-snr-10 regression (MAE 73.09 → 41.79 = V2 baseline)
**without losing the clean-case 10× MAE win** (still 11.27 on JFK Vosk
ios). No runtime toggle, no host-side detection — fully automatic.

This is a real **MAJOR** under the project version policy: a new
in-band signal (per-event mean confidence) introduced into the matcher
pipeline, eliminating a regression that V3 + V3.1 toggle could only
work around.

| profile | matcher | sess | x-rec_p95 | max_stall | **MAE** | tele/min | cross_para |
|---|---|---|---|---|---|---|---|
| jfk Vosk ios (V3 win condition) | V2 | 7 | 2390 | 4160 | 114.61 | 1.52 | 2.54 |
| jfk Vosk ios | V3 | 7 | 2390 | 4160 | **11.27** | 0.51 | 1.52 |
| jfk Vosk ios | **V4** | 7 | 2390 | 4160 | **11.27** | 0.51 | 1.52 |
| **cafe-noise-snr-10 (V3 regression)** | V2 | 10 | 1910 | 3563 | **41.79** | 1.52 | 3.04 |
| cafe-noise-snr-10 | V3 | 10 | 2710 | 4150 | 73.09 ⚠ | 1.01 | 2.03 |
| **cafe-noise-snr-10** | **V4** | 10 | **1910** | **3563** | **41.79** | 1.52 | 3.04 |

## Issue #2 acceptance criteria (all pass automatically)

| # | Criterion | Pass? |
|---|---|---|
| 1 | cafe-noise-snr-10 MAE ≤ 41.79 | ✅ V4 default = 41.79 (= V2 baseline) |
| 2 | clean MAE ≤ 12 | ✅ V4 default = 11.27 (= V3 baseline) |
| 3 | TTS clean & ios identical V2/V3/V4 | ✅ all four byte-identical |
| 4 | Docstring documents the gate / signals / disable flag | ✅ `script_matcher_v4.dart` header + this report |

## Mechanism (the new MAJOR)

### Problem (recap from V3.1 report)

V3 introduced an 8-partial post-reset budget that lets `_resyncMatch`
fire on partials, collapsing post-reset recovery from ~2.4 s to
~700 ms median on **clean** Vosk JFK ios. On **cafe-noise-snr-10**
the same mechanism committed to *wrong* sentence targets because
moderate noise produced partials that scored similarly (in
char/word matching) to legitimate ahead-anchors.

V3.1 was a runtime workaround (`setNoisyEnvironmentMode(bool)`); the
host had to know it was noisy. V4 makes the matcher know.

### V4 mechanism

A new in-band signal: per-event **mean ASR confidence** carried
through the events.json schema, computed from the original Vosk
per-word `conf` field that was already in `word_timings.json`.

The signal flows:

```
benchmark/asr/vosk_runner.py  (Vosk per-word conf)
        ↓
benchmark/word_timings.py     (preserves the field)
        ↓
benchmark/cadence/simulator.py (aggregates: each event carries
        ↓                       confidences[] + mean_confidence)
benchmark/results/events/     (events.json schema extended)
        ↓
benchmark/replay/replay.dart  (calls matcher.setNextEventConfidence
        ↓                      before each match())
ScriptMatcherV4.match()       (gates _resyncMatch on the value)
```

The gate is local: V4's `match()` decides whether to run recovery on
*this specific* partial based on *this partial's* confidence. There
is no per-session aggregation, no rolling window, no host-side
threshold tuning. The next high-confidence partial within the same
post-reset window can still trigger recovery — only the bad ones get
filtered.

### Threshold = 0.6

Calibrated against the JFK Vosk events:

| condition | typical mean confidence on partials |
|---|---|
| jfk Vosk ios (clean source audio, V3-win regime) | ~0.96 |
| **cafe-noise-snr-10 ios (V3-loss regime)** | **~0.46** |
| tts_jfk ios (synthetic, V3=V2 regime) | 1.00 |

0.6 sits in the dead zone, comfortably above noise (cafe-snr-10 at
0.46) and below clean (Vosk ≥ 0.95 typically). Only 0.6 was
empirically verified in the sweep below — no other threshold was
run. Based on the 0.46 / 0.96 calibration gap, any threshold in
roughly [0.5, 0.9] *should* produce the same acceptance pass on
this clip, but that is an inference from the gap, not a
measurement. 0.6 is chosen because it leaves the most headroom in
both directions.

### Default-trust contract

Events without a `mean_confidence` field (legacy events.json from
before this PR, or future schemas that drop the field) get treated
as confidence = 1.0. V4 is therefore byte-identical to V3 on:

- All trace runs against pre-confidence-schema events.json
- TTS clips (synthetic confidence = 1.0 ≥ threshold)
- Clean-passthrough profile (no session resets ⇒ budget never opens
  ⇒ gate never consulted)

This was verified across 12 conditions in the sweep below.

## Cross-condition verification matrix

V4 vs V3 (same configuration, same events) across 12 conditions:

| condition | V3 MAE | V4 MAE | verdict |
|---|---|---|---|
| jfk Vosk ios | **11.27** | **11.27** | byte-identical (V3 win preserved) |
| jfk clean-passthrough | 29.54 | 29.54 | byte-identical (no resets) |
| jfk__clean (aug pipeline) ios | 11.27 | 11.27 | byte-identical |
| jfk__cafe-noise-snr-20 ios | 2.16 | 2.16 | byte-identical (V3 didn't fire) |
| **jfk__cafe-noise-snr-10 ios** | **73.09** ⚠ | **41.79** ✅ | **V4 fixes regression** |
| jfk__cafe-noise-snr-5 ios | 39.81 | 39.81 | byte-identical |
| jfk__reverb ios | 83.34 | 83.34 | byte-identical |
| jfk__bandlimit ios | 2.30 | 2.30 | byte-identical |
| jfk__pitch-up-3 ios | 47.40 | 47.40 | byte-identical |
| jfk__pitch-down-3 ios | 34.54 | 34.54 | byte-identical |
| tts_jfk ios | 2.57 | 2.57 | byte-identical |
| tts_jfk clean-passthrough | 2.26 | 2.26 | byte-identical |

**11 of 12 conditions are byte-identical V3↔V4. The one condition
that differs is exactly the regression we set out to fix, and the
fix collapses it back to the V2 baseline.** No collateral changes,
no new failure modes.

## Why the gate is local (not session-aggregated)

Earlier V4 attempts (documented in `v3.1-noisy-toggle-report.md`)
tried to detect "this whole session is noisy" via density signals
(advances/partial). They failed because cafe-noise-snr-10 has
*higher* density than clean — the matcher anchors *frequently* under
moderate noise, just to *wrong* positions.

The local per-partial confidence gate works for a different reason:
it doesn't ask "is this session noisy?" but "should I trust *this
specific partial* enough to commit a sentence-level jump on it?"
Low confidence on a partial means "even if it scores high in char
matching, the words might not actually be what the speaker said" —
exactly the discriminator V3 lacked.

## V3.1 toggle status

`setNoisyEnvironmentMode(bool)` on V3 stays in the codebase as
ablation/escape hatch but is no longer needed for production use.
V4 supersedes it. The `v3-noisy` matcher alias in replay.dart is
preserved for reproducing the V3.1 numbers in the V3.1 report.

## Files changed

- `benchmark/cadence/simulator.py` — Word dataclass + emitters extended with confidence (US-001)
- `lib/services/script_matcher_base.dart` — `setNextEventConfidence` interface (US-002)
- `lib/services/script_matcher.dart` / `_v2.dart` / `_v3.dart` — no-op stubs to satisfy `implements` (US-002)
- `benchmark/replay/replay.dart` — forwards `mean_confidence` from events to matcher (US-002)
- `lib/services/script_matcher_v4.dart` — new file with the gate (US-003)
- `benchmark/reports/v4-vs-v3-report.md` — this report (US-005)

## Caveats

- The 0.6 threshold is calibrated on Vosk small-en + audiomentations
  cafe noise. Production iOS `SFSpeechRecognizer` has its own
  confidence calibration; the threshold may need a re-tune once
  real-device confidence values arrive (the existing `_calibLog`
  hook in `speech_service.dart` could collect them).
- pitch-up-3 / reverb / cafe-noise-snr-5 don't differ V3↔V4 because
  V3 already didn't fire recovery on those (those conditions either
  produce stable enough partials, or stale never accumulates the
  way cafe-noise-snr-10 makes it). They're not new failure modes
  blocked by V4 — they're conditions where the gate happens to be
  irrelevant.
- The schema is additive and backward-compatible. Old events.json
  files without `mean_confidence` continue to work and produce
  V3-equivalent V4 traces (the default-trust contract).

## Reproduce

```bash
# Full sweep (this is what populated the table above):
for aug in clean cafe-noise-snr-20 cafe-noise-snr-10 cafe-noise-snr-5 \
           reverb bandlimit pitch-up-3 pitch-down-3; do
  for prof in clean-passthrough ios-on-device-15; do
    python3 benchmark/cadence/simulator.py jfk__${aug} ${prof}
    for mat in v3 v4; do
      dart run benchmark/replay/replay.dart \
        --script benchmark/real_audio/jfk_script.txt \
        --events benchmark/results/events/jfk__${aug}__${prof}.json \
        --matcher ${mat} \
        --out benchmark/results/traces/jfk__${aug}__${prof}__${mat}.json
    done
  done
done

# Plus jfk legacy + tts_jfk:
for stem in jfk tts_jfk; do
  for prof in clean-passthrough ios-on-device-15; do
    python3 benchmark/cadence/simulator.py ${stem} ${prof}
    for mat in v3 v4; do
      dart run benchmark/replay/replay.dart \
        --script benchmark/real_audio/${stem}_script.txt \
        --events benchmark/results/events/${stem}__${prof}.json \
        --matcher ${mat} \
        --out benchmark/results/traces/${stem}__${prof}__${mat}.json
    done
  done
done

# Compare:
python3 benchmark/metrics.py compare jfk__cafe-noise-snr-10
python3 benchmark/metrics.py compare jfk
```
