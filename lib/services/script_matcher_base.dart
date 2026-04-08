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
}
