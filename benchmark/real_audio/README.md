# Real-Audio Matcher Benchmark

Benchmarks `ScriptMatcher` (V1) and `ScriptMatcherV2` against **real
public-domain recordings** processed by [Vosk](https://alphacephei.com/vosk/) —
an offline streaming ASR whose partial/final cadence mirrors iOS
`SFSpeechRecognizer`.

**Why real audio**: synthetic benchmarks (see `benchmark/matcher_benchmark.dart`)
can't reproduce real-world tail volatility or the user-perceived "乱往后跳"
bug. Real recordings of known scripts expose matcher failures you cannot
trigger from crafted inputs.

## What it measures

For each event the matcher sees, the benchmark compares its reported
word index to the **time-aligned ground truth** position the speaker is
actually on (derived from Vosk's word-level timings and aligned to the
real script via `difflib.SequenceMatcher`).

Reported metrics per matcher × audio × transform × stale-advance on/off:
| metric | meaning |
|---|---|
| Final / max position | end-state and peak reached |
| Mean / max \|error\| | average and worst deviation from ground truth |
| Mean overshoot / max | how far the matcher ran AHEAD of the user (the bug users report) |
| Mean lag / max | how far the matcher fell BEHIND (stuck state) |
| Events on-target ±2 | how often the matcher was correct within 2 words |
| Forward jumps (>5 words) | single-event forward teleports |
| Backward jumps | regressions |
| Stale-advance firings | times the screen-level fallback fired |
| Max stall (events/ms) | longest interval with zero progress |
| Stall bursts ≥2 s | number of stall episodes |

## Transforms per audio

| Mode | Purpose |
|---|---|
| `baseline (no/with stale-advance)` | A/B on the screen-level auto-advance |
| `pause+12s (no/with stale-advance)` | Inject a 12-s silent gap mid-stream — proves stale-advance is the real cause of "乱往后跳" |
| `tail churn` | Rewrite the last word of every partial to a common word |
| `partial dropout 40%` | Drop 40% of partials — poor ASR signal |

## Committed audio clips

| Stem | Source | Length | Role |
|---|---|---|---|
| `jfk` | JFK inaugural address (archive.org, PD) | 120 s | deliberate, slow (~1.5 wps) |
| `fdr` | FDR "Day of Infamy" (archive.org, PD) | 120 s | urgent, higher WER |

## Files

| File | Purpose | Committed? |
|---|---|---|
| `run_vosk.py <stem>` | Vosk streaming → `{stem}_events.json` | yes |
| `extract_script.py <stem>` | wikitext → clean `{stem}_script.txt` | yes |
| `align_ground_truth.py <stems…>` | Vosk word timings → `{stem}_gt.json` (time→script_idx) | yes |
| `{stem}_script.txt` | speech transcript (public domain) | yes |
| `{stem}_events.json` | Vosk events (partials + finals + word timings) | yes |
| `{stem}_gt.json` | ground-truth anchors + dense interpolated samples | yes |
| `{stem}.wav` / `.mp3` | audio (regenerated, not committed) | no |
| `{stem}_raw.wiki` | wikisource download (regenerated) | no |
| `model/` | Vosk English model ~40 MB (regenerated) | no |

The committed JSON+script+gt files are self-contained: the Dart benchmark
runs on them directly without Python, Vosk, or audio.

## Run the Dart benchmark

```bash
dart run benchmark/real_audio_benchmark.dart
```

Look for the `mode: pause+12s (with stale-advance)` block on JFK. If
`Forward jumps (>5 words)` for V2 is non-zero, the screen-level
stale-advance is teleporting the user. Our current fix
(`teleprompter_screen.dart` → `_reviveStaleAsr`) raises the threshold
to 15 s and removes the forced sentence jump, so in production V2
stays smooth on natural pauses.

## Regenerate a new clip

```bash
cd benchmark/real_audio

# 1. Install deps once
python3 -m pip install --user vosk imageio-ffmpeg

# 2. Vosk English model (once, ~40 MB)
curl -sL -o model.zip https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip
unzip -q model.zip && mv vosk-model-small-en-us-0.15 model && rm model.zip

# 3. Audio: grab MP3 from archive.org
curl -sL -o NEW_full.mp3 "https://archive.org/download/<item>/<file>.mp3"

# 4. Trim + resample to 16 kHz mono
FFMPEG=$(python3 -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
"$FFMPEG" -y -i NEW_full.mp3 -t 120 -ar 16000 -ac 1 -sample_fmt s16 NEW.wav

# 5. Transcript from wikisource
curl -sL -A 'Mozilla/5.0' '<wikisource URL>?action=raw' -o NEW_raw.wiki
# add an entry to MARKERS in extract_script.py then:
python3 extract_script.py NEW

# 6. Streaming ASR (runs at ~1× real time)
python3 run_vosk.py NEW

# 7. Ground-truth alignment (add per-stem cap in align_ground_truth.py if needed)
python3 align_ground_truth.py NEW

# 8. Add the stem to `clips` in real_audio_benchmark.dart and rerun.
```

## Why old recordings have poor alignment

On pre-1950 recordings (JFK 1961, FDR 1941) the Vosk small English model
produces significant errors — compare "Chief Justice Earl Warren" to
Vosk's "pick up that that you've got it", or "Mr. Vice President" to
"gotta buy a gun ban captain america". The aligner recovers ~46 % on JFK
and ~18 % on FDR. The *absolute* position numbers degrade with the
alignment rate, but the **forward-jump counts and the A/B split** against
`stale-advance on/off` are robust regardless — they depend on matcher
behavior, not on alignment quality.
