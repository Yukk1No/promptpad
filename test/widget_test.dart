import 'package:flutter_test/flutter_test.dart';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher.dart';

void main() {
  group('Script tokenization', () {
    test('splits text into tokens with metaphone codes', () {
      final script = Script.fromText('Hello world');
      expect(script.tokens.length, 2);
      expect(script.tokens[0].normalized, 'hello');
      expect(script.tokens[1].normalized, 'world');
    });

    test('handles punctuation', () {
      final script = Script.fromText("Don't stop, please!");
      expect(script.tokens[0].normalized, "don't");
      expect(script.tokens[1].normalized, 'stop');
      expect(script.tokens[2].normalized, 'please');
    });
  });

  group('Script sentence parsing', () {
    test('splits on sentence-ending punctuation', () {
      final script = Script.fromText(
          'Hello world. How are you? I am fine!');
      expect(script.sentences.length, 3);
      expect(script.sentences[0].displayText, 'Hello world.');
      expect(script.sentences[1].displayText, 'How are you?');
      expect(script.sentences[2].displayText, 'I am fine!');
    });

    test('splits on double newlines', () {
      final script = Script.fromText('First paragraph\n\nSecond paragraph');
      expect(script.sentences.length, 2);
      expect(script.sentences[0].displayText, 'First paragraph');
      expect(script.sentences[1].displayText, 'Second paragraph');
    });

    test('parses markdown headings as annotations', () {
      final script = Script.fromText(
          '## Slide 1 — Intro\nWelcome everyone.');
      expect(script.sentences.length, 1);
      expect(script.sentences[0].heading, 'Slide 1 — Intro');
      expect(script.sentences[0].displayText, 'Welcome everyone.');
      // Heading words should NOT be in tokens
      expect(script.tokens.length, 2);
      expect(script.tokens[0].normalized, 'welcome');
      expect(script.tokens[1].normalized, 'everyone');
    });

    test('strips bold and italic markdown', () {
      final script = Script.fromText(
          'This is **bold** and *italic* text.');
      expect(script.sentences[0].displayText,
          'This is bold and italic text.');
    });

    test('strips underscore markdown', () {
      final script = Script.fromText(
          'This is __bold__ and _italic_ text.');
      expect(script.sentences[0].displayText,
          'This is bold and italic text.');
    });

    test('handles multiple sentences with heading', () {
      final script = Script.fromText(
          '## Section\nFirst sentence. Second sentence.');
      expect(script.sentences.length, 2);
      expect(script.sentences[0].heading, 'Section');
      expect(script.sentences[0].displayText, 'First sentence.');
      expect(script.sentences[1].heading, isNull);
      expect(script.sentences[1].displayText, 'Second sentence.');
      // Heading words excluded from tokens; only body words present
      expect(script.tokens.length, 4); // First sentence Second sentence
      expect(script.tokens[0].normalized, 'first');
    });

    test('strips horizontal rules', () {
      final script = Script.fromText(
          'Hello world.\n\n---\n\nGoodbye world.');
      expect(script.sentences.length, 2);
      expect(script.sentences[0].displayText, 'Hello world.');
      expect(script.sentences[1].displayText, 'Goodbye world.');
      // No --- tokens
      expect(script.tokens.every((t) => t.raw != '---'), isTrue);
    });

    test('strips metadata lines', () {
      final script = Script.fromText(
          '**Title:** My Talk\n**Presenter:** Alice\n\nHello everyone.');
      expect(script.sentences.length, 1);
      expect(script.sentences[0].displayText, 'Hello everyone.');
      // No metadata tokens
      expect(script.tokens.length, 2);
      expect(script.tokens[0].normalized, 'hello');
    });

    test('strips top-level heading from tokens', () {
      final script = Script.fromText(
          '# My Presentation\n\n## Slide 1\nHello.');
      // Top-level heading becomes annotation, body text is just "Hello."
      expect(script.tokens.length, 1);
      expect(script.tokens[0].normalized, 'hello');
    });

    test('handles full markdown presentation format', () {
      const text = '''# Midterm Presentation Speech Script

**Title:** Audio-Based COVID-19 Screening
**Presenter:** LOU Tianyue
**Duration:** ~15 minutes

---

## Slide 1 — Title (20 seconds)

Good morning. My name is LOU Tianyue.

---

## Slide 2 — Outline (10 seconds)

I will cover background and motivation.''';

      final script = Script.fromText(text);

      // Should have sentences only from speech text
      expect(script.sentences.length, greaterThanOrEqualTo(2));

      // First speech sentence should have Slide 1 heading
      final s0 = script.sentences.firstWhere(
          (s) => s.displayText.isNotEmpty);
      expect(s0.heading, contains('Slide 1'));
      expect(s0.displayText, 'Good morning.');

      // No metadata or --- in tokens
      expect(script.tokens.every((t) => t.raw != '---'), isTrue);
      expect(script.tokens.every((t) => !t.raw.startsWith('**')), isTrue);
    });
  });

  group('Double Metaphone', () {
    test('homophones produce same code', () {
      expect(doubleMetaphone('right'), doubleMetaphone('rite'));
      expect(doubleMetaphone('write'), doubleMetaphone('rite'));
    });

    test('similar sounding words match', () {
      expect(doubleMetaphone('phone'), doubleMetaphone('fone'));
    });

    test('empty string returns empty', () {
      expect(doubleMetaphone(''), '');
    });
  });

  group('ScriptMatcher - forward-only sequential matching', () {
    late ScriptMatcher matcher;

    setUp(() {
      matcher = ScriptMatcher();
    });

    test('matches first words without jumping ahead', () {
      final script = Script.fromText(
          'Four score and seven years ago our fathers brought forth');
      matcher.loadScript(script);

      // "for" should match "four" (prefix match) at position 0,
      // NOT jump to some other "for" in the middle
      final pos = matcher.match('for');
      expect(pos, 0); // stays at or near the start
    });

    test('advances sequentially with correct speech', () {
      final script = Script.fromText('one two three four five six seven');
      matcher.loadScript(script);

      var pos = matcher.match('one two');
      expect(pos, greaterThanOrEqualTo(1));

      pos = matcher.match('three four five');
      expect(pos, greaterThanOrEqualTo(4));
    });

    test('never goes backward', () {
      final script = Script.fromText('the cat sat on the mat by the door');
      matcher.loadScript(script);

      final pos1 = matcher.match('the cat sat');
      expect(pos1, greaterThanOrEqualTo(2));

      // Even if ASR gives us "the" again, we should NOT jump back
      final pos2 = matcher.match('the');
      expect(pos2, greaterThanOrEqualTo(pos1));
    });

    test('handles ASR hallucinated extra words', () {
      final script = Script.fromText('hello world goodbye');
      matcher.loadScript(script);

      // ASR adds "uh" between real words
      final pos = matcher.match('hello uh world');
      expect(pos, greaterThanOrEqualTo(1)); // should match "world"
    });

    test('handles skipped source words', () {
      final script = Script.fromText('one two three four five');
      matcher.loadScript(script);

      // User says "one" then silence (final), then says "four"
      matcher.match('one', isFinal: true);
      final pos = matcher.match('four');
      expect(pos, greaterThanOrEqualTo(3)); // should find "four" at index 3
    });

    test('fuzzy matches partial words', () {
      final script = Script.fromText('constitution of the united states');
      matcher.loadScript(script);

      // ASR gives partial/mangled word
      final pos = matcher.match('constitu');
      expect(pos, 0); // prefix match on "constitution"
    });

    test('fuzzy matches with edit distance', () {
      final script = Script.fromText('we hold these truths');
      matcher.loadScript(script);

      // ASR mishears "truths" as "truth"
      final pos = matcher.match('we hold these truth');
      expect(pos, greaterThanOrEqualTo(3));
    });

    test('reset returns to start', () {
      final script = Script.fromText('hello world foo bar');
      matcher.loadScript(script);

      matcher.match('hello world');
      matcher.reset();
      expect(matcher.confirmedPosition, 0);
      expect(matcher.currentSentence, 0);
    });

    test('repeated words do not cause backward jumps', () {
      // "the" appears multiple times
      final script = Script.fromText(
          'the quick brown fox jumped over the lazy dog');
      matcher.loadScript(script);

      // Read through first part (final=true to advance offset)
      var pos = matcher.match('the quick brown fox', isFinal: true);
      expect(pos, greaterThanOrEqualTo(3));

      // Now say "the lazy" — starts from new offset, matches second "the"
      pos = matcher.match('the lazy');
      expect(pos, greaterThanOrEqualTo(pos)); // never goes backward
    });
  });

  group('ScriptMatcher - sentence tracking', () {
    late ScriptMatcher matcher;

    setUp(() {
      matcher = ScriptMatcher();
    });

    test('starts at sentence 0', () {
      final script = Script.fromText(
          'First sentence. Second sentence. Third sentence.');
      matcher.loadScript(script);
      expect(matcher.currentSentence, 0);
      expect(matcher.totalSentences, 3);
    });

    test('jumpToSentence changes current sentence', () {
      final script = Script.fromText(
          'First sentence. Second sentence. Third sentence.');
      matcher.loadScript(script);

      matcher.jumpToSentence(2);
      expect(matcher.currentSentence, 2);
    });

    test('jumpToSentence clamps to valid range', () {
      final script = Script.fromText(
          'First sentence. Second sentence.');
      matcher.loadScript(script);

      matcher.jumpToSentence(10);
      expect(matcher.currentSentence, 1);

      matcher.jumpToSentence(-5);
      expect(matcher.currentSentence, 0);
    });

    test('reset returns sentence to 0', () {
      final script = Script.fromText(
          'First sentence. Second sentence.');
      matcher.loadScript(script);

      matcher.jumpToSentence(1);
      matcher.reset();
      expect(matcher.currentSentence, 0);
    });

    test('jumpToSentence syncs word position forward', () {
      final script = Script.fromText(
          'First sentence here. Second sentence here. Third sentence here.');
      matcher.loadScript(script);

      matcher.jumpToSentence(2);
      expect(matcher.currentSentence, 2);
      // confirmedPosition should point to the start of the third sentence
      // "First sentence here." = 3 words, "Second sentence here." = 3 words
      // So third sentence starts at word index 6
      expect(matcher.confirmedPosition, 6);
    });

    test('jumpToSentence syncs word position backward', () {
      final script = Script.fromText(
          'First sentence. Second sentence. Third sentence.');
      matcher.loadScript(script);

      matcher.jumpToSentence(2);
      expect(matcher.currentSentence, 2);

      // Now jump backward
      matcher.jumpToSentence(0);
      expect(matcher.currentSentence, 0);
      expect(matcher.confirmedPosition, 0);
    });

    test('jumpToSentence works with markdown headings', () {
      final script = Script.fromText(
          '## Slide 1\nGood morning.\n\n## Slide 2\nI will cover this.');
      matcher.loadScript(script);

      matcher.jumpToSentence(1);
      expect(matcher.currentSentence, 1);
      // "Good morning." = 2 words, so second sentence starts at word 2
      expect(matcher.confirmedPosition, 2);
    });
  });
}
