// Unit tests for V4's confidence-aware post-reset budget gate.
//
// V4 = V3 + a per-event confidence gate that suppresses _resyncMatch on
// partials whose mean ASR confidence is below 0.6 inside the post-reset
// recovery window. The benchmark harness verifies this end-to-end on
// JFK Vosk + cafe-noise sweep; these unit tests pin the gate's
// observable contract so future matcher work cannot regress it
// silently.
//
// Test script structure: 3 sentences. Sentences 0/1 contain only "xyz"
// tokens that fuzzy-match nothing the spoken text below ever produces;
// sentence 2 ("mike november oscar papa quebec.") is the only place
// the test transcripts can anchor. This forces the primary char/word
// matchers to return 0 on every test partial, leaving _resyncMatch as
// the only path that can advance _recognizedCharCount — which is
// exactly the path V4's gate controls.
import 'package:flutter_test/flutter_test.dart';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher_v4.dart';

void main() {
  // 15 'xyz' filler tokens (3 sentences of 5) before the target sentence so
  // _tailMatch's +15-word search window from confirmedPosition=0 cannot
  // reach 'mike' at token 15. That isolation matters: tail-match runs in
  // every match() call regardless of the gate, and would otherwise jump
  // the matcher into sentence 3 before _resyncMatch is consulted.
  const scriptText =
      'xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. '
      'mike november oscar papa quebec.';

  group('V4 confidence gate (issue #11)', () {
    test('low-conf partial in post-reset window suppresses resync', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV4()..loadScript(script);

      matcher.onSessionReset(); // opens 8-partial recovery budget

      // Two non-matching partials accumulate _staleCount to 2.
      matcher
        ..setNextEventConfidence(0.5)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.5)
        ..match('uhh ohh', isFinal: false);

      // A partial that, with high confidence, would resync to sentence 2.
      // Confidence 0.5 is below the 0.6 gate ⇒ recovery suppressed.
      matcher
        ..setNextEventConfidence(0.5)
        ..match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, 0,
          reason: 'gate must block _resyncMatch on low-conf partial '
              'inside the post-reset window');
    });

    test('high-conf partial in post-reset window allows resync', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV4()..loadScript(script);

      matcher.onSessionReset();

      matcher
        ..setNextEventConfidence(0.9)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.9)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.9)
        ..match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'gate must NOT block _resyncMatch when conf ≥ 0.6; '
              'matcher should jump into sentence 3 (token ≥15)');
    });

    test('default-trust: missing setNextEventConfidence treats as 1.0', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV4()..loadScript(script);

      matcher.onSessionReset();

      // Never call setNextEventConfidence — V4 must default to 1.0 so
      // legacy hosts and matchers without the schema take the V3 path.
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'default-trust contract: no host call ⇒ behave as V3');
    });

    test('confidence does not carry over after consumption', () {
      // After a low-conf call consumes the stored value, the next call
      // without setNextEventConfidence must revert to 1.0 — otherwise a
      // single noisy partial would silently degrade every later partial.
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV4()..loadScript(script);

      matcher.onSessionReset();

      matcher
        ..setNextEventConfidence(0.5)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.5)
        ..match('uhh ohh', isFinal: false);

      // Skip setNextEventConfidence — V4 must use the default 1.0,
      // not the prior 0.5.
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'stale low-conf value must NOT carry across match() calls');
    });

    test('low conf outside post-reset window has no effect', () {
      // Without onSessionReset, the budget is 0 ⇒ inPostResetWindow is
      // false ⇒ gate cannot fire regardless of confidence. V3's existing
      // canRecover branch already requires inPostResetWindow for partial
      // recovery, so V4 is byte-identical to V3 here.
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV4()..loadScript(script);

      // No onSessionReset call.
      matcher
        ..setNextEventConfidence(0.5)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.5)
        ..match('uhh ohh', isFinal: false);
      matcher
        ..setNextEventConfidence(0.5)
        ..match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, 0,
          reason: 'partial recovery is closed without onSessionReset, '
              'regardless of confidence');
    });

    test('isFinal recovery is unaffected by gate', () {
      // The gate only suppresses recovery on partials (!isFinal). The
      // V2 isFinal recovery path (stale ≥ _staleThreshold + isFinal)
      // must still fire even when confidence is below the threshold,
      // otherwise V4 would lose ground V2 already held.
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV4()..loadScript(script);

      matcher.onSessionReset();

      // 1-word partials so the partial-recovery branch's
      // `spokenWords.length >= 2` filter doesn't fire — we want stale
      // to climb past _staleThreshold (=4) without resync running.
      for (var i = 0; i < 5; i++) {
        matcher
          ..setNextEventConfidence(0.3)
          ..match('uh', isFinal: false);
      }

      matcher
        ..setNextEventConfidence(0.3)
        ..match('mike november oscar papa quebec', isFinal: true);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'isFinal recovery must fire even when conf < 0.6');
    });
  });
}
