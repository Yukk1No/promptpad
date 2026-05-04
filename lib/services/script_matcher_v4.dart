import 'dart:math';
import '../models/script.dart';
import 'script_matcher_base.dart';

/// V4 speech matcher: V3 + automatic confidence-aware post-reset budget gate.
///
/// V3 introduced an 8-partial post-reset partial-recovery budget that
/// collapsed cross-session recovery from ~2.4 s to ~700 ms median on
/// clean Vosk JFK ios — but regressed on cafe-noise-snr-10
/// (MAE 41.79 → 73.09) because moderate-noise partials anchor to
/// *wrong* sentence targets that look comparably-scored.
///
/// V3.1 (`setNoisyEnvironmentMode(bool)`) was a workaround: a runtime
/// toggle the host can flip when noise is known. V4 is the proper
/// fix: the matcher gates the partial-recovery budget on the inbound
/// transcript's mean ASR confidence, automatically suppressing
/// recovery on low-confidence (= noisy) partials and admitting
/// recovery on high-confidence (= clean) ones.
///
/// New mechanism (the MAJOR justification per CLAUDE.md version
/// policy): per-event mean confidence is read from the events.json
/// schema (added in the same v4-confidence-aware PR) and used as a
/// real-time signal — not measurable from greedy match scores
/// alone.
///
/// Threshold: 0.6. Calibrated from the JFK Vosk events:
///   clean ios:               sample mean conf ≈ 0.96 ⇒ above ⇒ V3 behavior
///   cafe-noise-snr-10 ios:   sample mean conf ≈ 0.46 ⇒ below ⇒ V2 fallback
///   tts_jfk ios:             mean conf = 1.0          ⇒ above ⇒ V3 behavior
///
/// Default-trust contract: legacy events without confidence (or
/// confidence 1.0 from synthetic TTS) take the V3 path. Only
/// observed-noisy partials get suppressed. V4 is therefore
/// byte-identical to V3 on:
///   - clean-passthrough (no session resets ⇒ budget never opens)
///   - tts_jfk ios (resets exist but confidence = 1.0 ≥ threshold)
///   - any pre-confidence-schema events.json the host hasn't
///     regenerated yet (replay.dart defaults the missing field to 1.0)
///
/// Body of the matcher is otherwise identical to V3 — copied here
/// because V3's private fields are library-scoped and cannot be
/// reached from a subclass in a different file. Per CLAUDE.md
/// "one MAJOR per file"; do not touch V3.

class _Hypothesis {
  int wordPos;
  _Hypothesis({required this.wordPos});
}

class ScriptMatcherV4 implements ScriptMatcherBase {
  Script? _script;

  // Pre-computed source data
  String _sourceText = '';
  List<String> _sourceWords = [];
  List<String> _sourceWordsNorm = [];
  List<String> _sourceMetaphones = [];
  Set<int> _anchorIndices = {};

  // V1-style greedy matching state
  int _matchStartOffset = 0;
  int _recognizedCharCount = 0;

  // Sentence tracking
  List<(int, int)> _sentenceBounds = [];
  List<int> _sentenceCharOffsets = [];
  int _currentSentence = 0;

  // Stale detection
  int _staleCount = 0;
  static const int _staleThreshold = 4;
  static const int _resyncLookahead = 6;

  // V3-style post-reset partial-recovery budget
  int _postResetPartialBudget = 0;
  static const int _postResetPartialBudgetSize = 8;

  // V4-only: most-recent mean confidence forwarded by the host before
  // the next match() call. Defaults to 1.0 so legacy events without
  // confidence behave identically to V3.
  double _nextMeanConfidence = 1.0;

  // V4 confidence threshold: partials with mean confidence below this
  // value cannot trigger post-reset recovery (we trust them less than
  // V3's recovery-on-partial path requires). Calibrated against the
  // JFK Vosk events: 0.46 (cafe-noise-snr-10) vs 0.96 (clean) — 0.6
  // sits in the dead zone. See benchmark/reports/v4-vs-v3-report.md
  // for the calibration sweep.
  static const double _confidenceGateThreshold = 0.6;

  // Beam state (mode tracking + recovery)
  List<_Hypothesis> _beam = [];

  // Static RegExp
  static final _whitespaceRe = RegExp(r'\s+');
  static final _nonAlnumRe = RegExp(r'[^a-z0-9]');

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  int get confirmedPosition => _charCountToWordIndex(_recognizedCharCount);

  int get displayPosition => confirmedPosition;

  @override
  int get currentSentence => _currentSentence;

  @override
  int get totalSentences => _script?.sentences.length ?? 0;

  /// V4: host forwards the inbound event's mean confidence here before
  /// each match() call. Stored until consumed in the next match().
  @override
  void setNextEventConfidence(double meanConfidence) {
    _nextMeanConfidence = meanConfidence;
  }

  @override
  void loadScript(Script script) {
    _script = script;
    _sourceText = script.tokens.map((t) => t.raw).join(' ');
    _sourceWords = _sourceText.split(_whitespaceRe);
    _sourceWordsNorm = script.tokens
        .map((t) => t.normalized.replaceAll(_nonAlnumRe, ''))
        .toList();
    _sourceMetaphones = script.tokens.map((t) => t.metaphone).toList();

    _anchorIndices = {};
    for (var i = 0; i < script.tokens.length; i++) {
      if (script.tokens[i].isAnchor) _anchorIndices.add(i);
    }

    _computeSentenceBounds(script);
    reset();
  }

  @override
  void reset() {
    _matchStartOffset = 0;
    _recognizedCharCount = 0;
    _currentSentence = 0;
    _staleCount = 0;
    _beam = [_Hypothesis(wordPos: 0)];
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
    _staleCount = 0;
    _beam = [_Hypothesis(wordPos: clamped)];
    _updateSentenceFromWordIndex(clamped);
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
      final wordIdx = _charCountToWordIndex(charOff);
      _beam = [_Hypothesis(wordPos: wordIdx)];
    }
  }

  @override
  void onSessionReset() {
    _matchStartOffset = _recognizedCharCount;
    _staleCount = 0;
    final wordIdx = confirmedPosition;
    _beam = [_Hypothesis(wordPos: wordIdx)];
    _postResetPartialBudget = _postResetPartialBudgetSize;
  }

  /// Process a spoken transcript. Returns the current word index.
  @override
  int match(String spoken, {bool isFinal = false}) {
    if (_script == null || _sourceText.isEmpty) return 0;

    final prevCount = _recognizedCharCount;

    final spokenLower = spoken.toLowerCase();
    final spokenWords = spokenLower
        .split(_whitespaceRe)
        .where((w) => w.isNotEmpty)
        .toList();

    final List<String> wordsForMatching;
    final String textForCharMatch;
    if (isFinal || spokenWords.length < 3) {
      wordsForMatching = spokenWords;
      textForCharMatch = spokenLower;
    } else {
      wordsForMatching = spokenWords.sublist(0, spokenWords.length - 1);
      textForCharMatch = wordsForMatching.join(' ');
    }

    final charResult = _charLevelMatch(textForCharMatch);
    final wordResult = _wordLevelMatch(wordsForMatching);
    final best = max(charResult, wordResult);
    final newCount = _matchStartOffset + best;

    if (newCount > _recognizedCharCount) {
      _recognizedCharCount = min(newCount, _sourceText.length);
    }

    final tailNorm = wordsForMatching
        .map((w) => w.replaceAll(_nonAlnumRe, ''))
        .where((w) => w.isNotEmpty)
        .toList();
    final tailResult = _tailMatch(tailNorm);
    if (tailResult != null && tailResult > _recognizedCharCount) {
      final maxJump = _nextSentenceCharOffset();
      _recognizedCharCount = min(tailResult, maxJump);
    }

    final madeProgress = _recognizedCharCount > prevCount;
    if (madeProgress) {
      _staleCount = 0;
      _postResetPartialBudget = 0;
    } else if (spoken.trim().isNotEmpty) {
      _staleCount++;
    }

    final inPostResetWindow = _postResetPartialBudget > 0;
    if (inPostResetWindow) {
      _postResetPartialBudget--;
    }
    // V4 confidence gate: when the budget window is open and the
    // inbound partial's mean confidence is below the threshold,
    // suppress recovery for THIS call only (do not zero the budget —
    // the next, higher-confidence partial within the window may still
    // fire recovery). High-confidence partials and isFinal-triggered
    // recovery (which is V2's path) are unaffected by this gate.
    final lowConfidencePartial = inPostResetWindow &&
        !isFinal &&
        _nextMeanConfidence < _confidenceGateThreshold;
    final canRecover = !lowConfidencePartial &&
        ((_staleCount >= _staleThreshold && isFinal) ||
            (inPostResetWindow && _staleCount >= 2 && spokenWords.length >= 2));
    if (canRecover && spoken.trim().isNotEmpty) {
      if (_resyncMatch(tailNorm.isNotEmpty ? tailNorm : spokenWords)) {
        _staleCount = 0;
        _postResetPartialBudget = 0;
      } else if (_staleCount >= _staleThreshold * 3) {
        _beamRecovery(tailNorm.isNotEmpty ? tailNorm : spokenWords);
      }
    }

    if (isFinal) {
      _matchStartOffset = _recognizedCharCount;
    }

    final wordIdx = confirmedPosition;
    _updateSentenceFromWordIndex(wordIdx);

    if (_beam.isEmpty || (_beam.first.wordPos - wordIdx).abs() > 3) {
      _beam = [_Hypothesis(wordPos: wordIdx)];
    } else {
      _beam.first.wordPos = wordIdx;
    }

    // Reset the stored confidence after consumption so a missing
    // setNextEventConfidence() call before the next match() reverts
    // to the default-trust 1.0 rather than carrying forward a stale
    // low-confidence value.
    _nextMeanConfidence = 1.0;

    return wordIdx;
  }

  // ---------------------------------------------------------------------------
  // V1-style Greedy Matching (identical to V3)
  // ---------------------------------------------------------------------------

  int _charLevelMatch(String spokenLower) {
    if (_matchStartOffset >= _sourceText.length) return 0;

    final remainEnd = min(_matchStartOffset + 500, _sourceText.length);
    final remainingSource =
        _sourceText.substring(_matchStartOffset, remainEnd).toLowerCase();
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

  int _wordLevelMatch(List<String> spokenWords) {
    if (_matchStartOffset >= _sourceText.length) return 0;
    if (spokenWords.isEmpty) return 0;

    final remainEnd = min(_matchStartOffset + 500, _sourceText.length);
    final remaining = _sourceText.substring(_matchStartOffset, remainEnd);
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

  int? _tailMatch(List<String> spokenNorm) {
    if (spokenNorm.length < 3) return null;

    const maxTailLen = 5;
    const minConsecutive = 3;
    final tailLen = spokenNorm.length.clamp(minConsecutive, maxTailLen);
    final tailWords = spokenNorm.sublist(spokenNorm.length - tailLen);
    if (tailWords.length < minConsecutive) return null;

    final startIdx = confirmedPosition;
    const windowSize = 15;
    final endIdx = min(startIdx + windowSize, _sourceWordsNorm.length);
    if (startIdx >= endIdx) return null;

    var bestMatchCount = 0;
    var bestSourceIdx = -1;

    for (var wi = startIdx; wi <= endIdx - minConsecutive; wi++) {
      var consecutive = 0;
      var ti = 0;
      var si = wi;

      while (ti < tailWords.length && si < endIdx) {
        if (_sourceWordsNorm[si].isEmpty) {
          si++;
          continue;
        }
        if (_isFuzzyMatchCached(si, tailWords[ti])) {
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

  // ---------------------------------------------------------------------------
  // Recovery (identical to V3)
  // ---------------------------------------------------------------------------

  bool _resyncMatch(List<String> spokenWords) {
    final script = _script;
    if (script == null || _sentenceBounds.isEmpty) return false;
    if (spokenWords.isEmpty) return false;

    final maxSentence = min(
      _currentSentence + _resyncLookahead,
      script.sentences.length - 1,
    );

    var bestScore = 0;
    var bestSentence = -1;
    var bestCharOffset = 0;

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

    if (bestSentence >= 0 && bestScore >= 15) {
      _currentSentence = bestSentence;
      _recognizedCharCount = bestCharOffset + bestScore;
      _matchStartOffset = _recognizedCharCount;
      return true;
    }
    return false;
  }

  void _beamRecovery(List<String> spokenWords) {
    if (spokenWords.isEmpty) return;

    final spkNorm = spokenWords
        .map((w) => w.replaceAll(_nonAlnumRe, ''))
        .where((w) => w.isNotEmpty)
        .toList();
    if (spkNorm.length < 2) return;

    final totalWords = _sourceWordsNorm.length;
    final currentWordIdx = confirmedPosition;

    var bestScore = 0.0;
    var bestPos = -1;

    final lo = currentWordIdx;
    final hi = min(totalWords, currentWordIdx + 50);

    for (final ai in _anchorIndices) {
      if (ai < lo || ai >= hi) continue;
      final score = _scoreAnchorMatch(spkNorm, ai);
      if (score > bestScore) {
        bestScore = score;
        bestPos = ai;
      }
    }

    for (var pos = lo; pos < hi; pos += 3) {
      if (_anchorIndices.contains(pos)) continue;
      final score = _scoreAnchorMatch(spkNorm, pos);
      if (score > bestScore * 0.8 && score > 25.0) {
        bestScore = score;
        bestPos = pos;
      }
    }

    if (bestPos >= 0 && bestScore >= 35.0) {
      final charOff = _wordIndexToCharOffset(bestPos);
      _recognizedCharCount = charOff;
      _matchStartOffset = charOff;
      _staleCount = 0;
    }
  }

  double _scoreAnchorMatch(List<String> spkNorm, int anchorIdx) {
    if (spkNorm.isEmpty) return 0;

    final recentLen = min(5, spkNorm.length);
    final recent = spkNorm.sublist(spkNorm.length - recentLen);

    final totalWords = _sourceWordsNorm.length;
    final scanStart = max(0, anchorIdx - recent.length + 1);
    final scanEnd = min(totalWords, anchorIdx + recent.length);

    var score = 0.0;
    var si = 0;
    var wi = scanStart;

    while (si < recent.length && wi < scanEnd) {
      final srcNorm = _sourceWordsNorm[wi];
      final spkWord = recent[si];

      if (srcNorm == spkWord) {
        score += 10.0;
        if (_anchorIndices.contains(wi)) score += 15.0;
        si++;
        wi++;
      } else if (_metaphoneMatch(wi, spkWord)) {
        score += 7.0;
        si++;
        wi++;
      } else if (srcNorm.isNotEmpty &&
          spkWord.isNotEmpty &&
          _editDistance(srcNorm, spkWord) <= 2) {
        score += 5.0;
        si++;
        wi++;
      } else {
        score -= 2.0;
        si++;
        wi++;
      }
    }

    return score;
  }

  // ---------------------------------------------------------------------------
  // Sentence Tracking (identical to V3)
  // ---------------------------------------------------------------------------

  int _nextSentenceCharOffset() {
    if (_sentenceCharOffsets.isEmpty) return _sourceText.length;
    final targetSentence = _currentSentence + 2;
    if (targetSentence < _sentenceCharOffsets.length) {
      return _sentenceCharOffsets[targetSentence];
    }
    return _sourceText.length;
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

  void _updateSentenceFromWordIndex(int wordIndex) {
    final script = _script;
    if (script == null || script.sentences.isEmpty) return;
    if (_sentenceBounds.isEmpty) return;

    for (var i = 0; i < _sentenceBounds.length; i++) {
      final (startW, endW) = _sentenceBounds[i];
      if (wordIndex < endW) {
        final mid = startW + (endW - startW) ~/ 2;
        _currentSentence =
            (wordIndex >= mid && i + 1 < _sentenceBounds.length) ? i + 1 : i;
        return;
      }
    }
    _currentSentence = _sentenceBounds.length - 1;
  }

  // ---------------------------------------------------------------------------
  // Matching Helpers (identical to V3)
  // ---------------------------------------------------------------------------

  bool _metaphoneMatch(int sourceIdx, String spokenWord) {
    if (sourceIdx >= _sourceMetaphones.length) return false;
    final metaSrc = _sourceMetaphones[sourceIdx];
    if (metaSrc.isEmpty) return false;
    final metaSpk = doubleMetaphone(spokenWord);
    return metaSpk.isNotEmpty && metaSrc == metaSpk;
  }

  bool _isFuzzyMatchCached(int sourceIdx, String spokenWord) {
    if (sourceIdx >= _sourceWordsNorm.length) return false;
    final srcWord = _sourceWordsNorm[sourceIdx];
    if (srcWord.isEmpty || spokenWord.isEmpty) return false;
    if (srcWord == spokenWord) return true;

    final metaSrc = _sourceMetaphones[sourceIdx];
    final metaSpk = doubleMetaphone(spokenWord);
    if (metaSrc.isNotEmpty && metaSpk.isNotEmpty && metaSrc == metaSpk) {
      return true;
    }

    return _isFuzzyMatchCore(srcWord, spokenWord);
  }

  bool _isFuzzyMatchCore(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;

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

  static int _editDistance(String a, String b) {
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
}
