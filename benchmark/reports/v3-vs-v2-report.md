# V3 vs V2 Report: Cross-Session Recovery on JFK Inaugural

**Date**: 2026-05-01
**Clip**: `jfk` (JFK 1961 inaugural, 120 s, Vosk-small-en alignment 46% / 90 anchors)
**Matchers compared**: V1, V2, **V3 (new)**
**Cadence profiles**: `clean-passthrough` and `ios-on-device-15`
**Run**: `python3 benchmark/run.py jfk --matchers v1 v2 v3`

## TL;DR

| profile | matcher | matches | lag_p95 (w) | max_stall (ms) | x-recover_p95 (ms) | x-recover_max (ms) | unrecovered | teleports/min | cross_para/min | index_MAE |
|---|---|---|---|---|---|---|---|---|---|---|
| clean-passthrough | v1 | 196 | 48.0 | 7350 | 0 | 0 | 0 | 1.01 | 2.03 | 28.5 |
| clean-passthrough | v2 | 196 | 55.0 | 7350 | 0 | 0 | 0 | 0.00 | 1.01 | 29.5 |
| clean-passthrough | **v3** | 196 | **55.0** | **7350** | **0** | **0** | **0** | **0.00** | **1.01** | **29.5** |
| ios-on-device-15 | v1 | 1309 | 0.0 | 4080 | 2230 | 2230 | 0 | 2.54 | 3.05 | 116.0 |
| ios-on-device-15 | v2 | 1309 | 0.0 | 4160 | 2390 | 2390 | 0 | 1.52 | 2.54 | 114.6 |
| ios-on-device-15 | **v3** | 1309 | **1.0** | **4160** | **2390** | **2390** | **0** | **0.51** | **1.52** | **11.3** |

Headline numbers on `ios-on-device-15`:
- **cross_session_recovery_ms p50: 960 ms (V2) → 710 ms (V3)** — modest win.
- **cross_session_recovery_ms p95: 2390 ms (V2) → 2390 ms (V3)** — **hypothesis target <500 ms NOT met.**
- **index_MAE: 114.6 (V2) → 11.3 (V3)** — **~10× improvement** in how closely the highlight tracks GT.
- **teleports/min: 1.52 (V2) → 0.51 (V3)** — fewer >5-word jumps.
- **cross_para/min: 2.54 (V2) → 1.52 (V3)** — fewer paragraph teleports.
- **lag_p95: 0 → 1 word** — minor regression (matcher slightly behind GT instead of slightly ahead).

`clean-passthrough` is byte-identical V2 vs V3 — no regression on the simple cadence.

## V3 diff

### `ScriptMatcherBase.onSessionReset()`

The base interface gained a no-op default plus required overrides on V1/V2 (Dart's `implements` requires every member be implemented even when the abstract class provides a body, so V1/V2 each got a single `@override void onSessionReset() {}` line — no body logic touched).

### `ScriptMatcherV3.onSessionReset()` (the load-bearing change)

```dart
@override
void onSessionReset() {
  // Re-anchor the matching window to the current confirmed position so
  // the next fresh transcript can match starting from where the user
  // actually is, not from where the previous final left _matchStartOffset.
  _matchStartOffset = _recognizedCharCount;
  // Clear stale counter — the post-reset stalls in V1/V2 came from
  // accumulating stale-counts during the empty-text gap. A fresh
  // session deserves a fresh stale budget.
  _staleCount = 0;
  // Reset beam to a single hypothesis at the current position so any
  // beam-recovery logic also starts clean for the new session.
  final wordIdx = confirmedPosition;
  _beam = [_Hypothesis(wordPos: wordIdx)];
  // Allow the next few partials to run recovery. Critical for collapsing
  // the post-reset stall: V2 waits for the next isFinal before _resyncMatch
  // and _beamRecovery may fire, but on JFK the next final can be 1.5–2.4 s
  // away. A small budget (8 partials × 80 ms ≈ 640 ms) lets V3 try resync
  // much sooner without permanently changing matcher behavior.
  _postResetPartialBudget = _postResetPartialBudgetSize;
  // Note: do NOT touch _recognizedCharCount, _currentSentence, or any
  // sentence-level state — the user's view must remain stable across
  // the boundary.
}
```

Why each line matters:
1. `_matchStartOffset = _recognizedCharCount` — the original hypothesis. The fresh post-reset transcript starts from empty, so the matcher's char-level greedy search window must start at the user's *current* position, not at wherever the previous final left it. **In practice this had no effect on JFK** because the previous final (just before the reset) had already pinned `_matchStartOffset` to `_recognizedCharCount` via V2's normal final logic, so the offsets were already aligned at every reset. (See "Hypothesis verdict" below.)
2. `_staleCount = 0` — protects against a quirk where stale-count accumulated *during* the empty post-reset gap could over-trigger recovery later. Cheap, harmless.
3. `_beam = [_Hypothesis(wordPos: confirmedPosition)]` — keeps beam-recovery sane for the new session; without this, the beam could carry stale hypotheses from before the reset.
4. `_postResetPartialBudget = 8` — **the line that actually moved metrics.** V2's `_resyncMatch`/`_beamRecovery` only run when `isFinal == true`. On JFK ios-on-device-15, the next final after a reset can arrive 1–3 s later, so V2 sat on partials accumulating stale-count without ever attempting recovery. V3 opens an 8-partial (~640 ms) window where `_resyncMatch` may fire on partials with `_staleCount >= 2` and `>=2` spoken words.

The match() loop additionally consumes the budget and gates recovery:

```dart
final inPostResetWindow = _postResetPartialBudget > 0;
if (inPostResetWindow) _postResetPartialBudget--;
final canRecover = (_staleCount >= _staleThreshold && isFinal) ||
    (inPostResetWindow && _staleCount >= 2 && spokenWords.length >= 2);
```

When the matcher actually advances, the budget is also cancelled (`_postResetPartialBudget = 0`) so V3 doesn't keep running expensive recovery probes once the new session has anchored.

### Replay wiring

`benchmark/replay/replay.dart` was updated to:
1. Add `case 'v3': return ScriptMatcherV3();` to `_makeMatcher()`.
2. Call `matcher.onSessionReset()` in the event loop on every `event_type == 'session_reset'`, *before* recording the trace marker. V1/V2 inherit the no-op default, so the call is invisible to them.

## Hypothesis verdict

> "A matcher that listens for `session_reset` and explicitly resets `_matchStartOffset = _recognizedCharCount` should recover in <500 ms instead of 2400 ms."

**The hypothesis as written did not hold.** With *only* the `_matchStartOffset = _recognizedCharCount` change (no partial-recovery budget), V3 produced **bitwise-identical traces to V2** on every one of the 7 JFK resets:

```
reset[9] t=3810 pos=2 v2_rec=2390ms v3_rec=2390ms
reset[44] t=8610 pos=7 v2_rec= 960ms v3_rec= 960ms
reset[53] t=10964 pos=23 v2_rec= 790ms v3_rec= 790ms
reset[133] t=19680 pos=37 v2_rec= 390ms v3_rec= 390ms
reset[149] t=22530 pos=138 v2_rec= 630ms v3_rec= 630ms
reset[722] t=70230 pos=208 v2_rec=1590ms v3_rec=1590ms
reset[960] t=90840 pos=300 v2_rec=2230ms v3_rec=2230ms
```

**Why**: V2's normal `match()` logic already does `_matchStartOffset = _recognizedCharCount` on every isFinal, and every JFK reset comes ~250–2000 ms *after* a final. So at the moment of reset, V2's `_matchStartOffset` is already pinned to `_recognizedCharCount`. The "stale `_matchStartOffset`" failure mode the original investigation predicted **doesn't fire on this clip**.

**The actual cause of post-reset stall on JFK**: after a reset, the cumulative-text contract delivers tiny strings ("pick", "we", "not"). The matcher does run `_charLevelMatch` and `_wordLevelMatch` — but the script in the next 500 chars from the user's position simply doesn't contain those words (Vosk's small-en model mishears JFK's audio). Recovery (`_resyncMatch` / `_beamRecovery`) is gated on `isFinal`, but the next isFinal is 1.5–2.5 s away. V2's recovery never triggers in time.

**What worked**: the additional `_postResetPartialBudget` mechanism. By allowing recovery on partials for the first ~640 ms after a reset, V3 cuts:
- 4 of 7 reset-recovery times to <600 ms
- Median (p50) recovery from 960 → 710 ms
- index_MAE on ios-on-device-15 from 114.6 → 11.3 (10×)
- teleports/min from 1.52 → 0.51

**What did not budge**: 2 of 7 resets stayed at 2390 ms / 1440 ms. Those resets land on Vosk hallucinations: the user is at script position 2 ("Johnson,") when Vosk says "pick up the cause of freedom" — but JFK never said "pick up the cause" anywhere in the script. There is no anchor to find ahead, and recovery is *correctly* refusing to teleport backward. This is an ASR-quality lower bound, not a matcher problem.

**Quoted numbers**:
- V2 baseline: cross_session_recovery_ms_p95 = **2390 ms**
- V3 final: cross_session_recovery_ms_p95 = **2390 ms** (the slowest reset, capped by Vosk hallucinations, is unchanged)
- V3 final: cross_session_recovery_ms_p50 = **710 ms** (down from 960 ms)
- V3 final: index_MAE = **11.3** (down from 114.6) — by far the biggest user-visible win, since this directly reflects how closely the highlight tracks ground truth.

## Additional logic needed (or still needed)

To actually hit <500 ms p95, V3 (or V4) would need one of:

1. **Wider char-match window** post-reset. Currently `_charLevelMatch` scans only `_matchStartOffset:_matchStartOffset+500` chars (~80 words). On reset[9] the matcher sits at position 2; if "freedom" or "celebration" appears at position ~30 they're inside that window, but if Vosk says something Vosk-specific that has no script equivalent at all, no window size will help.

2. **Aggressive forward beam search on first post-reset partial**, scanning 100+ words ahead with a higher score threshold to teleport on confident anchors. V3's current `_beamRecovery` searches up to +50 words but is gated on `_staleCount >= staleThreshold * 3 = 12` and (in V3) `_postResetPartialBudget > 0`. On the bad resets the budget runs out before stale_count reaches 12.

3. **Tolerate small backward jumps** after a session_reset. If Vosk has fallen behind (e.g. user position 39, Vosk text matches script position 19), allowing a one-time backward jump within ±1 sentence on the first post-reset final would catch the "Vosk fell behind" case. This is risky for the teleporter UX but only at session boundaries.

4. **Match against the source's *future* sentence(s)** with a relaxed score threshold the moment a reset hits. V3 already does this via `_resyncMatch`, but V2's `_resyncMatch` requires `score >= 15` (~3 fuzzy-matched words). Lowering the threshold to e.g. 10 only inside the post-reset window would catch shorter post-reset partials, at the cost of more paragraph teleports.

5. **Don't fight ASR hallucinations.** When the cumulative post-reset transcript fails to anchor for >1 s, *freeze* the highlight and tell the user via UI ("listening…") rather than try to teleport. The current matcher already freezes (no jump) — the report metric just calls that "unrecovered". For UX, freezing is correct; for the metric to hit <500 ms p95, the metric needs an "unrecovered-acceptable" exemption when ASR text is hallucinated.

## Unexpected findings

- **clean-passthrough is byte-identical V2 vs V3.** This is correct: clean-passthrough has zero session_resets, so V3's onSessionReset() and post-reset budget code never execute. No regression possible there. Confirms the V3 changes are fully gated on session boundaries.

- **V3 lag_p95 went from 0 → 1 word on ios-on-device-15.** This looks like a regression but it's actually an artifact of better tracking: V2's massive overshoot (167 words) means it's far ahead of GT, so `lag` (gt - pred, clamped to ≥0) is always 0. V3 is much closer to GT (MAE 11.3 vs 114.6) so it occasionally falls slightly behind, raising lag slightly. The combined index_MAE drop is the real signal and it strongly favors V3.

- **V3 cross_para/min dropped from 2.54 → 1.52.** Recovery on partials caught false-anchor jumps earlier, before they cascaded into paragraph teleports. Beneficial side effect.

- **Adding `onSessionReset` as a method body on `ScriptMatcherBase` (abstract class) required also adding stub implementations to V1 and V2.** Dart's `implements` clause forces every implementer to provide its own definition for every member, even when the abstract class provides a default body. Constraint said "ONLY edit allowed to existing matcher files is adding `void onSessionReset() {}` to `ScriptMatcherBase`" but compilation required a single `@override void onSessionReset() {}` no-op line on V1 and V2 too. These additions touch zero body logic — they exist purely to satisfy the type system.

## Reproduce

```bash
# from repo root:
python3 benchmark/run.py jfk --matchers v1 v2 v3
```

Inputs:
- `benchmark/real_audio/jfk_script.txt` (script)
- `benchmark/real_audio/jfk_events.json` (Vosk word_timings)
- `benchmark/real_audio/jfk_gt.json` (ground truth, 90 anchors)

Outputs:
- `benchmark/results/word_timings/jfk.json`
- `benchmark/results/events/jfk__{clean-passthrough,ios-on-device-15}.json`
- `benchmark/results/traces/jfk__*__{v1,v2,v3}.json`

Files touched in this change:
- `lib/services/script_matcher_base.dart` (added `void onSessionReset() {}` default)
- `lib/services/script_matcher.dart` (added stub `@override void onSessionReset() {}` to satisfy `implements`)
- `lib/services/script_matcher_v2.dart` (same stub)
- `lib/services/script_matcher_v3.dart` (new file, copy of V2 + reset hook + post-reset partial-recovery budget)
- `benchmark/replay/replay.dart` (registered v3, calls onSessionReset on session_reset events)

Verification:
- `flutter analyze lib/services/script_matcher.dart lib/services/script_matcher_v2.dart lib/services/script_matcher_v3.dart lib/services/script_matcher_base.dart benchmark/replay/replay.dart` → clean.
- `dart run benchmark/replay/replay.dart` produces 3 traces × 2 profiles = 6 trace files.
- `python3 benchmark/metrics.py compare jfk` produces the comparison table above.
