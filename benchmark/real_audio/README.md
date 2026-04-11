# Real-Audio Matcher Benchmark

Benchmarks `ScriptMatcher` (V1) and `ScriptMatcherV2` against a **real
public-domain recording** (JFK inaugural address, first 120 s) using
[Vosk](https://alphacephei.com/vosk/) — an offline streaming ASR whose
partial/final cadence mirrors iOS `SFSpeechRecognizer`.

This catches real-world forward-jumping bugs that the synthetic
benchmark in `benchmark/matcher_benchmark.dart` cannot reproduce.

## Files

| File | Purpose | Committed? |
|---|---|---|
| `run_vosk.py` | Runs Vosk streaming on `jfk.wav`, writes `jfk_events.json` | yes |
| `extract_script.py` | Parses wikisource wikitext → clean `jfk_script.txt` | yes |
| `jfk_script.txt` | Extracted 1355-word JFK inaugural address (public domain) | yes |
| `jfk_events.json` | 234 pre-recorded Vosk events (197 partials + 37 finals) | yes |
| `jfk.wav` / `jfk_full.mp3` | Audio (regenerated, not committed) | no |
| `model/` | Vosk English model ~40 MB (regenerated, not committed) | no |

The committed JSON + script are self-contained: the Dart benchmark runs
on them directly without needing Python, Vosk or audio files.

## Run the Dart benchmark (just the replay)

```bash
dart run benchmark/real_audio_benchmark.dart
```

Expected output after the V2 forward-jump fix (commit `aaf1eef`):

```
=== V1 Classic ===
  Forward jumps (>5 words):  4
  Max single-event jump:     102 words

=== V2 Advanced ===
  Forward jumps (>5 words):  0
  Max single-event jump:     0 words
```

## Regenerate events (full pipeline)

Only needed if you change the audio window, ASR cadence, or want a
different recording.

```bash
cd benchmark/real_audio

# 1. Python deps (one-time)
python3 -m pip install --user vosk imageio-ffmpeg

# 2. Vosk English model (one-time, ~40 MB)
curl -sL -o model.zip https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip
unzip -q model.zip && mv vosk-model-small-en-us-0.15 model && rm model.zip

# 3. JFK audio (one-time, 14 MB)
curl -sL -o jfk_full.mp3 https://archive.org/download/JFK_Inaugural_Address_19610120/JFK_Inaugural_Address_19610120.mp3

# 4. Trim to 120 s, resample to 16 kHz mono (Vosk's expected format)
FFMPEG=$(python3 -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
"$FFMPEG" -y -i jfk_full.mp3 -t 120 -ar 16000 -ac 1 -sample_fmt s16 jfk.wav

# 5. Run streaming ASR (~2 min on CPU, same as audio length)
python3 run_vosk.py

# 6. (Optional) re-extract the script from wikisource
curl -sL -A 'Mozilla/5.0' \
  'https://en.wikisource.org/wiki/John_F._Kennedy%27s_Inaugural_Address?action=raw' \
  -o jfk_raw.wiki
python3 extract_script.py
```

## Why a real recording?

The synthetic benchmark uses idealized partials (`"the quick" → "the
quick brown"`) which never match the tail volatility of a production
ASR. Vosk processing a real recording reproduces the exact class of
event that triggered the bug users reported as *"乱往后跳"* — a final
event whose (noisy) text coincidentally matches a distant source
fragment, causing the greedy matcher to teleport.

On this recording V1 exhibits a 102-word single-event forward jump at
event 233 (final `"get the plan by a"`). That's the bug, reproduced.
