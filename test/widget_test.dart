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

  group('ScriptMatcher', () {
    test('matches spoken words to script position', () {
      final script = Script.fromText(
          'Four score and seven years ago our fathers brought forth');
      final matcher = ScriptMatcher();
      matcher.loadScript(script);

      // Speak the first few words
      var pos = matcher.match('four score and');
      expect(pos, greaterThanOrEqualTo(0));
      expect(pos, lessThan(script.tokens.length));
    });

    test('advances position with more speech', () {
      final script = Script.fromText('one two three four five six seven');
      final matcher = ScriptMatcher();
      matcher.loadScript(script);

      final pos1 = matcher.match('one two');
      final pos2 = matcher.match('three four five');
      expect(pos2, greaterThanOrEqualTo(pos1));
    });

    test('reset returns to start', () {
      final script = Script.fromText('hello world foo bar');
      final matcher = ScriptMatcher();
      matcher.loadScript(script);

      matcher.match('hello world');
      matcher.reset();
      expect(matcher.confirmedPosition, 0);
    });
  });
}
