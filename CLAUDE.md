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

**`lib/services/script_matcher_v3.dart`** (V3 / V3.1) - Extends V2 with `onSessionReset()` hook + 8-partial post-reset partial-recovery budget, eliminating the cumulative-text-contract failure mode that caused V2's 1-2.4 s post-silence-restart stall. 10× MAE win on noisy real-Vosk JFK ios; byte-identical to V2 on clean inputs (TTS, no resets). V3.1 adds `setNoisyEnvironmentMode(bool)` runtime toggle: on ⇒ V2 fallback (eliminates the cafe-noise-snr-10 regression at the cost of the clean-case win). Default off ⇒ full V3 behaviour. Superseded by V4 for production use; toggle kept for ablation. See `benchmark/reports/v3-vs-v2-report.md` and `v3.1-noisy-toggle-report.md`.

**`lib/services/script_matcher_v4.dart`** (V4) - Extends V3 with automatic per-event confidence gate. Reads `mean_confidence` from each transcript event (added to events.json schema in this version) via `setNextEventConfidence`. Inside the post-reset budget window, suppresses `_resyncMatch` on partials with confidence < 0.6, falling back to V2's wait-for-isFinal path on noisy partials only. Solves the V3 cafe-noise-snr-10 regression (MAE 73.09 → 41.79) **without losing the clean-case win** (still 11.27 on JFK Vosk ios). 11 of 12 sweep conditions byte-identical to V3; the 12th is exactly the regression V4 fixes. No runtime toggle needed — gate is automatic. See `benchmark/reports/v4-vs-v3-report.md`.

**`lib/screens/teleprompter_screen.dart`** - Orchestrator: initializes speech + matcher, subscribes to events, manages wakelock/brightness, runs health-check (30s) and stale-advance (8s timeout) timers. Selects V1, V2, V3, or V4 matcher based on `tracking_algorithm` setting.

**`lib/widgets/script_display.dart`** - Renders tokens as `Wrap` with per-word `GlobalKey` for scroll targeting. Auto-scrolls to keep current word at 1/3 screen height. Supports mirror mode.

### Matching Algorithm Design

Both matchers track position via internal char offset (`_recognizedCharCount`), converted to word index for display. Three matching layers run in order:

1. **Primary**: char-level and word-level greedy matching from current offset (capped at 500 chars)
2. **Tail-match**: last spoken words searched in forward window for drift correction
3. **Recovery**: sentence-ahead resync (stale >= 3), then beam anchor search (V2, stale >= 6)

Fuzzy matching cascade: exact match -> Double Metaphone -> prefix match -> substring -> edit distance.

### Persistence

All settings stored via `SharedPreferences` (no backend): speech locale, on-device flag, tracking algorithm, default font size, script history (last 5).

## Algorithm Version Policy

Matcher versions track **algorithmic breakthroughs**, not code churn. Don't bump MAJOR for refactors, parameter tweaks, or new configuration options. Otherwise the version number stops carrying meaning ("V100 in 6 months").

| Level | Bump when | Examples in this repo |
|---|---|---|
| **MAJOR** (V1 → V2 → V3 → V4) | A new failure mode is solved, a core mechanism is added or replaced, or measured behavior changes by ≥1 order of magnitude on a calibrated benchmark. | V2 added stable-prefix + beam recovery; V3 added cross-session-reset awareness + post-reset partial budget (10× MAE win on noisy real audio). |
| **MINOR** (V3 → V3.1 → V3.2) | Same algorithm gains a new configurable mode, runtime toggle, parameter, or interface extension. Default behavior must stay byte-identical to the previous MINOR. | V3.1 added `setNoisyEnvironmentMode(bool)` runtime fallback to V2 — same V3 algorithm, optional knob. |
| **PATCH** (no version bump) | Bug fixes, micro-tunings, performance work, refactors, comment changes. | Threshold tweaks, dead-code removal, doc edits. |

Operational rules:
1. **One MAJOR per file.** `script_matcher_v3.dart` holds V3 and any V3.x. Don't create `script_matcher_v3_1.dart`.
2. **A MAJOR ships with a benchmark report** under `benchmark/reports/v{N}-vs-v{N-1}-report.md` quoting concrete numbers vs the previous MAJOR on the same fixtures.
3. **A MINOR ships with a short note** in the corresponding MAJOR's docstring + report explaining what the new toggle does and what it does NOT change. Default-off MINORs need no separate report unless they introduce a new failure surface.
4. **Don't ship a MAJOR for a regression fix that doesn't introduce new mechanism.** If you can't explain the improvement in one sentence ("V4: gates partial recovery on per-word ASR confidence"), it's probably a MINOR.
5. **Negative results count.** A V4 attempt that fails to satisfy its acceptance criteria stays unmerged or lands as a MINOR with the failure documented. The V4 namespace stays free for the next real breakthrough.
6. The matcher version exposed in `tracking_algorithm` SharedPreferences setting and `replay.dart --matcher` only takes MAJOR ids (`v1`, `v2`, `v3`, `v3-noisy` alias for V3 with the noisy flag set). MINORs are accessed via configuration on the MAJOR object, not as separate matcher selections.

## Platform Constraints

- iOS `SFSpeechRecognizer` has a ~60-second session limit; `SpeechService.healthCheck()` force-restarts before timeout
- `speech_to_text` stops after silence pauses; `_onStatus('notListening')` auto-restarts with 150ms delay
- Char-level match scan capped at 500 chars to prevent O(n*m) slowdown
- Tail-match window is 15 words to reduce false positive jumps
