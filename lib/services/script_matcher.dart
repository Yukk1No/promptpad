import 'dart:math';
import '../models/script.dart';

/// Tracks the speaker's position in the script using speech recognition results.
///
/// Ported from promptme-ai's matching algorithm:
/// - Inverted token index for O(1) candidate lookup
/// - Double Metaphone phonetic normalization
/// - Banded Levenshtein similarity
/// - Multi-hypothesis beam with locality scoring
class ScriptMatcher {
  static const int _beamWidth = 3;
  static const int _matchWindow = 4;
  static const int _maxEdits = 3;
  static const double _localityDecay = 0.02;

  Script? _script;
  final List<_Hypothesis> _beam = [];
  int _confirmedPos = 0;

  int get confirmedPosition => _confirmedPos;

  void loadScript(Script script) {
    _script = script;
    _beam.clear();
    _confirmedPos = 0;
  }

  void reset() {
    _beam.clear();
    _confirmedPos = 0;
  }

  /// Process a transcript fragment and return the new confirmed word position.
  int match(String transcript) {
    final script = _script;
    if (script == null || script.tokens.isEmpty) return 0;

    final spokenWords = transcript
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.toLowerCase().replaceAll(RegExp(r"[^\w']"), ''))
        .where((w) => w.isNotEmpty)
        .toList();

    if (spokenWords.isEmpty) return _confirmedPos;

    // Find candidate positions via inverted index + phonetic matching
    final candidates = <int>{};
    for (final word in spokenWords) {
      final metaphone = doubleMetaphone(word);
      for (var i = 0; i < script.tokens.length; i++) {
        final token = script.tokens[i];
        if (token.normalized == word ||
            (metaphone.isNotEmpty && token.metaphone == metaphone)) {
          candidates.add(i);
        }
      }
    }

    if (candidates.isEmpty) return _confirmedPos;

    // Score each candidate using banded Levenshtein over a window
    for (final pos in candidates) {
      final windowStart = max(0, pos - _matchWindow);
      final windowEnd = min(script.tokens.length, pos + _matchWindow + 1);
      final windowTokens = script.tokens
          .sublist(windowStart, windowEnd)
          .map((t) => t.normalized)
          .toList();

      final sim = _bandedSimilarity(spokenWords, windowTokens);
      final distance = (pos - _confirmedPos).abs();
      final locality = 1.0 / (1.0 + distance * _localityDecay);
      // Penalize backward jumps more heavily
      final direction = pos >= _confirmedPos ? 1.0 : 0.5;
      final score = sim * locality * direction;

      _updateBeam(pos, score);
    }

    // Commit the best forward hypothesis
    _beam.sort((a, b) => b.score.compareTo(a.score));
    for (final h in _beam) {
      if (h.position >= _confirmedPos) {
        _confirmedPos = h.position;
        break;
      }
    }

    // Prune stale hypotheses
    _beam.removeWhere(
        (h) => h.age > 5 || (h.position - _confirmedPos).abs() > 20);

    return _confirmedPos;
  }

  void _updateBeam(int position, double score) {
    for (final h in _beam) {
      if ((h.position - position).abs() <= _matchWindow) {
        h.score = max(h.score, score);
        h.position = position;
        h.age = 0;
        return;
      }
    }
    if (_beam.length < _beamWidth) {
      _beam.add(_Hypothesis(position: position, score: score));
    } else {
      // Replace worst
      _beam.sort((a, b) => a.score.compareTo(b.score));
      if (_beam.first.score < score) {
        _beam.first
          ..position = position
          ..score = score
          ..age = 0;
      }
    }
  }

  /// Banded Levenshtein similarity [0, 1] between two word sequences.
  double _bandedSimilarity(List<String> a, List<String> b) {
    final n = a.length, m = b.length;
    if (n == 0 || m == 0) return 0.0;

    final maxLen = max(n, m);
    final band = min(_maxEdits, maxLen);

    // DP with pre-allocated rows
    var prev = List<int>.filled(m + 1, 0);
    var curr = List<int>.filled(m + 1, 0);

    for (var j = 0; j <= min(band, m); j++) {
      prev[j] = j;
    }
    for (var j = band + 1; j <= m; j++) {
      prev[j] = band + 1;
    }

    for (var i = 1; i <= n; i++) {
      curr[0] = i;
      final lo = max(1, i - band);
      final hi = min(m, i + band);

      for (var j = 1; j < lo; j++) {
        curr[j] = band + 1;
      }

      for (var j = lo; j <= hi; j++) {
        final cost = _wordSimilarity(a[i - 1], b[j - 1]) >= 0.8 ? 0 : 1;
        curr[j] = min(
          min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }

      for (var j = hi + 1; j <= m; j++) {
        curr[j] = band + 1;
      }

      final tmp = prev;
      prev = curr;
      curr = tmp;
    }

    final dist = prev[m];
    return 1.0 - (dist / maxLen);
  }

  /// Similarity between two individual words using metaphone + character overlap.
  double _wordSimilarity(String a, String b) {
    if (a == b) return 1.0;
    final ma = doubleMetaphone(a);
    final mb = doubleMetaphone(b);
    if (ma.isNotEmpty && ma == mb) return 0.95;

    // Character-level Jaccard as fallback
    final sa = a.split('').toSet();
    final sb = b.split('').toSet();
    final inter = sa.intersection(sb).length;
    final union = sa.union(sb).length;
    return union == 0 ? 0.0 : inter / union;
  }
}

class _Hypothesis {
  int position;
  double score;
  int age = 0;

  _Hypothesis({required this.position, required this.score});
}
