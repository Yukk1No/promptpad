# P0.5 Report: V2 Cross-Session Failure — JFK Reproduction

**Date**: 2026-04-30
**Clip**: `jfk` (JFK 1961 inaugural, 120 s, Vosk-small-en alignment 46% / 90 anchors)
**Matchers compared**: V1 (`script_matcher.dart`) vs V2 (`script_matcher_v2.dart`)
**Cadence profiles**: `clean-passthrough` (control) and `ios-on-device-15`
**Run**: `python3 benchmark/run.py jfk`

## TL;DR

| profile | matcher | matches | lag_p95 (w) | max_stall (ms) | x-recover_p95 (ms) | x-recover_max (ms) | unrecovered |
|---|---|---|---|---|---|---|---|
| clean-passthrough | v1 | 196 | 48.0 | 7350 | 0 | 0 | 0 |
| clean-passthrough | v2 | 196 | 55.0 | 7350 | 0 | 0 | 0 |
| ios-on-device-15 | v1 | 1309 | 0.0 | 4080 | 2230 | 2230 | 0 |
| ios-on-device-15 | v2 | 1309 | 0.0 | 4160 | 2390 | 2390 | 0 |

**Core finding**: 7 simulated `session_reset` events caused both matchers to
take ~1–2.4 seconds each to re-advance past their pre-reset position.
Total stuck time ≈ 14 s of 120 s = **~12% of session duration spent in
post-reset stall**, matching the production "V2 卡住" complaint.

## Method

1. `word_timings.py` extracted Vosk word-level timings from the existing
   `benchmark/real_audio/jfk_events.json` (196 words across 37 finals).
2. `cadence/simulator.py` rendered the word_timings into two events.json
   variants:
   - `clean-passthrough`: each word = one `final` event at its start_ms;
     no partials, no session reset.
   - `ios-on-device-15`: cumulative-within-session partials at 80 ms cadence;
     session boundary inserted whenever silence gap > 1500 ms (yielded 8
     sessions / 7 reset events on JFK; final at end of each session).
3. `replay/replay.dart` walked each events.json through V1 and V2,
   emitting per-event traces with predicted_word_idx + match() µs cost.
   `session_reset` entries were recorded but `match()` was *not* called —
   that's the contract break we're trying to measure.
4. `metrics.py` joined trace × ground truth and computed Layer 1+2+3.

## Key observations

### 1. The 4-second stall is the visible failure

`max_stall_ms = 4080 ms (V1) / 4160 ms (V2)` on the ios profile. That's the
longest single window where the matcher's `_recognizedCharCount` did not
advance. In production this is what the user sees as "frozen highlight".

### 2. Cross-session recovery dominates the stall

`cross_session_recovery_ms_max ≈ 2.4 s`, recovered = 7/7 (no permanent
unrecoverable). The headline metric directly attributes ~half of the
visible stall to the cross-session contract break: after every silence
> 1.5 s, the matcher waits ~1–2.4 s before its position re-advances,
because the next session's first transcript starts from empty text and
V2's `_matchStartOffset` is still pinned to the previous session's
final position.

### 3. V2 is NOT specifically broken; V1 has the same symptom

V2's recovery time is ~7% worse than V1's (2390 vs 2230 ms), not the
order-of-magnitude difference one would expect if the bug were V2-introduced.
The **cumulative-text-contract assumption is shared by both matchers**
(both use `_matchStartOffset`-anchored char-level greedy match). V2's
extra machinery (tail-trim, beam recovery) doesn't help here because
none of it is triggered by "fresh empty text" — it requires text to
exist first.

**Implication**: a hypothetical V3 that simply listens for `session_reset`
and either resets `_matchStartOffset` or runs an explicit re-anchor on
the new session's first final would likely recover in <500 ms. This is
testable by adding a `--matcher v3` to `replay.dart` and re-running.

### 4. Layer 1 lag = 0 on ios profile is misleading

The `lag_words` metric reports 0 for ios while overshoot rate is 99.8%
because cumulative partials advance the matcher *ahead* of GT. This is
an artifact of (a) sparse GT (90 anchors over 120 s) being interpolated
generously between matched Vosk words, and (b) cumulative partials
giving the matcher long anchor-rich text to find matches deep in the
script. Don't read the ios `lag_p95 = 0` as "matcher follows GT
perfectly" — read it as "matcher is consistently ahead of GT, often by
167–236 words." This is exactly the GT-quality concern Codex flagged
(`alignment_rate=46%, p90 gap=5w` is borderline for Layer 1 on ios).

### 5. clean-passthrough exposes a different baseline issue

Both matchers lag 26–29 words (MAE) on clean-passthrough — that's not a
cadence problem, it's because Vosk's mishearings populate the events.
The first Vosk "word" is "right" but JFK actually said "Vice" — so the
matcher's first events don't align to the script's first words at all,
and it lags until enough correct words accumulate to anchor. This is a
**lower bound on matcher robustness against Vosk-style ASR errors with
zero cadence churn**. P1 should add `clean-passthrough` runs against
the *true* script word_timings (not Vosk's misheard ones) to separate
"matcher vs ASR errors" from "matcher vs cadence behavior".

### 6. Layer 3 boundary jumps: V2 modestly helps

| profile | matcher | cross_para/min | same_para_far/min |
|---|---|---|---|
| clean-passthrough | v1 | 2.03 | 0.51 |
| clean-passthrough | v2 | 1.01 | 0.51 |
| ios-on-device-15 | v1 | 3.05 | 3.55 |
| ios-on-device-15 | v2 | 2.54 | 2.54 |

V2 cuts cross-paragraph jumps roughly in half on clean-passthrough
(2.03 → 1.01 per minute), confirming the tail-trim mechanism does
prevent some paragraph teleports. On ios profile the absolute jump rate
roughly triples for both — cumulative partials produce more anchor
matches, hence more aggressive forward jumps; V2 is somewhat but not
dramatically better.

## Caveats

- **iOS profile parameters are placeholder estimates**. Real-device
  calibration (P0.0 hook in `speech_service.dart`) is still pending. The
  ~2.4 s recovery measurement could shift ±50% with calibrated values.
  See `benchmark/README.md` for the calibration procedure.
- **GT alignment is 46% for JFK**; absolute lag/overshoot numbers should
  not be quoted in user-facing claims. Use them for V1/V2 *relative*
  comparison only. P1 should add fully-aligned synthetic clips (TTS +
  exact word_timings) where GT is 100%.
- **Layer 4 viewport / off-screen duration not yet implemented**. The
  user-visible-pain metric most aligned with subjective complaints is
  still on the P2 to-do list.
- **Single clip**. JFK alone isn't a benchmark; P1 adds LibriSpeech-clean
  and self-recorded clips for sample diversity.

## Files

- `benchmark/results/word_timings/jfk.json` — input
- `benchmark/results/events/jfk__{clean-passthrough,ios-on-device-15}.json` — simulator output
- `benchmark/results/traces/jfk__*__{v1,v2}.json` — replay output
- Reproduce: `python3 benchmark/run.py jfk`
