/// A parsed script with sentence-level and word-level structure.
class Script {
  final String raw;
  final List<ScriptToken> tokens;
  final List<Sentence> sentences;

  Script({required this.raw, required this.tokens, required this.sentences});

  /// Shared normalization used by both Script and ScriptMatcher.
  static String normalizeWord(String word) {
    return word
        .toLowerCase()
        .replaceAll(RegExp(r"[^\w']"), '')
        .replaceAll(RegExp(r"^'+|'+$"), '');
  }

  factory Script.fromText(String text) {
    // Pre-process: remove markdown heading lines so heading words
    // do NOT become tokens. Headings only live in Sentence.heading.
    final strippedText = text
        .split('\n')
        .where((line) => !RegExp(r'^\s*#{1,6}\s+').hasMatch(line))
        .join('\n');

    final words = strippedText.split(RegExp(r'\s+'));
    final tokens = <ScriptToken>[];
    // Walk through strippedText with an explicit offset counter
    var offset = 0;

    for (final word in words) {
      if (word.isEmpty) continue;
      // Find the word starting from the current offset
      final start = strippedText.indexOf(word, offset);
      if (start < 0) continue;
      final normalized = normalizeWord(word);
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

    final sentences = _parseSentences(text);
    return Script(raw: text, tokens: tokens, sentences: sentences);
  }

  /// Parse text into sentences, splitting on sentence-ending punctuation
  /// or double-newlines. Markdown headings become section annotations.
  static List<Sentence> _parseSentences(String text) {
    final sentences = <Sentence>[];

    // Split on double-newline first to get paragraphs
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    String? pendingHeading;

    for (final paragraph in paragraphs) {
      final trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;

      // Split paragraph into lines to detect markdown headings
      final lines = trimmed.split('\n');
      final buffer = StringBuffer();

      for (final line in lines) {
        final trimmedLine = line.trim();

        // Check for markdown heading
        final headingMatch = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(trimmedLine);
        if (headingMatch != null) {
          // Flush any buffered text as sentences before setting heading
          if (buffer.isNotEmpty) {
            _splitIntoSentences(buffer.toString(), sentences, pendingHeading);
            pendingHeading = null;
            buffer.clear();
          }
          pendingHeading = headingMatch.group(2)!.trim();
          continue;
        }

        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(trimmedLine);
      }

      if (buffer.isNotEmpty) {
        _splitIntoSentences(buffer.toString(), sentences, pendingHeading);
        pendingHeading = null;
      }
    }

    // If there's a trailing heading with no text after it, add it as empty sentence
    if (pendingHeading != null) {
      sentences.add(Sentence(
        index: sentences.length,
        rawText: '',
        displayText: '',
        heading: pendingHeading,
      ));
    }

    return sentences;
  }

  /// Split a block of text into sentences on `.` `?` `!`
  static void _splitIntoSentences(
    String text,
    List<Sentence> sentences,
    String? heading,
  ) {
    // Split on sentence-ending punctuation, keeping the punctuation
    final parts = text.split(RegExp(r'(?<=[.!?])\s+'));
    bool isFirst = true;

    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;

      final displayText = stripMarkdown(trimmed);

      sentences.add(Sentence(
        index: sentences.length,
        rawText: trimmed,
        displayText: displayText,
        heading: isFirst ? heading : null,
      ));
      isFirst = false;
    }
  }

  /// Strip markdown bold/italic markers for display.
  static String stripMarkdown(String text) {
    var result = text;
    // Bold+italic (*** or ___)
    result = result.replaceAllMapped(
        RegExp(r'\*\*\*(.+?)\*\*\*'), (m) => m.group(1)!);
    result = result.replaceAllMapped(
        RegExp(r'___(.+?)___'), (m) => m.group(1)!);
    // Bold (** or __)
    result = result.replaceAllMapped(
        RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!);
    result = result.replaceAllMapped(
        RegExp(r'__(.+?)__'), (m) => m.group(1)!);
    // Italic (* or _)
    result = result.replaceAllMapped(
        RegExp(r'\*(.+?)\*'), (m) => m.group(1)!);
    result = result.replaceAllMapped(
        RegExp(r'_(.+?)_'), (m) => m.group(1)!);
    return result;
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

/// A sentence in the script, with optional markdown heading annotation.
class Sentence {
  final int index;
  final String rawText;
  final String displayText;
  final String? heading;

  const Sentence({
    required this.index,
    required this.rawText,
    required this.displayText,
    this.heading,
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
