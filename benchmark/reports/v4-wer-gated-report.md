# V4 Matcher Report — Runtime-Toggle Noisy Environment Mode

**Date**: 2026-05-03
**Issue**: #2 (V4 matcher: WER-gated post-reset partial-recovery budget)
**File**: `lib/services/script_matcher_v4.dart`
**Reproduce**: `python3 benchmark/run.py jfk --augments clean cafe-noise-snr-10 --matchers v2 v3 v4`

## TL;DR

V4 ships as **V3 + an opt-in `setNoisyEnvironmentMode(true)` flag** that
short-circuits to V2 behaviour when noise is known. Three V4 attempts at
auto-detecting "noisy" from in-band signals failed because V3's
clean-case win and noise-case loss come from the same mechanism
(`_resyncMatch` firing on partials post-reset) and cannot be separated
without per-word ASR confidence values that are not in the current
events.json schema.

| profile | matcher | x-rec_p95 (ms) | max_stall (ms) | MAE | teleports/min | cross_para/min |
|---|---|---|---|---|---|---|
| ios (clean Vosk) | V2 | 2390 | 4160 | 114.61 | 1.52 | 2.54 |
| ios (clean Vosk) | V3 | 2390 | 4160 | **11.27** | 0.51 | 1.52 |
| ios (clean Vosk) | **V4 default** | 2390 | 4160 | **11.27** | 0.51 | 1.52 |
| ios (clean Vosk) | **V4-noisy** | 2390 | 4160 | 114.61 | 1.52 | 2.54 |
| **cafe-noise-snr-10** | V2 | 1910 | 3563 | **41.79** | 1.52 | 3.04 |
| **cafe-noise-snr-10** | V3 | 2710 | 4150 | 73.09 ⚠ | 1.01 | 2.03 |
| **cafe-noise-snr-10** | **V4 default** | 2710 | 4150 | 73.09 ⚠ | 1.01 | 2.03 |
| **cafe-noise-snr-10** | **V4-noisy** | 1910 | 3563 | **41.79** | 1.52 | 3.04 |

⚠ Known regression. With V4-noisy on, this row falls back to V2 numbers.

## Issue #2 acceptance criteria

| # | Criterion | Pass? |
|---|---|---|
| 1 | cafe-noise-snr-10 MAE ≤ 41.79 | ✓ with `v4-noisy` (= 41.79). ✗ for default V4 (= 73.09 = V3 inherited regression) |
| 2 | clean MAE ≤ 12 | ✓ default V4 = 11.27 |
| 3 | TTS clean & ios identical V2/V3/V4 | ✓ all three byte-identical (no resets fire post-reset budget under TTS) |
| 4 | Docstring documents the gate + signals + disable flag | ✓ see `lib/services/script_matcher_v4.dart` header + this report |

## What we tried (in order)

### Attempt 1: Stricter resync minScore + minWords inside post-reset window

Bumped `_resyncMatch` minScore from 15 → 25; bumped post-reset minWords
from 2 → 4.

**Result**: Killed the V3 clean win (clean MAE 11.27 → 81.59) without
fixing cafe-noise-snr-10 (MAE 73.09 → 71.78). The clean-case good
anchors and the noise-case bad anchors land in the same score range,
so a higher score threshold filters both equally.

### Attempt 2: Disable `_resyncMatch` entirely inside post-reset window

Inside the budget window, skip resync; only let `_beamRecovery` fire if
stale ≥ 12.

**Result**: Same as attempt 1 — clean MAE 81.59, cafe-noise unchanged
71.78. V3's clean win actually IS the resync-on-partial firing; without
it, V4 falls back to V2-on-the-relevant-events (which also has high
MAE).

### Attempt 3: Replace `_resyncMatch` with `_beamRecovery` (lower stale gate)

Inside the budget window, fire `_beamRecovery` (score ≥ 35,
anchor-weighted) at stale ≥ 2 instead of resync.

**Result**: Identical to attempt 2. `_beamRecovery` early-returns when
`spkNorm.length < 2`, which is true for most short post-reset partials,
so the recovery never actually fires.

### Density signal probe (rejected before implementation)

Computed "advances per partial" density across V3 traces:

| condition | avg_density |
|---|---|
| clean | 0.467 |
| cafe-noise-snr-10 | **0.900** |
| cafe-noise-snr-5 | 0.583 |
| pitch-up-3 | 0.218 |
| bandlimit | 1.045 |

The signal is NOT a clean separator: cafe-noise-snr-10 actually has
higher density than clean. On moderate noise the matcher anchors
*frequently* — to *wrong* positions. Density measures "how often
matcher anchors", not "how often it anchors correctly". Without GT
or confidence the matcher can't tell the difference.

## Why auto-detection fundamentally fails (the deeper finding)

V3's resync-on-partial has two regimes:

- **Clean**: cumulative partial contains real script words → resync
  finds the right ahead-target → committing the jump is correct.
- **Moderate noise**: cumulative partial contains words that are
  systematically misheard but happen to look like a phrase 1–3
  sentences ahead → resync finds that wrong target with comparable
  score → committing is wrong.

Char/word match scoring is ambiguous between these two regimes. The
disambiguator is *whether the words actually came from the speaker*
— per-word confidence from the ASR engine. iOS `SFSpeechRecognizer`
provides confidence per result; the `speech_to_text` Flutter plugin
exposes a single overall confidence per result; word-level confidence
would require either the iOS native API or a Vosk-style runner.

**Until the events.json schema carries per-word or per-final
confidence, no purely matcher-side gate can distinguish clean from
moderate-noise post-reset partials.**

## V4 final design

V4 = V3 + `setNoisyEnvironmentMode(bool)` runtime flag.

- **Default (off)**: V4 == V3. The post-reset budget opens on every
  `onSessionReset()`. 10× MAE win on clean, regression on
  cafe-noise-snr-10 inherited from V3.
- **Noisy mode (on)**: `onSessionReset()` skips opening the budget.
  V4 == V2 with respect to recovery. Mid-quality MAE on noisy clips,
  no clean-case win.

The host (PromptPad UI / `teleprompter_screen.dart`) decides which
mode to run. Recommended triggers:
- A "Café mode" Settings toggle.
- iOS `AVAudioSession` peak-noise-level reading > threshold
  (Apple-provided; no extra ASR plumbing required).
- A `--prefer-stability` startup flag for users who report
  "matcher jumps to wrong place" complaints.

V4 is a strict superset of V3 (defaults match), so adopting V4 is
risk-free for users currently on V3.

## Caveats

- The cafe-noise-snr-10 regression is **only fixable** in default mode
  by adding ASR confidence to the events.json schema. Filed as
  follow-up work.
- V4 was tested against the same 8 audio augments as V3. The
  conditions where V3 = V2 byte-identical (cafe-noise-snr-{20,5},
  reverb, bandlimit, pitch-{up,down}-3) all behave the same under V4
  default and V4-noisy — the post-reset budget never fires recovery
  on those because stale doesn't accumulate fast enough.
- TTS 92%-aligned baseline is byte-identical V2/V3/V4/V4-noisy on
  both profiles. No-op for V4 in the TTS regime.

## Follow-ups

- Issue #2 stays open as "auto-detection requires ASR confidence in
  events.json".
- New issue (filed separately): extend `events.json` schema to carry
  per-word confidence; rerun all benchmark runs with the richer
  schema; revisit V4 auto-detection.
- Production rollout: wire `teleprompter_screen.dart` to set
  `setNoisyEnvironmentMode` based on AVAudioSession noise readings or
  a user-visible Settings toggle.

## Reproduce

```bash
# Compare V2 / V3 / V4-default / V4-noisy on key conditions
for aug in clean cafe-noise-snr-10; do
  for mat in v2 v3 v4 v4-noisy; do
    dart run benchmark/replay/replay.dart \
      --script benchmark/real_audio/jfk_script.txt \
      --events benchmark/results/events/jfk__${aug}__ios-on-device-15.json \
      --matcher ${mat} \
      --out benchmark/results/traces/jfk__${aug}__ios-on-device-15__${mat}.json
  done
done
python3 benchmark/metrics.py compare jfk__clean
python3 benchmark/metrics.py compare jfk__cafe-noise-snr-10
```
