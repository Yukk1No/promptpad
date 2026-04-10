# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
flutter run                    # Run on connected device/simulator
flutter build ios              # Build iOS release
flutter build apk              # Build Android APK
flutter analyze                # Run linter (flutter_lints)
flutter test                   # Run all tests
flutter test test/foo_test.dart # Run a single test file
```

No backend, no code generation steps, no environment variables required.

## Architecture

PromptPad is a speech-driven auto-following teleprompter. Users paste a script, speak naturally, and the app tracks their position in real time using speech recognition matched against the script text.

### Data Flow

Microphone -> `speech_to_text` plugin -> `SpeechService` (stream of `SpeechEvent`) -> `ScriptMatcher.match(spoken)` -> word/sentence index -> `ScriptDisplay` (highlight + auto-scroll)

### Key Components

**`lib/models/script.dart`** - Parses raw text into `Script` with `ScriptToken` (word-level: raw, normalized, Double Metaphone phonetic code, anchor flag) and `Sentence` (sentence-level with heading annotations). Handles markdown stripping. Contains `doubleMetaphone()` used by both matchers.

**`lib/services/speech_service.dart`** - Wraps `speech_to_text` with auto-restart on silence, epoch-based stale result filtering, and periodic health-check restarts (iOS kills sessions at ~60s).

**`lib/services/script_matcher_base.dart`** - Abstract interface (`ScriptMatcherBase`) for swappable matching algorithms.

**`lib/services/script_matcher.dart`** (V1) - Classic matcher: char-level + word-level greedy matching, tail-match re-anchoring (last 3-5 words in 15-word window), sentence-ahead resync after 3 stale results.

**`lib/services/script_matcher_v2.dart`** (V2) - Extends V1 with: stable prefix extraction (buffers 3 partial results to filter ASR churn), beam-based anchor recovery (searches distinctive words in +/-50 word window after 6 stale results), direct sentence mapping.

**`lib/screens/teleprompter_screen.dart`** - Orchestrator: initializes speech + matcher, subscribes to events, manages wakelock/brightness, runs health-check (30s) and stale-advance (8s timeout) timers. Selects V1 or V2 matcher based on `tracking_algorithm` setting.

**`lib/widgets/script_display.dart`** - Renders tokens as `Wrap` with per-word `GlobalKey` for scroll targeting. Auto-scrolls to keep current word at 1/3 screen height. Supports mirror mode.

### Matching Algorithm Design

Both matchers track position via internal char offset (`_recognizedCharCount`), converted to word index for display. Three matching layers run in order:

1. **Primary**: char-level and word-level greedy matching from current offset (capped at 500 chars)
2. **Tail-match**: last spoken words searched in forward window for drift correction
3. **Recovery**: sentence-ahead resync (stale >= 3), then beam anchor search (V2, stale >= 6)

Fuzzy matching cascade: exact match -> Double Metaphone -> prefix match -> substring -> edit distance.

### Persistence

All settings stored via `SharedPreferences` (no backend): speech locale, on-device flag, tracking algorithm, default font size, script history (last 5).

## Platform Constraints

- iOS `SFSpeechRecognizer` has a ~60-second session limit; `SpeechService.healthCheck()` force-restarts before timeout
- `speech_to_text` stops after silence pauses; `_onStatus('notListening')` auto-restarts with 150ms delay
- Char-level match scan capped at 500 chars to prevent O(n*m) slowdown
- Tail-match window is 15 words to reduce false positive jumps
