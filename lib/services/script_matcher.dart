import 'dart:math';
import '../models/script.dart';
import 'script_matcher_base.dart';

/// Speech matcher with tail-match re-anchoring for drift recovery.
///
/// Dual strategy: char-level + word-level matching from textream.
/// Tail-match: last few spoken words searched ahead to correct drift.
/// Stale detection + resync for catastrophic loss.
class ScriptMatcher implements ScriptMatcherBase {
  Script? _script;

  String _sourceText = '';
  List<String> _sourceWords = [];

  /// Pre-normalized lowercase source words (computed once).
  List<String> _sourceWordsNorm = [];

  /// Pre-computed Double Metaphone codes for source words.
  List<String> _sourceMetaphones = [];

  int _matchStartOffset = 0;
  int _recognizedCharCount = 0;
  int _currentSentence = 0;

  int _staleCount = 0;
  static const int _staleThreshold = 3;
  static const int _resyncLookahead = 5;

  List<(int, int)> _sentenceBounds = [];
  List<int> _sentenceCharOffsets = [];

  // Static RegExp to avoid re-creation per call
  static final _whitespaceRe = RegExp(r'\s+');
  static final _nonAlnumRe = RegExp(r'[^a-z0-9]');

  @override
  int get currentSentence => _currentSentence;
  @override
  int get totalSentences => _script?.sentences.length ?? 0;
  int get staleCount => _staleCount;

  @override
  int get confirmedPosition => _charCountToWordIndex(_recognizedCharCount);

  @override
  void loadScript(Script script) {
    _script = script;
    _sourceText = script.tokens.map((t) => t.raw).join(' ');
    _sourceWords = _sourceText.split(_whitespaceRe);
    _matchStartOffset = 0;
    _recognizedCharCount = 0;
    _currentSentence = 0;
    _staleCount = 0;

    // Pre-compute normalized words and metaphone codes
    _sourceWordsNorm = _sourceWords
        .map((w) => w.toLowerCase().replaceAll(_nonAlnumRe, ''))
        .toList();
    _sourceMetaphones = _sourceWordsNorm.map(doubleMetaphone).toList();

    _computeSentenceBounds(script);
  }

  void _computeSentenceBounds(Script script) {
    _sentenceBounds = [];
    _sentenceCharOffsets = [];

    if (script.sentences.isEmpty || script.tokens.isEmpty) return;

    var tokenIdx = 0;
    for (final sentence in script.sentences) {
      final sentWords = sentence.displayText
          .split(_whitespaceRe)
          .where((w) => w.isNotEmpty)
          .toList();
      final startToken = tokenIdx;
      for (final _ in sentWords) {
        if (tokenIdx < script.tokens.length) tokenIdx++;
      }
      _sentenceBounds.add((startToken, tokenIdx));
      _sentenceCharOffsets.add(_wordIndexToCharOffset(startToken));
    }
  }

  @override
  void reset() {
    _matchStartOffset = 0;
    _recognizedCharCount = 0;
    _currentSentence = 0;
    _staleCount = 0;
  }

  @override
  void jumpTo(int wordIndex) {
    final script = _script;
    if (script == null) return;
    final clamped = wordIndex.clamp(0, script.tokens.length - 1);
    var charPos = 0;
    for (var i = 0; i < clamped; i++) {
      charPos += script.tokens[i].raw.length + 1;
    }
    _recognizedCharCount = charPos;
    _matchStartOffset = charPos;
  }

  @override
  void jumpToSentence(int sentenceIndex) {
    final script = _script;
    if (script == null || script.sentences.isEmpty) return;
    _currentSentence = sentenceIndex.clamp(0, script.sentences.length - 1);
    _staleCount = 0;
    if (_currentSentence < _sentenceCharOffsets.length) {
      final charOff = _sentenceCharOffsets[_currentSentence];
      _recognizedCharCount = charOff;
      _matchStartOffset = charOff;
    }
  }

  /// Process a spoken transcript. Returns the current word index.
  @override
  int match(String spoken, {bool isFinal = false}) {
    if (_script == null || _sourceText.isEmpty) return 0;

    final prevCount = _recognizedCharCount;

    // Normalize spoken text once, reuse across strategies
    final spokenLower = spoken.toLowerCase();
    final spokenWords = spokenLower
        .split(_whitespaceRe)
        .where((w) => w.isNotEmpty)
        .toList();

    // Normal match from current offset
    final charResult = _charLevelMatch(spokenLower);
    final wordResult = _wordLevelMatch(spokenWords);
    final best = max(charResult, wordResult);
    final newCount = _matchStartOffset + best;

    if (newCount > _recognizedCharCount) {
      _recognizedCharCount = min(newCount, _sourceText.length);
    }

    // Tail-match re-anchoring: bounded jump (max 1 sentence ahead)
    final tailResult = _tailMatch(spokenWords);
    if (tailResult != null && tailResult > _recognizedCharCount) {
      // Limit jump: don't exceed next sentence boundary
      final maxJump = _nextSentenceCharOffset();
      _recognizedCharCount = min(tailResult, maxJump);
    }

    // Track stale state
    final madeProgress = _recognizedCharCount > prevCount;
    if (madeProgress) {
      _staleCount = 0;
    } else if (spoken.trim().isNotEmpty) {
      _staleCount++;
    }

    // Resync: if stuck, search ahead in upcoming sentences
    if (_staleCount >= _staleThreshold && isFinal && spoken.trim().isNotEmpty) {
      if (_resyncMatch(spokenWords)) {
        _staleCount = 0;
      }
    }

    if (isFinal) {
      _matchStartOffset = _recognizedCharCount;
    }

    _updateSentenceFromCharCount();
    return confirmedPosition;
  }

  /// Get the char offset of the END of the next sentence (for bounding jumps).
  int _nextSentenceCharOffset() {
    if (_sentenceCharOffsets.isEmpty) return _sourceText.length;
    // Allow jumping up to 2 sentences ahead (current + 1)
    final targetSentence = _currentSentence + 2;
    if (targetSentence < _sentenceCharOffsets.length) {
      return _sentenceCharOffsets[targetSentence];
    }
    return _sourceText.length;
  }

  /// Search ahead in the next sentences for the best match.
  bool _resyncMatch(List<String> spokenWords) {
    final script = _script;
    if (script == null) return false;
    if (_sentenceCharOffsets.isEmpty || _sentenceBounds.isEmpty) return false;
    if (spokenWords.isEmpty) return false;

    final maxSentence = min(
      _currentSentence + _resyncLookahead,
      script.sentences.length - 1,
    );

    int bestScore = 0;
    int bestSentence = -1;
    int bestCharOffset = 0;

    for (var si = _currentSentence + 1; si <= maxSentence; si++) {
      if (si >= _sentenceCharOffsets.length) break;
      final sentCharOff = _sentenceCharOffsets[si];
      if (sentCharOff >= _sourceText.length) continue;

      final savedOffset = _matchStartOffset;
      _matchStartOffset = sentCharOff;

      final charScore = _charLevelMatch(spokenWords.join(' '));
      final wordScore = _wordLevelMatch(spokenWords);
      final score = max(charScore, wordScore);

      _matchStartOffset = savedOffset;

      if (score > bestScore) {
        bestScore = score;
        bestSentence = si;
        bestCharOffset = sentCharOff;
      }
    }

    // Require ~3 words of evidence, not just one short common word.
    if (bestSentence >= 0 && bestScore >= 15) {
      _currentSentence = bestSentence;
      _recognizedCharCount = bestCharOffset + bestScore;
      _matchStartOffset = _recognizedCharCount;
      return true;
    }
    return false;
  }

  /// Tail-match: match last 3-5 spoken words in a forward window.
  /// Returns char offset, or null. Bounded to prevent huge jumps.
  int? _tailMatch(List<String> spokenWords) {
    if (spokenWords.length < 2) return null;

    const maxTailLen = 5;
    const minConsecutive = 2;
    final tailLen = spokenWords.length.clamp(minConsecutive, maxTailLen);
    final tailWords = spokenWords.sublist(spokenWords.length - tailLen);
    final tailNorm = tailWords
        .map((w) => w.replaceAll(_nonAlnumRe, ''))
        .where((w) => w.isNotEmpty)
        .toList();
    if (tailNorm.length < minConsecutive) return null;

    final startIdx = confirmedPosition;
    const windowSize = 15; // tighter window to reduce false positives
    final endIdx = min(startIdx + windowSize, _sourceWordsNorm.length);
    if (startIdx >= endIdx) return null;

    int bestMatchCount = 0;
    int bestSourceIdx = -1;

    for (var wi = startIdx; wi <= endIdx - minConsecutive; wi++) {
      var consecutive = 0;
      var ti = 0;
      var si = wi;

      while (ti < tailNorm.length && si < endIdx) {
        if (_sourceWordsNorm[si].isEmpty) {
          si++;
          continue;
        }
        if (_isFuzzyMatchCached(si, tailNorm[ti])) {
          consecutive++;
          si++;
          ti++;
        } else {
          break;
        }
      }

      if (consecutive >= minConsecutive && consecutive > bestMatchCount) {
        bestMatchCount = consecutive;
        bestSourceIdx = si;
      }
    }

    if (bestSourceIdx < 0) return null;
    return _wordIndexToCharOffset(bestSourceIdx);
  }

  /// Fuzzy match using cached metaphone for source word at index.
  bool _isFuzzyMatchCached(int sourceIdx, String spokenWord) {
    if (sourceIdx >= _sourceWordsNorm.length) return false;
    final srcWord = _sourceWordsNorm[sourceIdx];
    if (srcWord.isEmpty || spokenWord.isEmpty) return false;
    if (srcWord == spokenWord) return true;

    // Cached metaphone for source, compute for spoken
    final metaSrc = _sourceMetaphones[sourceIdx];
    final metaSpk = doubleMetaphone(spokenWord);
    if (metaSrc.isNotEmpty && metaSpk.isNotEmpty && metaSrc == metaSpk) {
      return true;
    }

    return _isFuzzyMatchCore(srcWord, spokenWord);
  }

  void _updateSentenceFromCharCount() {
    final script = _script;
    if (script == null || script.sentences.isEmpty) return;
    if (_sentenceBounds.isEmpty) return;
    if (_currentSentence >= script.sentences.length - 1) return;

    final currentWordIdx = _charCountToWordIndex(_recognizedCharCount);
    final (startW, endW) = _sentenceBounds[_currentSentence];

    if (startW == endW) {
      _currentSentence++;
      return;
    }
    if (currentWordIdx >= endW) {
      _currentSentence++;
      return;
    }
    final sentenceWordCount = endW - startW;
    final wordsMatched = (currentWordIdx - startW).clamp(0, sentenceWordCount);
    if (wordsMatched > sentenceWordCount ~/ 2) {
      _currentSentence++;
    }
  }

  /// Character-level fuzzy match. Scan limited to avoid O(n*m) blowup.
  int _charLevelMatch(String spokenLower) {
    if (_matchStartOffset >= _sourceText.length) return 0;

    // Limit scan: max 500 chars of remaining source to prevent slowdown
    final remainEnd = min(_matchStartOffset + 500, _sourceText.length);
    final remainingSource = _sourceText
        .substring(_matchStartOffset, remainEnd)
        .toLowerCase();
    if (spokenLower.isEmpty) return 0;

    var si = 0;
    var ri = 0;
    var lastGoodOrigIndex = -1;

    while (si < remainingSource.length && ri < spokenLower.length) {
      final sc = remainingSource[si];
      final rc = spokenLower[ri];

      if (!_isAlnum(sc)) { si++; continue; }
      if (!_isAlnum(rc)) { ri++; continue; }

      if (sc == rc) {
        lastGoodOrigIndex = si;
        si++;
        ri++;
        continue;
      }

      var synced = false;
      for (var k = 1; k <= 3 && ri + k < spokenLower.length; k++) {
        if (_isAlnum(spokenLower[ri + k]) && spokenLower[ri + k] == sc) {
          ri += k;
          synced = true;
          break;
        }
      }
      if (synced) continue;

      for (var k = 1; k <= 3 && si + k < remainingSource.length; k++) {
        if (_isAlnum(remainingSource[si + k]) &&
            remainingSource[si + k] == rc) {
          si += k;
          synced = true;
          break;
        }
      }
      if (synced) continue;

      si++;
      ri++;
    }

    return lastGoodOrigIndex + 1;
  }

  /// Word-level match using pre-split spoken words.
  int _wordLevelMatch(List<String> spokenWords) {
    if (_matchStartOffset >= _sourceText.length) return 0;
    if (spokenWords.isEmpty) return 0;

    final remaining = _sourceText.substring(_matchStartOffset);
    final srcWords = remaining.split(_whitespaceRe);
    if (srcWords.isEmpty) return 0;

    var si = 0;
    var ri = 0;
    var matchedCharCount = 0;

    while (si < srcWords.length && ri < spokenWords.length) {
      final srcWord = srcWords[si].toLowerCase().replaceAll(_nonAlnumRe, '');
      final spkWord = spokenWords[ri].replaceAll(_nonAlnumRe, '');

      if (srcWord.isEmpty) {
        matchedCharCount += srcWords[si].length + 1;
        si++;
        continue;
      }

      if (_isFuzzyMatchCore(srcWord, spkWord)) {
        matchedCharCount += srcWords[si].length + 1;
        si++;
        ri++;
        continue;
      }

      var found = false;
      for (var skip = 1; skip <= 3 && ri + skip < spokenWords.length; skip++) {
        final ahead = spokenWords[ri + skip].replaceAll(_nonAlnumRe, '');
        if (_isFuzzyMatchCore(srcWord, ahead)) {
          ri += skip + 1;
          matchedCharCount += srcWords[si].length + 1;
          si++;
          found = true;
          break;
        }
      }
      if (found) continue;

      for (var skip = 1; skip <= 3 && si + skip < srcWords.length; skip++) {
        final aheadSrc =
            srcWords[si + skip].toLowerCase().replaceAll(_nonAlnumRe, '');
        if (_isFuzzyMatchCore(aheadSrc, spkWord)) {
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

      ri++;
    }

    if (matchedCharCount > 0) matchedCharCount--;
    return matchedCharCount;
  }

  /// Core fuzzy match without metaphone cache (for ad-hoc comparisons).
  bool _isFuzzyMatchCore(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;

    // Phonetic match
    final metaA = doubleMetaphone(a);
    final metaB = doubleMetaphone(b);
    if (metaA.isNotEmpty && metaB.isNotEmpty && metaA == metaB) return true;

    final longer = max(a.length, b.length);
    if (a.startsWith(b) && b.length * 2 >= longer) return true;
    if (b.startsWith(a) && a.length * 2 >= longer) return true;

    if (a.length >= 4 && b.length >= 4) {
      if (a.contains(b) || b.contains(a)) return true;
    }

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

  int _charCountToWordIndex(int charCount) {
    final script = _script;
    if (script == null || script.tokens.isEmpty) return 0;
    if (charCount <= 0) return 0;

    var offset = 0;
    for (var i = 0; i < _sourceWords.length; i++) {
      offset += _sourceWords[i].length;
      if (offset >= charCount) return min(i, script.tokens.length - 1);
      offset += 1;
    }
    return script.tokens.length - 1;
  }

  int _wordIndexToCharOffset(int wordIndex) {
    var offset = 0;
    for (var i = 0; i < wordIndex && i < _sourceWords.length; i++) {
      offset += _sourceWords[i].length + 1;
    }
    return offset;
  }

  bool _isAlnum(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) || (code >= 97 && code <= 122);
  }
}
