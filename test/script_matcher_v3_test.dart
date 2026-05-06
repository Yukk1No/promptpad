// Unit tests for V3's onSessionReset hook + V3.1 setNoisyEnvironmentMode
// toggle. The benchmark sweep covers integration metrics; these tests
// pin the observable contract at the matcher API surface.
import 'package:flutter_test/flutter_test.dart';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher_v3.dart';

void main() {
  // Same fixture as script_matcher_v4_test.dart: 15 'xyz' filler tokens
  // before the target sentence so _tailMatch's +15-word window from
  // confirmedPosition=0 cannot reach 'mike' at token 15. Only
  // _resyncMatch (post-reset budget path) can advance the position.
  const scriptText =
      'xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. xyz xyz xyz xyz xyz. '
      'mike november oscar papa quebec.';

  group('V3 onSessionReset (issue #11)', () {
    test('opens budget that lets _resyncMatch fire on partials', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV3()..loadScript(script);

      matcher.onSessionReset();

      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15),
          reason: 'post-reset partial-recovery budget should let resync '
              'fire on partials and jump into sentence 3 (token ≥15)');
    });

    test('without onSessionReset, partials cannot fire recovery', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV3()..loadScript(script);

      // No onSessionReset ⇒ budget=0 ⇒ V2-equivalent behavior on partials.
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, 0,
          reason: 'closed budget should suppress partial recovery');
    });

    test('does not teleport user position across the boundary', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV3()..loadScript(script);

      matcher.match('xyz xyz xyz', isFinal: true);
      final beforeReset = matcher.confirmedPosition;

      matcher.onSessionReset();

      expect(matcher.confirmedPosition, beforeReset,
          reason: 'onSessionReset must NOT change confirmedPosition — '
              'the user view must remain stable at the session boundary');
    });
  });

  group('V3.1 setNoisyEnvironmentMode toggle (issue #11)', () {
    test('default false ⇒ V3 behavior (budget opens on reset)', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV3()..loadScript(script);

      expect(matcher.isNoisyEnvironmentMode, isFalse);

      matcher.onSessionReset();
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, greaterThanOrEqualTo(15));
    });

    test('enabled ⇒ V2 fallback (budget never opens)', () {
      final script = Script.fromText(scriptText);
      final matcher = ScriptMatcherV3()..loadScript(script);
      matcher.setNoisyEnvironmentMode(true);

      expect(matcher.isNoisyEnvironmentMode, isTrue);

      matcher.onSessionReset();
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('uhh ohh', isFinal: false);
      matcher.match('mike november oscar papa', isFinal: false);

      expect(matcher.confirmedPosition, 0,
          reason: 'noisy-mode V3 should behave like V2 — partial recovery '
              'suppressed, position stays put');
    });
  });
}
