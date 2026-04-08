import 'dart:math';
import '../models/script.dart';
import 'script_matcher_base.dart';

/// V2 speech matcher: beam search + stable prefix + display hysteresis.
///
/// Dual-loop architecture:
/// - Fast path: stable prefix → beam search → display filter (every ASR event)
/// - Slow path: accumulated stable words → wide realignment (every 5 finals)
///
/// Design principle: "不乱跳、能冻结、能回正"
/// — Freezing when uncertain is always safer than jumping wrong.

/// Operating mode of the matcher state machine.
enum MatcherMode { normal, uncertain, lost, offscript }

/// A single beam hypothesis tracking a candidate position in the script.
class _Hypothesis {
  int wordPos;
  double score;
  MatcherMode mode;
  double speed; // estimated words/sec

  _Hypothesis({
    required this.wordPos,
    required this.score,
    this.mode = MatcherMode.normal,
    this.speed = 2.0,
  });

  _Hypothesis clone() => _Hypothesis(
        wordPos: wordPos,
        score: score,
        mode: mode,
        speed: speed,
      );
}

class ScriptMatcherV2 implements ScriptMatcherBase {
  Script? _script;

  // Pre-computed source data (mirrors v1 pattern)
  List<String> _sourceWords = [];
  List<String> _sourceWordsNorm = [];
  List<String> _sourceMetaphones = [];
  List<int> _anchorIndices = [];

  // Sentence tracking (same as v1)
  List<(int, int)> _sentenceBounds = [];
  List<int> _sentenceCharOffsets = [];
  int _currentSentence = 0;

  // Beam search state
  List<_Hypothesis> _beam = [];
  static const int _beamWidth = 8;

  // Stable prefix extraction — circular buffer of last 3 partials
  final List<List<String>> _partialBuffer = [];
  static const int _partialBufferSize = 3;

  // Display hysteresis
  int _internalWordPos = 0;
  int _displayWordPos = 0;
  DateTime _internalStableSince = DateTime.now();
  int _lastStableInternalPos = 0;

  // Mode state machine counters
  int _uncertainFrames = 0;
  int _lostFrames = 0;

  // Slow-path realignment
  final List<String> _stableWordBuffer = [];
  int _finalCount = 0;

  // Timing for speed estimation
  DateTime _lastMatchTime = DateTime.now();

  // Static RegExp (avoid re-creation)
  static final _whitespaceRe = RegExp(r'\s+');
  static final _nonAlnumRe = RegExp(r'[^a-z0-9]');

  // ---------------------------------------------------------------------------
  // Public API (matches ScriptMatcher interface)
  // ---------------------------------------------------------------------------

  @override
  int get confirmedPosition => _internalWordPos;
  int get displayPosition => _displayWordPos;
  @override
  int get currentSentence => _currentSentence;
  @override
  int get totalSentences => _script?.sentences.length ?? 0;
  MatcherMode get mode => _beam.isNotEmpty ? _beam.first.mode : MatcherMode.normal;
  double get confidence => _computeConfidence();

  @override
  void loadScript(Script script) {
    _script = script;
    _sourceWords = script.tokens.map((t) => t.raw).toList();
    _sourceWordsNorm = script.tokens
        .map((t) => t.normalized.replaceAll(_nonAlnumRe, ''))
        .toList();
    _sourceMetaphones = script.tokens.map((t) => t.metaphone).toList();

    _anchorIndices = [];
    for (var i = 0; i < script.tokens.length; i++) {
      if (script.tokens[i].isAnchor) _anchorIndices.add(i);
    }

    _computeSentenceBounds(script);
    reset();
  }

  @override
  void reset() {
    _beam = [_Hypothesis(wordPos: 0, score: 0.0)];
    _internalWordPos = 0;
    _displayWordPos = 0;
    _lastStableInternalPos = 0;
    _internalStableSince = DateTime.now();
    _currentSentence = 0;
    _uncertainFrames = 0;
    _lostFrames = 0;
    _partialBuffer.clear();
    _stableWordBuffer.clear();
    _finalCount = 0;
    _lastMatchTime = DateTime.now();
  }

  @override
  void jumpTo(int wordIndex) {
    final script = _script;
    if (script == null) return;
    final clamped = wordIndex.clamp(0, script.tokens.length - 1);
    _internalWordPos = clamped;
    _displayWordPos = clamped;
    _lastStableInternalPos = clamped;
    _internalStableSince = DateTime.now();
    _beam = [_Hypothesis(wordPos: clamped, score: 0.0)];
    _uncertainFrames = 0;
    _lostFrames = 0;
  }

  @override
  void jumpToSentence(int sentenceIndex) {
    final script = _script;
    if (script == null || script.sentences.isEmpty) return;
    _currentSentence = sentenceIndex.clamp(0, script.sentences.length - 1);
    if (_currentSentence < _sentenceBounds.length) {
      final (startW, _) = _sentenceBounds[_currentSentence];
      jumpTo(startW);
    }
  }

  /// Process a spoken transcript. Returns [displayPosition] for UI.
  @override
  int match(String spoken, {bool isFinal = false}) {
    if (_script == null || _sourceWords.isEmpty) return 0;

    final spokenWords = spoken
        .toLowerCase()
        .split(_whitespaceRe)
        .where((w) => w.isNotEmpty)
        .map((w) => w.replaceAll(_nonAlnumRe, ''))
        .where((w) => w.isNotEmpty)
        .toList();

    if (spokenWords.isEmpty) return _displayWordPos;

    // --- Stable prefix extraction ---
    final stableWords = _extractStablePrefix(spokenWords, isFinal);

    // Use stable prefix when available, otherwise fall back to raw input.
    // Unstable input still drives the beam but with discounted scores.
    final wordsToMatch = stableWords.isNotEmpty ? stableWords : spokenWords;
    final inputIsStable = stableWords.isNotEmpty || isFinal;

    // --- Timing for speed estimation ---
    final now = DateTime.now();
    final rawElapsed = now.difference(_lastMatchTime).inMilliseconds / 1000.0;
    // Floor at 50ms to avoid degenerate speed estimates in tight loops
    final elapsed = max(rawElapsed, 0.05);
    _lastMatchTime = now;

    // --- Beam search ---
    _runBeamSearch(wordsToMatch, elapsed, inputIsStable: inputIsStable);

    // --- Update internal position from top hypothesis ---
    // Cap advancement: never jump more than 12 words per call to prevent runaway
    if (_beam.isNotEmpty) {
      final topPos = _beam.first.wordPos.clamp(0, _sourceWords.length - 1);
      final maxAdvance = _internalWordPos + 12;
      _internalWordPos = min(topPos, maxAdvance);
    }

    // --- Mode state machine ---
    _updateMode();

    // --- Display hysteresis ---
    _updateDisplayPosition(now);

    // --- Slow-path realignment ---
    if (isFinal) {
      _stableWordBuffer.addAll(wordsToMatch);
      _finalCount++;
      if (_finalCount % 5 == 0) {
        _slowPathRealignment();
      }
      // Keep stable word buffer bounded
      if (_stableWordBuffer.length > 30) {
        _stableWordBuffer.removeRange(0, _stableWordBuffer.length - 30);
      }
    }

    // --- Sentence tracking ---
    _updateSentenceFromWordIndex(_internalWordPos);

    return _displayWordPos;
  }

  // ---------------------------------------------------------------------------
  // Stable Prefix Extraction
  // ---------------------------------------------------------------------------

  /// Extract words that are stable across recent partial results.
  /// Final results bypass the stability filter entirely.
  List<String> _extractStablePrefix(List<String> spokenWords, bool isFinal) {
    if (isFinal) {
      _partialBuffer.clear();
      return spokenWords;
    }

    // Add to circular buffer
    if (_partialBuffer.length >= _partialBufferSize) {
      _partialBuffer.removeAt(0);
    }
    _partialBuffer.add(List.of(spokenWords));

    // Need at least _partialBufferSize partials to extract stable prefix
    if (_partialBuffer.length < _partialBufferSize) return [];

    // A token is stable if it appears at the same position in all recent partials
    final minLen = _partialBuffer.map((p) => p.length).reduce(min);
    final stable = <String>[];

    for (var i = 0; i < minLen; i++) {
      final word = _partialBuffer.first[i];
      var allMatch = true;
      for (var j = 1; j < _partialBuffer.length; j++) {
        if (_partialBuffer[j][i] != word) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) {
        stable.add(word);
      } else {
        // Stop at first unstable position — prefix only
        break;
      }
    }

    return stable;
  }

  // ---------------------------------------------------------------------------
  // Beam Search
  // ---------------------------------------------------------------------------

  void _runBeamSearch(List<String> spokenWords, double elapsed,
      {bool inputIsStable = true}) {
    if (_beam.isEmpty) {
      _beam = [_Hypothesis(wordPos: 0, score: 0.0)];
    }

    // Discount factor for unstable (non-confirmed) input
    final stabilityMul = inputIsStable ? 1.0 : 0.6;

    final candidates = <_Hypothesis>[];
    final totalWords = _sourceWords.length;

    for (final hyp in _beam) {
      // Candidate 1: Stay at current position (safe default, no penalty)
      final stay = hyp.clone();
      candidates.add(stay);

      // Candidate 2-4: Advance 1-3 words (normal reading)
      for (var advance = 1; advance <= 3; advance++) {
        final newPos = hyp.wordPos + advance;
        if (newPos >= totalWords) continue;

        final matchScore = _scoreMatch(
          spokenWords,
          hyp.wordPos,
          newPos,
          hyp.speed,
          elapsed,
          advance,
        ) * stabilityMul;

        // Only advance if match quality is meaningful
        if (matchScore <= 0) continue;

        final candidate = hyp.clone();
        candidate.wordPos = newPos;
        candidate.score += matchScore;
        candidate.mode = MatcherMode.normal;

        // Update speed estimate with exponential moving average
        final instantSpeed = advance / elapsed;
        candidate.speed = candidate.speed * 0.7 + instantSpeed * 0.3;

        candidates.add(candidate);
      }

      // Candidate 5: Jump forward 4-10 words (skip-read)
      // Only attempt jumps when we have enough spoken words to validate
      if (spokenWords.length >= 3) {
        for (var jump = 4; jump <= 10; jump += 2) {
          final newPos = hyp.wordPos + jump;
          if (newPos >= totalWords) continue;

          final matchScore = _scoreMatch(
            spokenWords,
            hyp.wordPos,
            newPos,
            hyp.speed,
            elapsed,
            jump,
          ) * stabilityMul;

          // Require strong match quality for jumps
          if (matchScore < 15.0) continue;

          final candidate = hyp.clone();
          candidate.wordPos = newPos;
          candidate.score += matchScore - 5.0 * (jump - 3); // jump penalty
          candidate.mode = MatcherMode.normal;
          candidates.add(candidate);
        }
      }

      // Candidate 6: Enter OFFSCRIPT mode
      {
        final candidate = hyp.clone();
        candidate.score -= 20.0; // OFFSCRIPT transition cost
        candidate.mode = MatcherMode.offscript;
        candidates.add(candidate);
      }

      // From OFFSCRIPT: re-entry at anchors within ±20 words
      if (hyp.mode == MatcherMode.offscript) {
        final searchStart = max(0, hyp.wordPos - 20);
        final searchEnd = min(totalWords, hyp.wordPos + 20);

        for (final anchorIdx in _anchorIndices) {
          if (anchorIdx < searchStart || anchorIdx >= searchEnd) continue;

          final matchScore = _scoreAnchorReentry(spokenWords, anchorIdx);
          if (matchScore <= 0) continue;

          final candidate = hyp.clone();
          candidate.wordPos = anchorIdx;
          candidate.score += matchScore - 5.0; // cheap re-entry at anchor
          candidate.mode = MatcherMode.normal;
          candidates.add(candidate);
        }

        // Also try re-entry at non-anchor positions with higher cost
        for (var pos = searchStart; pos < searchEnd; pos += 3) {
          if (_isAnchorIndex(pos)) continue; // already handled above
          final matchScore = _scoreMatch(
            spokenWords,
            hyp.wordPos,
            pos,
            hyp.speed,
            elapsed,
            (pos - hyp.wordPos).abs(),
          );
          if (matchScore <= 5) continue;

          final candidate = hyp.clone();
          candidate.wordPos = pos;
          candidate.score += matchScore - 15.0; // expensive non-anchor re-entry
          candidate.mode = MatcherMode.normal;
          candidates.add(candidate);
        }
      }
    }

    // Prune to top-N by score
    candidates.sort((a, b) => b.score.compareTo(a.score));
    _beam = candidates.take(_beamWidth).toList();
  }

  /// Score matching spoken words against script ending near [newPos].
  /// Tries multiple alignment offsets (-1, 0, +1) to tolerate insertions/deletions,
  /// keeping position specificity (different candidates get different scores).
  double _scoreMatch(
    List<String> spokenWords,
    int fromPos,
    int newPos,
    double estimatedSpeed,
    double elapsed,
    int advance,
  ) {
    final totalWords = _sourceWordsNorm.length;
    final spkLen = spokenWords.length;

    // Try 3 alignment offsets to handle insertion/deletion shifts
    var bestAlignScore = -1000.0;
    for (final offsetShift in [-1, 0, 1]) {
      final alignStart = max(0, newPos - spkLen + 1 + offsetShift);
      var score = 0.0;

      var si = 0;
      var wi = alignStart;
      final alignEnd = min(totalWords, alignStart + spkLen + 2);

      while (si < spkLen && wi < alignEnd) {
        final srcNorm = _sourceWordsNorm[wi];
        final spkWord = spokenWords[si];

        if (srcNorm == spkWord) {
          score += 10.0;
          if (_script!.tokens[wi].isAnchor) score += 15.0;
          si++;
          wi++;
        } else if (_metaphoneMatch(wi, spkWord)) {
          score += 7.0;
          if (_script!.tokens[wi].isAnchor) score += 15.0;
          si++;
          wi++;
        } else if (srcNorm.isNotEmpty && spkWord.isNotEmpty &&
                   _editDistance(srcNorm, spkWord) <= 2) {
          score += 5.0;
          si++;
          wi++;
        } else {
          // Try skip 1 source word (reader skipped)
          if (wi + 1 < alignEnd) {
            final nextSrc = _sourceWordsNorm[wi + 1];
            if (nextSrc == spkWord || _metaphoneMatch(wi + 1, spkWord)) {
              wi++;
              continue;
            }
          }
          // Try skip 1 spoken word (ASR insertion)
          if (si + 1 < spkLen) {
            final nextSpk = spokenWords[si + 1];
            if (srcNorm == nextSpk || _metaphoneMatch(wi, nextSpk)) {
              si++;
              continue;
            }
          }
          score -= 2.0; // mismatch penalty
          si++;
          wi++;
        }
      }

      if (score > bestAlignScore) {
        bestAlignScore = score;
      }
    }

    var finalScore = bestAlignScore;

    // Speed prior
    if (estimatedSpeed > 0) {
      final expectedAdvance = estimatedSpeed * elapsed;
      final ratio = advance / max(expectedAdvance, 0.1);
      if (ratio > 0.3 && ratio < 2.0) {
        finalScore += 3.0;
      }
    }

    // Backward penalty
    if (newPos < fromPos) {
      finalScore -= 30.0;
    }

    return finalScore;
  }

  /// Score anchor re-entry: try matching spoken words near the anchor.
  double _scoreAnchorReentry(List<String> spokenWords, int anchorIdx) {
    final start = max(0, anchorIdx - 2);
    return _scoreMatch(spokenWords, start, anchorIdx, 0, 0, 0);
  }

  // ---------------------------------------------------------------------------
  // Mode State Machine
  // ---------------------------------------------------------------------------

  void _updateMode() {
    final conf = _computeConfidence();
    final topMode = _beam.isNotEmpty ? _beam.first.mode : MatcherMode.normal;

    if (topMode == MatcherMode.offscript) {
      // Already offscript via beam
      _uncertainFrames = 0;
      _lostFrames = 0;
      return;
    }

    if (conf > 0.5) {
      // Good confidence → NORMAL
      _uncertainFrames = 0;
      _lostFrames = 0;
      if (_beam.isNotEmpty) _beam.first.mode = MatcherMode.normal;
    } else if (conf < 0.3) {
      _uncertainFrames++;
      if (_uncertainFrames >= 2 && _lostFrames < 5) {
        if (_beam.isNotEmpty) _beam.first.mode = MatcherMode.uncertain;
      }
      if (_uncertainFrames >= 5) {
        _lostFrames++;
        if (_lostFrames >= 3) {
          if (_beam.isNotEmpty) _beam.first.mode = MatcherMode.lost;
        }
        if (_lostFrames >= 8) {
          if (_beam.isNotEmpty) _beam.first.mode = MatcherMode.offscript;
        }
      }
    } else {
      // In between — hold current state, decrement counters slowly
      if (_uncertainFrames > 0) _uncertainFrames--;
    }
  }

  double _computeConfidence() {
    if (_beam.length < 2) return 0.5;
    final topScore = _beam.first.score;
    final secondScore = _beam[1].score;
    // Avoid division by zero; shift scores to be positive
    final t = topScore - secondScore;
    if (t <= 0) return 0.0;
    return t / (t + 10.0); // sigmoid-like normalization
  }

  // ---------------------------------------------------------------------------
  // Display Hysteresis
  // ---------------------------------------------------------------------------

  void _updateDisplayPosition(DateTime now) {
    final currentMode = mode;

    // When UNCERTAIN or LOST, freeze display
    if (currentMode == MatcherMode.uncertain ||
        currentMode == MatcherMode.lost) {
      return;
    }

    // Track stability of internal position
    if (_internalWordPos != _lastStableInternalPos) {
      _lastStableInternalPos = _internalWordPos;
      _internalStableSince = now;
    }

    final stableMs = now.difference(_internalStableSince).inMilliseconds;

    // Only advance display when confidence > 0.6 AND stable for 300ms
    if (confidence > 0.6 && stableMs >= 300) {
      final diff = _internalWordPos - _displayWordPos;

      if (diff > 0) {
        // Forward movement: cap at 5 words per update for smoothness
        final step = min(diff, 5);
        _displayWordPos += step;
      } else if (diff < 0 && currentMode == MatcherMode.normal) {
        // Backward: only in NORMAL mode, and also capped
        // (recovering from OFFSCRIPT animates smoothly)
        final step = min(-diff, 3);
        _displayWordPos -= step;
      }
    } else if (currentMode == MatcherMode.offscript &&
               _internalWordPos != _displayWordPos) {
      // Recovering from OFFSCRIPT: animate toward new position
      if (confidence > 0.5 && stableMs >= 200) {
        final diff = _internalWordPos - _displayWordPos;
        final step = diff > 0 ? min(diff, 3) : -min(-diff, 3);
        _displayWordPos += step;
      }
    }

    // Clamp display position
    _displayWordPos = _displayWordPos.clamp(0, max(0, _sourceWords.length - 1));
  }

  // ---------------------------------------------------------------------------
  // Slow-Path Realignment
  // ---------------------------------------------------------------------------

  void _slowPathRealignment() {
    if (_stableWordBuffer.length < 10) return;

    // Take last 10-15 stable words
    final windowLen = min(15, _stableWordBuffer.length);
    final recentWords = _stableWordBuffer.sublist(
      _stableWordBuffer.length - windowLen,
    );

    // Search in a ±30 word window around current best position
    final searchStart = max(0, _internalWordPos - 30);
    final searchEnd = min(_sourceWords.length, _internalWordPos + 30);

    var bestScore = 0.0;
    var bestPos = _internalWordPos;

    for (var startPos = searchStart; startPos < searchEnd; startPos++) {
      final score = _scoreMatch(
        recentWords, startPos, startPos + recentWords.length ~/ 2,
        0, 0, 0,
      );
      if (score > bestScore) {
        bestScore = score;
        bestPos = startPos + recentWords.length ~/ 2;
      }
    }

    // Only adjust if slow path finds a clearly better position (2x current)
    final currentScore = _beam.isNotEmpty ? _beam.first.score : 0.0;
    if (bestScore > 0 && (currentScore <= 0 || bestScore > currentScore.abs() * 2)) {
      final clampedPos = bestPos.clamp(0, _sourceWords.length - 1);
      // Inject as a strong hypothesis into the beam
      _beam.insert(
        0,
        _Hypothesis(
          wordPos: clampedPos,
          score: _beam.isNotEmpty ? _beam.first.score + bestScore * 0.5 : bestScore,
          mode: MatcherMode.normal,
        ),
      );
      if (_beam.length > _beamWidth) {
        _beam.removeLast();
      }
      _internalWordPos = clampedPos;
    }
  }

  // ---------------------------------------------------------------------------
  // Sentence Tracking (mirrors v1)
  // ---------------------------------------------------------------------------

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
    if (_currentSentence >= script.sentences.length - 1) return;

    final (_, endW) = _sentenceBounds[_currentSentence];
    final (startW, _) = _sentenceBounds[_currentSentence];

    if (startW == endW) {
      _currentSentence++;
      return;
    }
    if (wordIndex >= endW) {
      _currentSentence++;
      return;
    }
    final sentenceWordCount = endW - startW;
    final wordsMatched = (wordIndex - startW).clamp(0, sentenceWordCount);
    if (wordsMatched > sentenceWordCount ~/ 2) {
      _currentSentence++;
    }
  }

  int _wordIndexToCharOffset(int wordIndex) {
    var offset = 0;
    for (var i = 0; i < wordIndex && i < _sourceWords.length; i++) {
      offset += _sourceWords[i].length + 1;
    }
    return offset;
  }

  // ---------------------------------------------------------------------------
  // Matching Helpers
  // ---------------------------------------------------------------------------

  bool _metaphoneMatch(int sourceIdx, String spokenWord) {
    if (sourceIdx >= _sourceMetaphones.length) return false;
    final metaSrc = _sourceMetaphones[sourceIdx];
    if (metaSrc.isEmpty) return false;
    final metaSpk = doubleMetaphone(spokenWord);
    return metaSpk.isNotEmpty && metaSrc == metaSpk;
  }

  bool _isAnchorIndex(int idx) {
    // Binary search would be faster but anchor list is typically small
    return _anchorIndices.contains(idx);
  }

  /// Levenshtein edit distance.
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
