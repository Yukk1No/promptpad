# Changelog

## v1.0.0

### Tracking Algorithm
- Dual tracking algorithm: Classic (V1) and Advanced with beam search (V2)
- Character-level + word-level greedy matching (inspired by Textream)
- Tail-match re-anchoring for continuous drift recovery
- Stale detection + sentence-ahead resync + timeout auto-advance
- Phonetic matching via Double Metaphone for accent tolerance
- V2: stable prefix extraction, beam-based anchor recovery

### Speech Recognition
- Platform-agnostic ASR via speech_to_text (iOS SFSpeechRecognizer / Android Google Speech)
- 10 supported languages
- On-device recognition option for offline use
- Auto-restart on silence, epoch-based stale filtering
- Health-check timer to work around iOS ~60s session limit

### UI & UX
- Word-level highlighting with auto-scroll (current word at 1/3 screen height)
- Sentence skip (left/right arrows)
- Adjustable font size (28–56pt)
- Mirror mode for teleprompter glass
- Adaptive controls layout (portrait / landscape)
- Markdown script support with section headings
- Script history (last 5 scripts)
- Screen wakelock + max brightness during playback
- Settings screen with algorithm picker, locale, font size
- About page with version and GitHub link
