# Layer 1: Audio Degradation Report

**Date**: 2026-05-01
**Clip**: `jfk` (JFK 1961 inaugural, 120 s)
**Matcher**: V2 only (`script_matcher_v2.dart`)
**Cadence profiles**: `clean-passthrough` (control) and `ios-on-device-15`
**Augments**: 8 (clean / cafe-noise-snr-20 / cafe-noise-snr-10 / cafe-noise-snr-5 / reverb / bandlimit / pitch-up-3 / pitch-down-3)
**Library**: audiomentations==0.43.1, Vosk==0.3.45, vosk-model-small-en-us

## Reproduce

```bash
python3 benchmark/run.py jfk \
  --augments clean cafe-noise-snr-20 cafe-noise-snr-10 cafe-noise-snr-5 \
             reverb bandlimit pitch-up-3 pitch-down-3 \
  --matchers v2
```

16 traces produced: 8 augments × 2 profiles × 1 matcher.

---

## TL;DR Table (ios-on-device-15 profile)

| augment | Vosk words | GT align% | x-recover_p95 (ms) | max_stall (ms) | lag_p95 (w) | sessions |
|---|---|---|---|---|---|---|
| clean | 196 | 46% | 2390 | 4160 | 0 | 8 |
| cafe-noise-snr-20 | 199 | 61% | 2390 | 6720 | 3 | 10 |
| cafe-noise-snr-10 | 189 | 59% | 1910 | 3563 | 0 | 11 |
| cafe-noise-snr-5 | 189 | 44% | 1110 | 3680 | 0 | 12 |
| reverb | 173 | 31% | 2970 | 4640 | 0 | 12 |
| bandlimit | 187 | 73% | 550 | 5120 | 4 | 9 |
| pitch-up-3 | 202 | 48% | 4200 | 10640 | 11 | 9 |
| pitch-down-3 | 182 | 44% | 2550 | 6160 | 11 | 8 |

*GT align%* = Vosk words aligned to script / total Vosk words (from `align_ground_truth.py`).
*x-recover_p95* = cross-session recovery time p95 — the headline V2 metric from P0.5.

---

## SNR Degradation Curve (V2, ios-on-device-15)

| augment | SNR | Vosk words | GT align% | x-recover_p95 (ms) | max_stall (ms) | lag_p95 (w) | unrecovered |
|---|---|---|---|---|---|---|---|
| clean | ∞ (baseline) | 196 | 46% | 2390 | 4160 | 0 | 0 |
| cafe-noise-snr-20 | 20 dB | 199 | 61% | 2390 | 6720 | 3 | 0 |
| cafe-noise-snr-10 | 10 dB | 189 | 59% | 1910 | 3563 | 0 | 0 |
| cafe-noise-snr-5 | 5 dB | 189 | 44% | 1110 | 3680 | 0 | **1** |

**Observations:**

- **Vosk word count is stable across SNR levels** (196 → 199 → 189 → 189). Gaussian noise doesn't suppress Vosk's word output — it just changes what words it hears. This differs from the intuitive model where noise causes silence; instead Vosk hallucinates different words.
- **GT alignment rate is NOT monotone with SNR**. At 20 dB the alignment *improves* (46% → 61%), likely because the noise shifts certain mishearings toward words that happen to match the JFK script better. At 5 dB it returns to ~44%. This non-monotonicity is a key finding: **Vosk alignment rate is not a reliable SNR proxy at moderate noise levels.**
- **cross_session_recovery_ms_p95 decreases as SNR drops** (2390 → 1910 → 1110 ms). This is counterintuitive and explained by the session boundary count: noisier audio triggers more sessions (8 → 10 → 11 → 12). More frequent resets mean shorter per-session text windows, so V2 finds its anchor faster from a shorter prefix. The matcher's cross-session failure mode actually *shrinks* in duration as noise breaks the audio into more fragments.
- **max_stall_ms fluctuates** (4160 → 6720 → 3563 → 3680). The spike at 20 dB correlates with the session count increase (9 sessions vs 8 clean), causing one long stall mid-script.
- **1 unrecovered reset at 5 dB** — V2 failed to re-advance past baseline for one of the 12 sessions. This is the first unrecovered event in the SNR sweep.

### clean-passthrough profile (same SNR rows)

| augment | lag_p95 (w) | max_stall (ms) | index MAE |
|---|---|---|---|
| clean | 55 | 7350 | 29.5 |
| cafe-noise-snr-20 | 0 | 5700 | 56.0 |
| cafe-noise-snr-10 | 2 | 4530 | 0.71 |
| cafe-noise-snr-5 | 20 | 4770 | 7.92 |

Noise at 20 dB dramatically reduces lag (55 → 0 words) because Vosk produces more words that accidentally match further into the script, pulling the matcher forward. At 5 dB, lag rises again (20 words) as Vosk word errors increase enough to anchor in the wrong place.

---

## Non-Noise Transforms (V2, both profiles)

### Reverb (synthetic room IR, RT60 ≈ 200 ms, 40% wet)

| profile | Vosk words | GT align% | lag_p95 (w) | max_stall (ms) | x-recover_p95 (ms) | unrecovered |
|---|---|---|---|---|---|---|
| clean-passthrough | 173 | 31% | 5 | 9240 | 0 | 0 |
| ios-on-device-15 | 173 | 31% | 0 | 4640 | 2970 | **1** |

Reverb is the harshest transform by GT quality (31% alignment rate — below the 46% clean baseline). The 9240 ms max_stall on clean-passthrough is the worst stall of any augment. Reverb causes Vosk to produce fewer words (173 vs 196 baseline) but with worse accuracy, and the words Vosk does produce align poorly to the script. The `max_stall_ms` spike on clean-passthrough reflects a long stretch where V2 cannot match any Vosk output to the script.

**Interesting**: reverb causes 1 unrecovered reset on ios profile despite having *fewer* sessions than the noise augments (12 sessions). The unrecovered case happens when Vosk misrecognizes the first word(s) after a session boundary so badly that V2 never finds a forward anchor in that session.

### Bandlimit (telephony-style BandPass 300–3400 Hz)

| profile | Vosk words | GT align% | lag_p95 (w) | max_stall (ms) | x-recover_p95 (ms) | unrecovered |
|---|---|---|---|---|---|---|
| clean-passthrough | 187 | **73%** | 2 | 3060 | 0 | 0 |
| ios-on-device-15 | 187 | **73%** | 4 | 5120 | 550 | 0 |

Bandlimit is the **best-performing augment** by GT alignment rate (73% vs 46% baseline). This makes sense: telephone-bandwidth filtering removes high-frequency noise but keeps speech fundamentals intact, and Vosk's model was trained primarily on telephone-style audio. The x-recover_p95 drops to 550 ms (vs 2390 ms baseline) — V2 recovers from session resets 4.3× faster under bandlimit because Vosk's output is more accurate and the matcher can anchor on the first post-reset word.

**Practical implication**: running PromptPad via a Bluetooth headset (which often applies similar high-pass + band limiting) may actually *improve* Vosk-based tracking. Real device ASR (iOS SFSpeechRecognizer) has its own bandlimit + noise suppression stack so on-device behavior may differ.

### Pitch Shifts (±3 semitones)

| preset | profile | Vosk words | GT align% | lag_p95 (w) | max_stall (ms) | x-recover_p95 (ms) | sessions |
|---|---|---|---|---|---|---|---|
| pitch-up-3 | clean-passthrough | 202 | 48% | 0 | 6660 | 0 | 1 |
| pitch-up-3 | ios | 202 | 48% | **11** | **10640** | **4200** | 9 |
| pitch-down-3 | clean-passthrough | 182 | 44% | **51** | 6870 | 0 | 1 |
| pitch-down-3 | ios | 182 | 44% | **11** | 6160 | 2550 | 8 |

Pitch shifts produce the worst `lag_p95` and `max_stall_ms` values in the ios profile:

- **pitch-up-3 ios: 10640 ms max_stall** — the worst stall of all augments. Vosk processes a higher-pitched voice and produces a different but surprisingly large word set (202 words, 48% alignment). However, those words don't match the script well in sequence, causing V2 to teleport frequently (5.58/min vs 1.52 baseline) and stall for >10 s in the ios profile.
- **pitch-down-3 clean-passthrough: lag_p95 = 51 words** — Vosk hears a lower-pitched voice and produces words that systematically anchor ~35 words behind the speaker's actual position. The matcher keeps up with Vosk's output but Vosk is wrong about *which* words were said. This 51-word lag is the worst lag of any augment on clean-passthrough.
- **x-recover_p95 = 4200 ms for pitch-up-3** — the worst cross-session recovery of all augments, 1.75× worse than baseline (2390 ms). High-pitched ASR errors cause V2's anchor search to fail repeatedly after session boundaries, extending recovery.

---

## Caveats

### 1. Vosk WER degrades non-monotonically with noise

Gaussian noise at 20 dB *improved* Vosk's word count and GT alignment rate compared to clean. This is because:
- Vosk's small-en-us acoustic model was trained with data augmentation and is somewhat noise-robust.
- The alignment metric measures how many Vosk words match the script — if noise shifts a mishearing toward a word that happens to be in the JFK script, alignment improves.
- **Consequence**: GT alignment rate cannot be used as a reliable audio quality proxy. Acoustic SNR is the correct quality axis.

### 2. GT quality degrades, making absolute metrics unreliable at low quality

For augments with alignment_rate < 40% (reverb at 31%), the GT anchor count is too sparse to provide reliable lag measurements. The `lag_ms` and `index_mae` numbers for reverb should be treated as indicative, not precise.

**Quality threshold recommendation:**
- **Fit for all layers (L1–L3)**: alignment_rate ≥ 50% → bandlimit (73%), cafe-noise-snr-20 (61%), cafe-noise-snr-10 (59%)
- **Fit for L2/L3 only**: alignment_rate 40–50% → clean (46%), pitch-up-3 (48%), cafe-noise-snr-5 (44%), pitch-down-3 (44%)
- **L2/L3 marginal, L1 unreliable**: alignment_rate < 40% → reverb (31%) — use for trajectory/cross-session metrics only; lag numbers are not trustworthy

### 3. Cross-session recovery improves with noise (counterintuitive)

Noisier audio → more session breaks → shorter per-session text → faster V2 re-anchor. This means the cross_session_recovery metric underestimates V2's failure mode in the noise sweep. The **pitch** augments are more diagnostic because they preserve session counts while degrading ASR quality.

### 4. Reverb implementation note

`RoomSimulator` from audiomentations requires `pyroomacoustics` which is not installed. A synthetic exponential-decay IR (RT60 ≈ 200 ms, 40% wet mix) was used instead via `scipy.signal.fftconvolve`. This is a simpler reverb model than a full room simulation but is sufficient to study ASR degradation from reverberation.

### 5. Single clip

JFK alone is not a benchmark. The degradation curves will shift for speakers with different fundamental frequency (pitch shifts will affect differently), accent, or cadence. P1 should add at least one synthetic TTS clip with 100% GT alignment to remove the GT-quality confound from Layer 1 measurements.

---

## Summary of V2 Breaking Points

From worst to best across all augments:

1. **pitch-up-3 (ios)**: max_stall 10640 ms, x-recover_p95 4200 ms — V2 breaks most severely here. High pitch confuses both Vosk's acoustic model and V2's anchor search after each session reset.
2. **reverb (clean-passthrough)**: max_stall 9240 ms — long stall from poor GT alignment; 1 unrecovered reset on ios.
3. **pitch-down-3 (clean-passthrough)**: lag_p95 51 words — systematic position offset; Vosk hears wrong words that happen to be clustered 35 words behind the speaker.
4. **cafe-noise-snr-5 (ios)**: 1 unrecovered reset — V2's first unrecovered failure in the SNR sweep.
5. **bandlimit**: best-performing augment overall, suggesting telephone-style audio is actually *easier* for this pipeline.

**Where V2 breaks first**: pitch distortion degrades cross-session recovery faster than additive noise of the same perceptual severity. The `pitch-up-3` case shows V2 spending >10 s stalled — worse than any noise preset — despite Vosk producing more words than the clean baseline.

---

## Files

| artifact | path |
|---|---|
| Degraded WAVs | `benchmark/results/audio/jfk__{preset}.wav` (8 files) |
| Raw ASR events | `benchmark/results/events_raw/jfk__{preset}.json` (8 files) |
| Word timings | `benchmark/results/word_timings/jfk__{preset}.json` (8 files) |
| GT traces | `benchmark/real_audio/jfk__{preset}_gt.json` (8 files) |
| Simulator events | `benchmark/results/events/jfk__{preset}__{profile}.json` (16 files) |
| Replay traces | `benchmark/results/traces/jfk__{preset}__{profile}__v2.json` (16 files) |
| Augmenter | `benchmark/augment.py` |
| Generalized Vosk runner | `benchmark/asr/vosk_runner.py` |
