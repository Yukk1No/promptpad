# Ultrawork Integration Report — P0 Phase Completion

**Status**: ✅ Complete — all 3 ultrawork tracks shipped, cross-validated, integrated
**Date**: 2026-05-01

> This report consolidates 3 parallel ultrawork tracks dispatched after the
> P0.5 smoking-gun reproduction (`jfk-p0.5-report.md`):
>
> 1. **V3 matcher** — `v3-vs-v2-report.md`
> 2. **Layer 1 audio degradation** — `layer1-audio-degradation-report.md`
> 3. **TTS true baseline** — `tts-true-baseline-report.md`
>
> Plus inline integration work done during the wait period:
> - Layer 4 viewport metrics (`viewport_metrics.py`) — was P2 in spec v0.2,
>   advanced to P0 because no agent was building it and it consumed only
>   read-only inputs.
> - V3 cross-validation against TTS clip + all 8 audio augments — done
>   directly in this session because each agent had focused scope.

## TL;DR (4 headline findings)

1. **Matcher fundamentals are sound.** TTS 92%-aligned baseline drops
   `index_MAE` from 28.5–29.5 words on raw Vosk JFK → **2.26 words on TTS**.
   The previously alarming "30 word lag" was 100% Vosk ASR errors. P0.5 §5
   hypothesis confirmed. Layer 4 viewport: V2 ios on TTS = **0.0% off-screen**;
   V1 ios on TTS = 35% — V2's tail-trim mechanism's true value exposed.

2. **V3 hypothesis as written did NOT hold; the actual fix was different.**
   `_matchStartOffset = _recognizedCharCount` alone is bitwise-identical
   to V2 (V2 already pins it on every isFinal). The fix that DID work:
   open an 8-partial (~640 ms) post-reset budget where recovery may fire
   on partials. Result on noisy JFK ios profile: **index_MAE 114.6→11.3
   (10× tighter)**, teleports/min 1.52→0.51, cross_para/min 2.54→1.52.
   But the headline `cross_session_recovery_ms_p95` stayed at 2390 ms —
   the 2 worst resets are bounded by Vosk hallucinations recovery
   correctly refuses to teleport on.

3. **V3 is NOT a strict Pareto improvement** (cross-validation finding,
   not in the V3 agent's report). Across 8 audio augments × ios profile:
   V3 = V2 byte-identical on 6/8 (V3 stays dormant when stale doesn't
   accumulate aggressively), V3 wins big on `clean`, **V3 REGRESSES on
   `cafe-noise-snr-10`** (MAE 41.79→73.09, x-rec_p95 1910→2710 ms,
   max_stall 3563→4150 ms). The post-reset budget fires on partials
   under moderate noise and anchors to a wrong position faster than V2
   would have. V3 ships with a known fragility band at moderate WER.

4. **Audio degradation surprises** (Layer 1 sweep on V2 ios):
   - **pitch shifts are the worst attack** — pitch-up-3 produces 10640 ms
     max_stall (2.5× clean) and 4200 ms x-rec_p95 (1.75× clean).
   - **bandlimit (telephony 300-3400 Hz) is the BEST augment** — 73% GT
     alignment (vs 46% clean), 550 ms x-rec_p95 (vs 2390 ms). Vosk's
     telephony training stack benefits.
   - **Gaussian noise non-monotonic** — at 20 dB SNR, GT alignment
     *improves* to 61%; x-recover even drops below baseline at high noise
     because more session_resets fragment the audio into shorter recovery
     windows. **Vosk WER is not a reliable SNR proxy.**

## Cross-validation matrix (V2 vs V3, ios-on-device-15 profile)

| condition | V2 sess | V2 x-rec_p95 | V2 max_stall | V2 MAE | V3 x-rec_p95 | V3 max_stall | V3 MAE | verdict |
|---|---|---|---|---|---|---|---|---|
| clean (Vosk@JFK 46% align) | 7 | 2390 | 4160 | 114.6 | 2390 | 4160 | **11.3** | V3 strong win |
| cafe-noise-snr-20 | 9 | 2390 | 6720 | 2.16 | 2390 | 6720 | 2.16 | V3=V2 (dormant) |
| **cafe-noise-snr-10** | 10 | 1910 | 3563 | 41.79 | **2710** | **4150** | **73.09** | **V3 REGRESSION** |
| cafe-noise-snr-5 | 12 | 1110 | 3680 | 39.81 | 1110 | 3680 | 39.81 | V3=V2 (dormant) |
| reverb | 11 | 2970 | 4640 | 83.34 | 2970 | 4640 | 83.34 | V3=V2 (dormant) |
| bandlimit | 8 | 550 | 5120 | 2.30 | 550 | 5120 | 2.30 | V3=V2 (dormant) |
| pitch-up-3 | 8 | 4200 | 10640 | 47.40 | 4200 | 10640 | 47.40 | V3=V2 (dormant) |
| pitch-down-3 | 7 | 2550 | 6160 | 34.54 | 2550 | 6160 | 34.54 | V3=V2 (dormant) |
| **TTS 92%-align clean-pass** | 0 | — | 2490 | 2.26 | — | 2490 | 2.26 | V3=V2 (no resets) |
| **TTS 92%-align ios** | 1 | 589 | 2960 | 2.57 | 589 | 2960 | 2.57 | V3=V2 (1 reset, dormant) |

**Interpretation**: V3's post-reset partial-recovery budget activates only
when stale_count accumulates to ≥ 2 *during* the post-reset window. On
6/8 augments + TTS, this never happens (either partial text anchors fast
enough, or it never anchors at all and budget runs out). Only on `clean`
JFK Vosk does V3 hit its sweet spot (MAE 10×). On `cafe-noise-snr-10` V3
fires recovery on partials and anchors to a *wrong* position because the
moderate noise produces just enough Vosk-acceptable but script-incorrect
words to mislead the post-reset resync.

## Layer 4 viewport metrics (Tier-2 P0 deliverable, advanced from P2)

`benchmark/viewport_metrics.py` (~150 LOC, separate from metrics.py to
avoid coupling). Implements `compare <stem>` mode + 4 viewport_presets
(iphone-13-mini, iphone-15-pro, ipad-mini, pixel-6 with realistic
words_per_line approximation derived from script_display.dart layout).

Validation: on TTS 92%-align clip:

| trace | off-screen | episodes | TTRV p95 |
|---|---|---|---|
| tts_jfk clean V1 | 9.6% | 5 | 6390 ms |
| tts_jfk clean V2 | 9.6% | 5 | 6390 ms |
| tts_jfk clean V3 | 9.6% | 5 | 6390 ms |
| **tts_jfk ios V1** | **35.0%** | 3 | 22450 ms |
| **tts_jfk ios V2** | **0.0%** | 0 | — |
| **tts_jfk ios V3** | **0.0%** | 0 | — |

**Hidden V2 win revealed**: on ios cadence with high-quality GT, V1 spends
35% of session off-screen — V2's tail-trim mechanism cuts that to **0%**.
This isn't visible in word-level metrics (lag p95 differs by 3 vs 5 words)
but is huge in user perception. Layer 4 was the right metric to add.

**Caveat**: words_per_line is approximated from script_display.dart layout
to ±20%. Layer 4 numbers must only be quoted on `usable_for_layer4: true`
clips (alignment ≥ 80%; tts_jfk @ 92% qualifies, jfk Vosk @ 46% does not).
Original JFK Vosk Layer 4 numbers (80–93% off-screen) were almost entirely
sparse-GT noise, not real matcher failure. P2 should add a Flutter
widget-test layout oracle for absolute precision.

## Action items / next phase

### Immediate
- [ ] **Investigate V3's cafe-noise-snr-10 regression**: trace the actual
  reset events — does the post-reset budget fire on a partial that anchors
  to a wrong position? If yes, a higher score threshold inside the post-reset
  window (or a kill-switch when the next text is short) might fix it.
- [ ] **Reproduce on a self-recorded clip** to break single-clip overfit
  on JFK. The Layer 1 audio synthesis pipeline supports any WAV input.
- [ ] **Real-device cadence calibration** — `lib/services/speech_service.dart`
  already has the `_calibLog` hook. User must run on actual iOS device
  and pipe `adb logcat`/Xcode console through `cadence/calibrate.py`.
  Current ios profile parameters are still placeholder estimates.

### Spec v0.3
Apply the changes outlined in `.omc/plans/spec-v0.3-changes.md`. Key updates:
- §5 P0 → mark complete, P0+ also includes Layer 4 + V3 + TTS baseline
- §"matcher list" → add V3 with onSessionReset contract + post-reset budget
- §"oracle pool" → add tts_jfk @ 92%, demote fdr (already), JFK Vosk relegated to relative-comparison-only
- §9 risks → V3 fragility band at moderate WER (cafe-noise-snr-10 finding)
- §5 P1 → ✅ Layer 1 audio degradation done; remaining: faster-whisper-tiny, sweep.py
- §5 P2 → ✅ Layer 4 viewport advanced; remaining: Flutter widget layout oracle, plot.py, regression.py

### V4 candidates (from V3 report's 5 paths)
1. Wider char-match window post-reset (currently 500 chars; try 1500).
2. Lower `_resyncMatch` score threshold inside post-reset window (15 → 10).
3. Allow bounded backward jumps on first post-reset final (±1 sentence).
4. Aggressive forward beam (+100 words instead of +50).
5. UX-level "listening…" signal when ASR text fails to anchor for >1 s
   (the matcher already freezes; expose to UI).

**Plus a new V4 candidate from this integration**: gate V3's post-reset
budget by an estimated WER signal. If the previous session's text had
characteristic noise patterns (low confidence, short final, high partial
churn), suppress the budget so V3 falls back to V2 behavior. This would
fix the cafe-noise-snr-10 regression without losing the clean-case win.

## Reproduce all three tracks + integration

```bash
# 1. V3 vs V2 on JFK Vosk (P0.5 baseline + V3)
python3 benchmark/run.py jfk --matchers v1 v2 v3

# 2. Layer 1 audio sweep (V2 only, the agent's run)
python3 benchmark/run.py jfk \
    --augments clean cafe-noise-snr-20 cafe-noise-snr-10 cafe-noise-snr-5 \
                reverb bandlimit pitch-up-3 pitch-down-3 \
    --matchers v2

# 3. TTS true baseline (run via the agent's helper)
python3 benchmark/make_tts_baseline.py
python3 benchmark/run.py tts_jfk --matchers v1 v2 v3 --skip-vosk

# 4. V3 across audio augments (this integration's contribution)
for aug in clean cafe-noise-snr-20 cafe-noise-snr-10 cafe-noise-snr-5 \
           reverb bandlimit pitch-up-3 pitch-down-3; do
    dart run benchmark/replay/replay.dart \
        --script benchmark/real_audio/jfk_script.txt \
        --events benchmark/results/events/jfk__${aug}__ios-on-device-15.json \
        --matcher v3 \
        --out benchmark/results/traces/jfk__${aug}__ios-on-device-15__v3.json
done

# 5. Layer 4 viewport on TTS (the validated GT)
python3 benchmark/viewport_metrics.py compare tts_jfk
```

## Files added/changed during integration (this session, after agents)

| File | Purpose |
|---|---|
| `benchmark/viewport_metrics.py` | Layer 4 implementation (NEW) |
| `benchmark/results/traces/jfk__<augment>__ios-on-device-15__v3.json` × 8 | V3 cross-axis traces (NEW) |
| `benchmark/results/traces/tts_jfk__*__v3.json` × 2 | V3 on TTS (NEW) |
| `benchmark/README.md` | Updated layout, matchers, metrics tables |
| `benchmark/results/ultrawork-integration.md` | This report |
| `.omc/plans/spec-v0.3-changes.md` | v0.3 spec change outline (NEW) |

Untouched by integration session: 3 agent reports + their primary fixtures.
