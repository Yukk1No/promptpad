// ignore_for_file: avoid_print
//
// Replay harness for the new benchmark framework. Reads a script + an
// events.json produced by cadence/simulator.py, walks the events through
// the requested matcher (V1 or V2), and emits a trace.json that
// metrics.py consumes.
//
// Usage (from repo root, via main project's pubspec):
//   dart run benchmark/replay/replay.dart \
//       --script benchmark/real_audio/jfk_script.txt \
//       --events benchmark/results/events/jfk__ios-on-device-15.json \
//       --matcher v2 \
//       --out    benchmark/results/traces/jfk__ios-on-device-15__v2.json
//
// The replay treats event_type=session_reset specially: it records a
// trace marker but does NOT call matcher.match(). The matcher itself
// has no notion of session_reset — that's the whole point. The matcher
// still has _matchStartOffset frozen from the previous final, and the
// next transcript event arrives with text starting from empty (because
// cadence/simulator.py made it so). This is the cross-session contract
// breakage we want to measure.

import 'dart:convert';
import 'dart:io';

import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher.dart';
import 'package:promptpad/services/script_matcher_v2.dart';
import 'package:promptpad/services/script_matcher_v3.dart';
import 'package:promptpad/services/script_matcher_v4.dart';
import 'package:promptpad/services/script_matcher_v5.dart';
import 'package:promptpad/services/script_matcher_base.dart';

ScriptMatcherBase _makeMatcher(String name) {
  switch (name) {
    case 'v1':
      return ScriptMatcher();
    case 'v2':
      return ScriptMatcherV2();
    case 'v3':
      return ScriptMatcherV3();
    case 'v3-noisy':
      // Convenience alias: V3 with noisy-environment mode on (V2 fallback).
      // Superseded by V4 (automatic confidence gate); kept for ablation.
      final m = ScriptMatcherV3();
      m.setNoisyEnvironmentMode(true);
      return m;
    case 'v4':
      return ScriptMatcherV4();
    case 'v5':
      // V5 = V3 + discrimination-gated _resyncMatch. Production-safe
      // fix for the V3 cafe-noise regression that V4 only solved on
      // benchmark fixtures (V4 needs partial-level ASR confidence,
      // which iOS speech_to_text never reports — empirically 98.9%
      // of partials are 0.0).
      return ScriptMatcherV5();
    default:
      throw ArgumentError(
          'unknown matcher: $name (expected v1|v2|v3|v3-noisy|v4|v5)');
  }
}

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[key] = argv[++i];
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

void main(List<String> argv) {
  final args = _parseArgs(argv);
  final scriptPath = args['script'];
  final eventsPath = args['events'];
  final matcherName = args['matcher'] ?? 'v2';
  final outPath = args['out'];

  if (scriptPath == null || eventsPath == null || outPath == null) {
    stderr.writeln('usage: replay.dart --script x.txt --events y.json '
        '--matcher v1|v2 --out z.json');
    exit(2);
  }

  final scriptText = File(scriptPath).readAsStringSync();
  final script = Script.fromText(scriptText);
  final matcher = _makeMatcher(matcherName);
  matcher.loadScript(script);
  matcher.reset();

  final eventsPayload = jsonDecode(File(eventsPath).readAsStringSync())
      as Map<String, dynamic>;
  final events = eventsPayload['events'] as List<dynamic>;

  final trace = <Map<String, Object?>>[];
  int matchCalls = 0;
  int sessionResets = 0;

  for (var i = 0; i < events.length; i++) {
    final e = events[i] as Map<String, dynamic>;
    final type = e['event_type'] as String;
    final timeMs = (e['time_ms'] as num).toInt();

    if (type == 'session_reset') {
      // Crucial: do NOT call matcher.match(). Just record where the matcher
      // was so metrics can compute cross_session_recovery_ms.
      // Invoke the matcher's session-reset hook BEFORE recording so the
      // recorded position reflects whatever the matcher decides it should
      // be at the boundary (V1/V2: no-op; V3: re-pin _matchStartOffset).
      // This must NOT teleport the user — V3 leaves _recognizedCharCount
      // (and therefore confirmedPosition) untouched.
      matcher.onSessionReset();
      trace.add({
        'event_idx': i,
        'kind': 'session_reset',
        'time_ms': timeMs,
        'session_id_old': e['session_id_old'],
        'session_id_new': e['session_id_new'],
        'reason': e['reason'],
        'predicted_word_idx_at_reset': matcher.confirmedPosition,
      });
      sessionResets++;
      continue;
    }

    final text = e['text'] as String;
    final isFinal = e['is_final'] as bool;
    // V4 schema: forward per-event mean confidence to the matcher
    // before match(). V1/V2/V3 ignore this hook (no-op default in
    // ScriptMatcherBase). Default to 1.0 when the event predates the
    // confidence-aware schema so V4 falls back to "fully trusted".
    final meanConf = e['mean_confidence'];
    if (meanConf is num) {
      matcher.setNextEventConfidence(meanConf.toDouble());
    } else {
      matcher.setNextEventConfidence(1.0);
    }
    final stopwatch = Stopwatch()..start();
    matcher.match(text, isFinal: isFinal);
    stopwatch.stop();
    final pos = matcher.confirmedPosition;
    matchCalls++;

    trace.add({
      'event_idx': i,
      'kind': 'match',
      'time_ms': timeMs,
      'session_id': e['session_id'],
      'is_final': isFinal,
      'text_len': text.length,
      'predicted_word_idx': pos,
      'match_us': stopwatch.elapsedMicroseconds,
    });
  }

  final out = {
    'events_path': eventsPath,
    'script_path': scriptPath,
    'matcher_version': matcherName,
    'event_count': events.length,
    'match_call_count': matchCalls,
    'session_reset_count': sessionResets,
    'trace': trace,
  };

  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('${jsonEncode(out)}\n');
  stderr.writeln('replay($matcherName): $matchCalls match calls, '
      '$sessionResets session_resets, ${trace.length} trace entries → '
      '$outPath');
}
