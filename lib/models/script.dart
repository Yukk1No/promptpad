/// A tokenized script ready for matching.
class Script {
  final String raw;
  final List<ScriptToken> tokens;

  Script({required this.raw, required this.tokens});

  factory Script.fromText(String text) {
    final words = text.split(RegExp(r'\s+'));
    final tokens = <ScriptToken>[];
    var offset = 0;

    for (final word in words) {
      if (word.isEmpty) continue;
      final start = text.indexOf(word, offset);
      final normalized = _normalize(word);
      final metaphone = doubleMetaphone(normalized);
      tokens.add(ScriptToken(
        index: tokens.length,
        raw: word,
        normalized: normalized,
        metaphone: metaphone,
        charOffset: start,
      ));
      offset = start + word.length;
    }
    return Script(raw: text, tokens: tokens);
  }

  static String _normalize(String word) {
    return word
        .toLowerCase()
        .replaceAll(RegExp(r"[^\w']"), '')
        .replaceAll(RegExp(r"^'+|'+$"), '');
  }
}

class ScriptToken {
  final int index;
  final String raw;
  final String normalized;
  final String metaphone;
  final int charOffset;

  const ScriptToken({
    required this.index,
    required this.raw,
    required this.normalized,
    required this.metaphone,
    required this.charOffset,
  });
}

/// Simplified Double Metaphone — maps words to consonant skeletons
/// so homophones (right/write/rite) collapse to the same code.
String doubleMetaphone(String word) {
  if (word.isEmpty) return '';
  final s = word.toUpperCase();
  final buf = StringBuffer();
  var i = 0;

  // Skip silent initial letters
  if (s.length > 1) {
    const silentPrefixes = ['GN', 'KN', 'PN', 'AE', 'WR'];
    for (final p in silentPrefixes) {
      if (s.startsWith(p)) {
        i = 1;
        break;
      }
    }
  }

  while (i < s.length && buf.length < 4) {
    final c = s[i];
    final next = i + 1 < s.length ? s[i + 1] : '';

    switch (c) {
      case 'A' || 'E' || 'I' || 'O' || 'U':
        if (i == 0) buf.write('A');
        i++;
      case 'B':
        buf.write('P');
        i += (next == 'B') ? 2 : 1;
      case 'C':
        if (next == 'H') {
          buf.write('X');
          i += 2;
        } else if ('EIY'.contains(next)) {
          buf.write('S');
          i += 2;
        } else {
          buf.write('K');
          i += (next == 'C') ? 2 : 1;
        }
      case 'D':
        if (next == 'G' && i + 2 < s.length && 'EIY'.contains(s[i + 2])) {
          buf.write('J');
          i += 3;
        } else {
          buf.write('T');
          i += (next == 'D') ? 2 : 1;
        }
      case 'F':
        buf.write('F');
        i += (next == 'F') ? 2 : 1;
      case 'G':
        if (next == 'H') {
          // GH silent before consonant
          i += 2;
        } else if (next == '' || 'EIY'.contains(next)) {
          buf.write('J');
          i += 1;
        } else {
          buf.write('K');
          i += (next == 'G') ? 2 : 1;
        }
      case 'H':
        if ('AEIOU'.contains(next)) {
          buf.write('H');
          i += 2;
        } else {
          i++;
        }
      case 'J':
        buf.write('J');
        i += (next == 'J') ? 2 : 1;
      case 'K':
        buf.write('K');
        i += (next == 'K') ? 2 : 1;
      case 'L':
        buf.write('L');
        i += (next == 'L') ? 2 : 1;
      case 'M':
        buf.write('M');
        i += (next == 'M') ? 2 : 1;
      case 'N':
        buf.write('N');
        i += (next == 'N') ? 2 : 1;
      case 'P':
        if (next == 'H') {
          buf.write('F');
          i += 2;
        } else {
          buf.write('P');
          i += (next == 'P') ? 2 : 1;
        }
      case 'Q':
        buf.write('K');
        i += (next == 'Q') ? 2 : 1;
      case 'R':
        buf.write('R');
        i += (next == 'R') ? 2 : 1;
      case 'S':
        if (next == 'H') {
          buf.write('X');
          i += 2;
        } else if (next == 'I' && i + 2 < s.length && 'AO'.contains(s[i + 2])) {
          buf.write('X');
          i += 3;
        } else {
          buf.write('S');
          i += (next == 'S') ? 2 : 1;
        }
      case 'T':
        if (next == 'H') {
          buf.write('0'); // theta
          i += 2;
        } else if (next == 'I' && i + 2 < s.length && 'AO'.contains(s[i + 2])) {
          buf.write('X');
          i += 3;
        } else {
          buf.write('T');
          i += (next == 'T') ? 2 : 1;
        }
      case 'V':
        buf.write('F');
        i += (next == 'V') ? 2 : 1;
      case 'W' || 'Y':
        if ('AEIOU'.contains(next)) {
          buf.write(c);
          i += 2;
        } else {
          i++;
        }
      case 'X':
        buf.write('KS');
        i += (next == 'X') ? 2 : 1;
      case 'Z':
        buf.write('S');
        i += (next == 'Z') ? 2 : 1;
      default:
        i++;
    }
  }
  return buf.toString();
}
