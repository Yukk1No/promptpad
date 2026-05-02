import '../models/script.dart';

/// Common interface for script matchers (v1 classic and v2 advanced).
abstract class ScriptMatcherBase {
  void loadScript(Script script);
  void reset();
  void jumpTo(int wordIndex);
  void jumpToSentence(int sentenceIndex);
  int match(String spoken, {bool isFinal = false});
  int get confirmedPosition;
  int get currentSentence;
  int get totalSentences;

  /// Called by the host (replay harness or production code) when the
  /// underlying ASR session resets (e.g. iOS silence-restart, 60-s health
  /// restart). Default is a no-op so V1/V2 are unaffected. V3+ overrides
  /// this to re-anchor `_matchStartOffset` so the next fresh transcript
  /// can match from the matcher's *current* position rather than the
  /// previous session's final char offset.
  void onSessionReset() {}
}
