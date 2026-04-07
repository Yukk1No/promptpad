import 'dart:math';
import '../models/script.dart';

/// Tracks the speaker's position in the script using speech recognition results.
///
/// Inspired by textream's dual-strategy approach:
/// - Sequential forward-only matching (never jumps backward)
/// - Word-level fuzzy match with skip tolerance
/// - Character-level walk with re-sync
/// - Best of both strategies wins
class ScriptMatcher {
  Script? _script;
  int _confirmedPos = 0;
  String _normalizedSource = '';
  int _charOffset = 0;

  int get confirmedPosition => _confirmedPos;

  void loadScript(Script script) {
    _script = script;
    _confirmedPos = 0;
    _charOffset = 0;
    _normalizedSource =
        script.tokens.map((t) => t.normalized).join(' ');
  }

  void reset() {
    _confirmedPos = 0;
    _charOffset = 0;
  }

  void jumpTo(int wordIndex) {
    final script = _script;
    if (script == null) return;
    _confirmedPos = wordIndex.clamp(0, script.tokens.length - 1);
    _recalcCharOffset();
  }

  /// Process a transcript and return the new confirmed word position.
  /// Only moves forward, never backward.
  int match(String transcript) {
    final script = _script;
    if (script == null || script.tokens.isEmpty) return 0;

    final wordResult = _wordLevelMatch(transcript);
    final charResult = _charLevelMatch(transcript);
    final best = max(wordResult, charResult);

    if (best > _confirmedPos) {
      _confirmedPos = min(best, script.tokens.length - 1);
      _recalcCharOffset();
    }

    return _confirmedPos;
  }

  /// Word-level sequential match from current position.
  /// Walks source and spoken words forward with skip tolerance.
  int _wordLevelMatch(String transcript) {
    final script = _script!;
    final spokenWords = _normalizeWords(transcript);
    if (spokenWords.isEmpty) return _confirmedPos;

    var si = _confirmedPos; // source index
    var ri = 0; // spoken (recognition) index
    var lastMatched = _confirmedPos;

    while (si < script.tokens.length && ri < spokenWords.length) {
      final srcWord = script.tokens[si].normalized;
      final spkWord = spokenWords[ri];

      if (srcWord.isEmpty) {
        si++;
        continue;
      }

      if (_isFuzzyMatch(srcWord, spkWord)) {
        // Match found — advance both
        lastMatched = si;
        si++;
        ri++;
        continue;
      }

      // Try skipping up to 3 spoken words (ASR hallucinated extra words)
      var found = false;
      for (var skip = 1; skip <= 3 && ri + skip < spokenWords.length; skip++) {
        if (_isFuzzyMatch(srcWord, spokenWords[ri + skip])) {
          ri += skip + 1;
          lastMatched = si;
          si++;
          found = true;
          break;
        }
      }
      if (found) continue;

      // Try skipping up to 3 source words (user skipped or ASR missed)
      for (var skip = 1;
          skip <= 3 && si + skip < script.tokens.length;
          skip++) {
        if (_isFuzzyMatch(script.tokens[si + skip].normalized, spkWord)) {
          lastMatched = si + skip;
          si = si + skip + 1;
          ri++;
          found = true;
          break;
        }
      }
      if (found) continue;

      // No match — advance spoken pointer only (don't advance source)
      ri++;
    }

    return lastMatched;
  }

  /// Character-level walk with re-sync, operating on normalized text
  /// from the current position forward.
  int _charLevelMatch(String transcript) {
    if (_charOffset >= _normalizedSource.length) return _confirmedPos;

    final spoken = _normalize(transcript);
    if (spoken.isEmpty) return _confirmedPos;

    var si = _charOffset; // source char index
    var ri = 0; // spoken char index
    var lastGoodSi = _charOffset;

    while (si < _normalizedSource.length && ri < spoken.length) {
      final sc = _normalizedSource[si];
      final rc = spoken[ri];

      // Skip whitespace/non-alnum in both
      if (!_isAlnum(sc)) {
        si++;
        continue;
      }
      if (!_isAlnum(rc)) {
        ri++;
        continue;
      }

      if (sc == rc) {
        lastGoodSi = si;
        si++;
        ri++;
        continue;
      }

      // Mismatch — try re-sync
      var synced = false;

      // Skip up to 3 in spoken (ASR inserted extra chars)
      for (var k = 1; k <= 3 && ri + k < spoken.length; k++) {
        if (_isAlnum(spoken[ri + k]) && spoken[ri + k] == sc) {
          ri += k;
          synced = true;
          break;
        }
      }
      if (synced) continue;

      // Skip up to 3 in source (ASR missed chars)
      for (var k = 1; k <= 3 && si + k < _normalizedSource.length; k++) {
        if (_isAlnum(_normalizedSource[si + k]) &&
            _normalizedSource[si + k] == rc) {
          si += k;
          synced = true;
          break;
        }
      }
      if (synced) continue;

      // Neither worked — advance both (substitution)
      lastGoodSi = si;
      si++;
      ri++;
    }

    // Convert char position back to word index
    return _charPosToWordIndex(lastGoodSi);
  }

  /// Fuzzy word match — prefix, containment, shared prefix, edit distance.
  bool _isFuzzyMatch(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;

    // Prefix match (handles "not" ~ "notch", partial ASR results)
    if (a.startsWith(b) || b.startsWith(a)) return true;

    // Substring containment
    if (a.length >= 3 && b.length >= 3) {
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

    // Edit distance tolerance
    final dist = _editDistance(a, b);
    if (shorter <= 4) return dist <= 1; // short words: 1 edit
    if (shorter <= 8) return dist <= 2; // medium: 2 edits
    return dist <= max(a.length, b.length) ~/ 3; // long: up to 1/3
  }

  /// Standard Levenshtein edit distance.
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

  /// Convert a character position in normalizedSource to a word index.
  int _charPosToWordIndex(int charPos) {
    final script = _script!;
    var offset = 0;
    for (var i = 0; i < script.tokens.length; i++) {
      final wordLen = script.tokens[i].normalized.length;
      if (offset + wordLen > charPos) return i;
      offset += wordLen + 1; // +1 for space
    }
    return script.tokens.length - 1;
  }

  /// Recalculate _charOffset from _confirmedPos.
  void _recalcCharOffset() {
    final script = _script!;
    var offset = 0;
    for (var i = 0; i < _confirmedPos && i < script.tokens.length; i++) {
      offset += script.tokens[i].normalized.length + 1;
    }
    _charOffset = offset;
  }

  List<String> _normalizeWords(String text) {
    return text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.toLowerCase().replaceAll(RegExp(r"[^\w']"), ''))
        .where((w) => w.isNotEmpty)
        .toList();
  }

  String _normalize(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '');
  }

  bool _isAlnum(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) || // 0-9
        (code >= 97 && code <= 122); // a-z
  }
}
