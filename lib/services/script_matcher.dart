import 'dart:math';
import '../models/script.dart';

/// Sentence-level speech matcher built on textream's dual-strategy approach.
///
/// Matches spoken text against the current sentence's text.
/// When >50% of the sentence is matched, advances to the next sentence.
/// Also exposes word-level position for backward compatibility.
class ScriptMatcher {
  Script? _script;

  /// The collapsed source text (all words joined by single space).
  String _sourceText = '';

  /// Lowercased, letters/numbers/whitespace only.
  String _normalizedSource = '';

  /// Source words split from the remaining suffix.
  List<String> _sourceWords = [];

  /// Character offset where matching begins (advances on each session/resume).
  int _matchStartOffset = 0;

  /// Total recognized characters so far (monotonically increasing).
  int _recognizedCharCount = 0;

  /// Current sentence index.
  int _currentSentence = 0;

  int get currentSentence => _currentSentence;
  int get totalSentences => _script?.sentences.length ?? 0;

  int get confirmedPosition => _charCountToWordIndex(_recognizedCharCount);

  void loadScript(Script script) {
    _script = script;
    _sourceText = script.tokens.map((t) => t.raw).join(' ');
    _normalizedSource = _normalize(_sourceText);
    _sourceWords = _sourceText.split(RegExp(r'\s+'));
    _matchStartOffset = 0;
    _recognizedCharCount = 0;
    _currentSentence = 0;
  }

  void reset() {
    _matchStartOffset = 0;
    _recognizedCharCount = 0;
    _currentSentence = 0;
  }

  void jumpTo(int wordIndex) {
    final script = _script;
    if (script == null) return;
    final clamped = wordIndex.clamp(0, script.tokens.length - 1);
    // Convert word index to char offset
    var charPos = 0;
    for (var i = 0; i < clamped; i++) {
      charPos += script.tokens[i].raw.length + 1;
    }
    _recognizedCharCount = charPos;
    _matchStartOffset = charPos;
  }

  /// Jump to a specific sentence index.
  void jumpToSentence(int sentenceIndex) {
    final script = _script;
    if (script == null || script.sentences.isEmpty) return;
    _currentSentence = sentenceIndex.clamp(0, script.sentences.length - 1);

    // Also update char-level tracking to match the sentence boundary
    final sentence = script.sentences[_currentSentence];
    // Find the char offset of this sentence's first word in the source text
    final sentenceNormalized = _normalize(sentence.rawText);
    if (sentenceNormalized.isNotEmpty) {
      // Search for the sentence start in the normalized source
      // We find the Nth occurrence by tracking sentences before this one
      var searchFrom = 0;
      for (var i = 0; i < _currentSentence; i++) {
        final prevNorm = _normalize(script.sentences[i].rawText);
        if (prevNorm.isNotEmpty) {
          final idx = _normalizedSource.indexOf(prevNorm, searchFrom);
          if (idx >= 0) {
            searchFrom = idx + prevNorm.length;
          }
        }
      }
      final idx = _normalizedSource.indexOf(sentenceNormalized, searchFrom);
      if (idx >= 0) {
        _recognizedCharCount = idx;
        _matchStartOffset = idx;
      }
    }
  }

  /// Process a spoken transcript. Returns the current word index.
  ///
  /// [isFinal] indicates the ASR session ended (silence detected).
  /// Partial results re-match from the same offset (cumulative text).
  /// Final results advance the offset for the next ASR session.
  int match(String spoken, {bool isFinal = false}) {
    if (_script == null || _sourceText.isEmpty) return 0;

    final charResult = _charLevelMatch(spoken);
    final wordResult = _wordLevelMatch(spoken);
    final best = max(charResult, wordResult);
    final newCount = _matchStartOffset + best;

    if (newCount > _recognizedCharCount) {
      _recognizedCharCount = min(newCount, _sourceText.length);
    }

    // Only advance matchStartOffset when ASR session ends (final result).
    // Partials are cumulative — they re-match from the same start.
    if (isFinal) {
      _matchStartOffset = _recognizedCharCount;
    }

    // Update sentence index based on match progress
    _updateSentenceFromCharCount();

    return confirmedPosition;
  }

  /// Update the current sentence index based on how far we've matched.
  void _updateSentenceFromCharCount() {
    final script = _script;
    if (script == null || script.sentences.isEmpty) return;

    // Check if we've matched enough of the current sentence to advance
    final currentSentenceObj = script.sentences[_currentSentence];
    final sentenceText = currentSentenceObj.rawText;
    if (sentenceText.isEmpty) return;

    final sentenceNormalized = _normalize(sentenceText);
    if (sentenceNormalized.isEmpty) return;

    // Find where this sentence starts in the normalized source
    var searchFrom = 0;
    for (var i = 0; i < _currentSentence; i++) {
      final prevNorm = _normalize(script.sentences[i].rawText);
      if (prevNorm.isNotEmpty) {
        final idx = _normalizedSource.indexOf(prevNorm, searchFrom);
        if (idx >= 0) {
          searchFrom = idx + prevNorm.length;
        }
      }
    }

    final sentenceStart = _normalizedSource.indexOf(sentenceNormalized, searchFrom);
    if (sentenceStart < 0) return;

    final sentenceEnd = sentenceStart + sentenceNormalized.length;
    final normalizedRecognized = _recognizedCharCount.clamp(0, _normalizedSource.length);

    // Calculate how much of the sentence has been matched
    if (normalizedRecognized > sentenceStart) {
      final matchedInSentence = (normalizedRecognized - sentenceStart)
          .clamp(0, sentenceNormalized.length);
      final matchRatio = matchedInSentence / sentenceNormalized.length;

      // Advance to next sentence when >50% matched
      if (matchRatio > 0.5 && _currentSentence < script.sentences.length - 1) {
        // Check if we're past the midpoint of the sentence
        if (normalizedRecognized >= sentenceStart + sentenceNormalized.length ~/ 2) {
          _currentSentence++;
        }
      }
    }

    // Also check if we've gone well past the current sentence
    if (normalizedRecognized >= sentenceEnd &&
        _currentSentence < script.sentences.length - 1) {
      _currentSentence++;
      // Recursively check in case we skipped multiple sentences
      _updateSentenceFromCharCount();
    }
  }

  /// Character-level fuzzy match on the remaining source suffix.
  /// Returns number of characters matched from matchStartOffset.
  int _charLevelMatch(String spoken) {
    if (_matchStartOffset >= _normalizedSource.length) return 0;

    final remainingSource = _normalizedSource.substring(_matchStartOffset);
    final normalizedSpoken = _normalize(spoken);
    if (normalizedSpoken.isEmpty) return 0;

    var si = 0; // source index
    var ri = 0; // recognition (spoken) index
    var lastGoodOrigIndex = 0;

    while (si < remainingSource.length && ri < normalizedSpoken.length) {
      final sc = remainingSource[si];
      final rc = normalizedSpoken[ri];

      // Skip non-alnum in both
      if (!_isAlnum(sc)) {
        si++;
        continue;
      }
      if (!_isAlnum(rc)) {
        ri++;
        continue;
      }

      if (sc == rc) {
        lastGoodOrigIndex = si;
        si++;
        ri++;
        continue;
      }

      // Mismatch — try re-sync
      var synced = false;

      // Skip up to 3 in spoken (ASR inserted extra)
      for (var k = 1; k <= 3 && ri + k < normalizedSpoken.length; k++) {
        if (_isAlnum(normalizedSpoken[ri + k]) &&
            normalizedSpoken[ri + k] == sc) {
          ri += k;
          synced = true;
          break;
        }
      }
      if (synced) continue;

      // Skip up to 3 in source (ASR missed)
      for (var k = 1; k <= 3 && si + k < remainingSource.length; k++) {
        if (_isAlnum(remainingSource[si + k]) &&
            remainingSource[si + k] == rc) {
          si += k;
          synced = true;
          break;
        }
      }
      if (synced) continue;

      // Neither — treat as substitution, record progress
      lastGoodOrigIndex = si;
      si++;
      ri++;
    }

    return lastGoodOrigIndex;
  }

  /// Word-level match on the remaining source suffix.
  /// Returns number of characters matched from matchStartOffset.
  int _wordLevelMatch(String spoken) {
    if (_matchStartOffset >= _sourceText.length) return 0;

    final remaining = _sourceText.substring(_matchStartOffset);
    final srcWords = remaining.split(RegExp(r'\s+'));
    final spkWords = spoken
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    if (srcWords.isEmpty || spkWords.isEmpty) return 0;

    var si = 0; // source word index
    var ri = 0; // spoken word index
    var matchedCharCount = 0;

    while (si < srcWords.length && ri < spkWords.length) {
      final srcWord =
          srcWords[si].toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final spkWord =
          spkWords[ri].replaceAll(RegExp(r'[^a-z0-9]'), '');

      // Skip empty source words (punctuation only)
      if (srcWord.isEmpty) {
        matchedCharCount += srcWords[si].length + 1; // +1 for space
        si++;
        continue;
      }

      if (_isFuzzyMatch(srcWord, spkWord)) {
        matchedCharCount += srcWords[si].length + 1;
        si++;
        ri++;
        continue;
      }

      // Try skipping up to 3 spoken words (ASR hallucinated)
      var found = false;
      for (var skip = 1; skip <= 3 && ri + skip < spkWords.length; skip++) {
        final ahead =
            spkWords[ri + skip].replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (_isFuzzyMatch(srcWord, ahead)) {
          ri += skip + 1;
          matchedCharCount += srcWords[si].length + 1;
          si++;
          found = true;
          break;
        }
      }
      if (found) continue;

      // Try skipping up to 3 source words (user skipped ahead)
      for (var skip = 1; skip <= 3 && si + skip < srcWords.length; skip++) {
        final aheadSrc = srcWords[si + skip]
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (_isFuzzyMatch(aheadSrc, spkWord)) {
          // Accumulate skipped source words
          for (var k = 0; k <= skip; k++) {
            matchedCharCount += srcWords[si + k].length + 1;
          }
          si += skip + 1;
          ri++;
          found = true;
          break;
        }
      }
      if (found) continue;

      // No match — advance spoken only
      ri++;
    }

    // Remove trailing +1 space if we matched anything
    if (matchedCharCount > 0) matchedCharCount--;

    return matchedCharCount;
  }

  /// Textream's isFuzzyMatch — prefix, containment, shared prefix, edit distance.
  bool _isFuzzyMatch(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;

    // Prefix match — only if prefix covers >= 50% of the longer word
    final longer = max(a.length, b.length);
    if (a.startsWith(b) && b.length * 2 >= longer) return true;
    if (b.startsWith(a) && a.length * 2 >= longer) return true;

    // Substring containment — only for words with length >= 4
    if (a.length >= 4 && b.length >= 4) {
      if (a.contains(b) || b.contains(a)) return true;
    }

    // Shared prefix >= 60% of shorter word
    final shorter = min(a.length, b.length);
    if (shorter >= 2) {
      var shared = 0;
      for (var i = 0; i < shorter; i++) {
        if (a[i] == b[i]) {
          shared++;
        } else {
          break;
        }
      }
      if (shared >= max(2, (shorter * 3) ~/ 5)) return true;
    }

    // Edit distance tolerance (tiered by word length)
    final dist = _editDistance(a, b);
    if (shorter <= 4) return dist <= 1;
    if (shorter <= 8) return dist <= 2;
    return dist <= max(a.length, b.length) ~/ 3;
  }

  int _editDistance(String a, String b) {
    final n = a.length, m = b.length;
    if (n == 0) return m;
    if (m == 0) return n;

    var prev = List<int>.generate(m + 1, (j) => j);
    var curr = List<int>.filled(m + 1, 0);

    for (var i = 1; i <= n; i++) {
      curr[0] = i;
      for (var j = 1; j <= m; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[m];
  }

  /// Convert character count to word index.
  int _charCountToWordIndex(int charCount) {
    final script = _script;
    if (script == null || script.tokens.isEmpty) return 0;
    if (charCount <= 0) return 0;

    var offset = 0;
    for (var i = 0; i < _sourceWords.length; i++) {
      offset += _sourceWords[i].length;
      if (offset >= charCount) return min(i, script.tokens.length - 1);
      offset += 1; // space
    }
    return script.tokens.length - 1;
  }

  String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), '');
  }

  bool _isAlnum(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) || (code >= 97 && code <= 122);
  }
}
