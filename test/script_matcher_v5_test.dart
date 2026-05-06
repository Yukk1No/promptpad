// Unit tests for V5's discrimination-gated _resyncMatch.
//
// V5 = V3 + a gate that requires the best resync candidate to be
// clearly ahead of the runner-up (best_score >= 1.5x second_best_score)
// before committing the jump. The mechanism is production-safe — it
// doesn't rely on the per-event mean_confidence signal that iOS
// speech_to_text never reports.
import 'package:flutter_test/flutter_test.dart';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher_v5.dart';

void main() {
  group('V5 discrimination gate (clean: clear winner case)', () {
    // 15 'xyz' filler tokens (3 sentences × 5) before the target so
    // _tailMatch can't reach. Only sentence 3 contains words the test
    // transcript can anchor on, so resync's other candidates score 0
    // and the ratio is effectively infinite (secondBestScore=0).
    const scriptText =
        'xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. '
        'mike november oscar papa quebec.';

    test('clear winner allows resync (V3-equivalent on clean ASR)', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.onSessionReset();

      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'unique-target resync must commit (no peers compete)');
    });

    test('without onSessionReset, partials cannot fire recovery', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, 0,
          reason: 'closed budget should suppress partial recovery '
              '(inherits from V3)');
    });

    test('isFinal recovery is unaffected by gate', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.onSessionReset();
      for (var i = 0; i < 5; i++) {
        matcher.match('uh', isFinal: false);
      }
      matcher.match('mike november oscar papa quebec', isFinal: true);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'isFinal recovery should fire — same V2/V3/V4 path');
    });

    test('does not teleport user position across the boundary', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.match('xyz xyz xyz', isFinal: true);
      final beforeReset = matcher.confirmedPosition;

      matcher.onSessionReset();

      expect(matcher.confirmedPosition, beforeReset);
    });
  });

  group('V5 discrimination gate (noisy: ambiguous candidates case)', () {
    // Three near-identical target sentences after the filler. Spoken
    // text "alpha bravo charlie" matches all three sentences equally
    // (only the trailing distinguisher word differs), so the resync
    // best/second-best ratio collapses to roughly 1:1 and the
    // discrimination gate must suppress the jump — V3 would have
    // committed to one of them at random.
    const ambiguousScript =
        'xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. '
        'alpha bravo charlie delta. '
        'alpha bravo charlie echo. '
        'alpha bravo charlie foxtrot.';

    test('ambiguous candidates suppress resync (V5 win condition)', () {
      final script = Script.fromText(ambiguousScript);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.onSessionReset();

      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      // 'alpha bravo charlie' matches sentences 3, 4, 5 with the same
      // 19-character prefix. Discrimination ratio ~ 1.0 < 1.5 ⇒
      // resync should suppress. Note: tail-trim drops the last spoken
      // word on partials with >=3 words, so resync sees only
      // ['alpha','bravo'] — both matching all three sentences equally.
      matcher.match('alpha bravo charlie', isFinal: false);

      expect(matcher.confirmedPosition, 0,
          reason: 'V5 gate must suppress ambiguous resync — V3 would '
              'have committed to one of the three equally-scoring '
              'sentences');
    });

    test('isFinal does not commit to ambiguous candidates either', () {
      // The discrimination gate fires regardless of isFinal: committing
      // to one of three equally-scoring sentences is wrong whether the
      // signal came from a partial or a final. The matcher stays put;
      // primary char/word match advances naturally as more correct
      // content arrives in subsequent sessions. This is a deliberate
      // departure from V2/V3/V4 (which commit on isFinal regardless)
      // and is what makes V5 production-safe under iOS partial
      // confidence == 0.0.
      final script = Script.fromText(ambiguousScript);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.onSessionReset();
      for (var i = 0; i < 5; i++) {
        matcher.match('uh', isFinal: false);
      }
      matcher.match('alpha bravo charlie', isFinal: true);

      expect(matcher.confirmedPosition, 0,
          reason: 'V5 gate must suppress ambiguous resync even on isFinal');
    });
  });

  group('V5 ignores per-event confidence', () {
    // V5 should be byte-identical regardless of setNextEventConfidence
    // calls — the discrimination signal is internal to the matcher.
    const scriptText =
        'xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. '
        'mike november oscar papa quebec.';

    test('low confidence does not affect outcome', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV5()..loadScript(script);

      matcher.onSessionReset();
      matcher
        ..setNextEventConfidence(0.1)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.1)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.1)
        ..match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'V5 must ignore confidence — low values do not gate it');
    });
  });
}
