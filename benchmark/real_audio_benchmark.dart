// ignore_for_file: avoid_print
//
// Real-audio benchmark for ScriptMatcher V1/V2 with ground-truth alignment.
//
// Pipeline: run_vosk.py emits a streaming ASR event log; align_ground_truth.py
// aligns Vosk's recognized sequence to the real script via difflib, producing
// a time-indexed ground-truth trace (where the speaker actually is in the
// script at each time point). This Dart benchmark replays the events through
// V1/V2 and compares matcher position against ground truth at every event.
//
// Metrics reported per matcher:
//   • Position error = matcher_pos - gt_pos (signed)
//   • Overshoot     = max(0, error)           — the "乱往后跳" bug
//   • Lag           = max(0, -error)          — falling behind
//   • Drift         = running sum of |error| over all events
//   • Max|error|    = worst single-event deviation
//   • Forward jumps > N words between consecutive events
//   • Backward jumps (position decreased)
//   • Stale-advance simulation: mirrors _checkStaleAndAdvance in
//     teleprompter_screen.dart. If 8 s pass without matcher progress,
//     auto-advance 1 sentence. Counted separately so we can see how
//     often the screen-level fallback masks matcher problems.
import 'dart:convert';
import 'dart:io';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher.dart';
import 'package:promptpad/services/script_matcher_v2.dart';
import 'package:promptpad/services/script_matcher_base.dart';

class JumpRecord {
  final int eventIdx;
  final int fromPos;
  final int toPos;
  final int gtPos;
  final String text;
  final bool isFinal;
  JumpRecord({
    required this.eventIdx,
    required this.fromPos,
    required this.toPos,
    required this.gtPos,
    required this.text,
    required this.isFinal,
  });
  int get delta => toPos - fromPos;
}

class RunResult {
  int finalPosition = 0;
  int finalGtPosition = 0;
  int maxPositionReached = 0;
  int forwardJumpCount = 0;
  int backwardJumpCount = 0;
  int maxForwardJump = 0;
  int maxBackwardJump = 0;

  double meanAbsError = 0; // mean |pos - gt|
  int maxAbsError = 0;
  double meanOvershoot = 0; // mean max(0, pos - gt)
  int maxOvershoot = 0;
  double meanLag = 0; // mean max(0, gt - pos)
  int maxLag = 0;
  int eventsAheadOfGt = 0;
  int eventsBehindGt = 0;
  int eventsOnTarget = 0; // |error| <= 2

  int staleAdvanceCount = 0;

  // Stall statistics — catches the "stuck behind" failure mode where
  // the matcher never jumps but never advances either.
  int maxStallEvents = 0; // longest run of events with no advance
  int maxStallMs = 0; // longest wall-clock stall
  int totalStallMs = 0; // total time spent not advancing
  int stallBurstCount = 0; // number of stalls lasting > 2 s

  final List<JumpRecord> biggestJumps = [];
  // per-event trace: [event_idx, time_ms, pos, gt_pos, error]
  final List<List<num>> trace = [];
}

/// Ground truth samples: sorted list of (time_ms, script_word_idx).
class GroundTruth {
  final List<List<num>> samples;
  GroundTruth(this.samples);

  int positionAt(int timeMs) {
    if (samples.isEmpty) return 0;
    if (timeMs <= samples.first[0]) return samples.first[1].toInt();
    if (timeMs >= samples.last[0]) return samples.last[1].toInt();
    // Binary search
    var lo = 0;
    var hi = samples.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (samples[mid][0] < timeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return samples[lo][1].toInt();
  }
}

RunResult run({
  required String name,
  required ScriptMatcherBase matcher,
  required Script script,
  required List<dynamic> events,
  required GroundTruth gt,
  bool simulateStaleAdvance = true,
  int staleThresholdSec = 8,
}) {
  matcher.loadScript(script);
  matcher.reset();

  final result = RunResult();
  int prev = 0;
  int absErrSum = 0;
  int overshootSum = 0;
  int lagSum = 0;

  int lastProgressTimeMs = 0;
  int lastProgressEventIdx = 0;

  final jumps = <JumpRecord>[];

  for (var i = 0; i < events.length; i++) {
    final e = events[i] as Map<String, dynamic>;
    final timeMs = (e['time_ms'] as num).toInt();
    final text = e['text'] as String;
    final isFinal = e['is_final'] as bool;

    matcher.match(text, isFinal: isFinal);
    int pos = matcher.confirmedPosition;

    // Stale-advance simulation (mirrors teleprompter_screen._checkStaleAndAdvance).
    if (simulateStaleAdvance) {
      if (pos > prev) {
        lastProgressTimeMs = timeMs;
      } else if (timeMs - lastProgressTimeMs >= staleThresholdSec * 1000) {
        final curSentence = matcher.currentSentence;
        if (curSentence < matcher.totalSentences - 1) {
          matcher.jumpToSentence(curSentence + 1);
          result.staleAdvanceCount++;
          lastProgressTimeMs = timeMs;
          pos = matcher.confirmedPosition;
        }
      }
    }

    final gtPos = gt.positionAt(timeMs);
    final err = pos - gtPos;

    result.trace.add([i, timeMs, pos, gtPos, err]);

    if (pos > result.maxPositionReached) result.maxPositionReached = pos;

    absErrSum += err.abs();
    if (err.abs() > result.maxAbsError) result.maxAbsError = err.abs();

    if (err > 0) {
      overshootSum += err;
      if (err > result.maxOvershoot) result.maxOvershoot = err;
      result.eventsAheadOfGt++;
    } else if (err < 0) {
      lagSum += -err;
      if (-err > result.maxLag) result.maxLag = -err;
      result.eventsBehindGt++;
    }
    if (err.abs() <= 2) result.eventsOnTarget++;

    final delta = pos - prev;
    if (delta > 5) {
      result.forwardJumpCount++;
      if (delta > result.maxForwardJump) result.maxForwardJump = delta;
      jumps.add(JumpRecord(
        eventIdx: i,
        fromPos: prev,
        toPos: pos,
        gtPos: gtPos,
        text: text,
        isFinal: isFinal,
      ));
    } else if (delta < 0) {
      result.backwardJumpCount++;
      if (-delta > result.maxBackwardJump) result.maxBackwardJump = -delta;
    }

    // Stall tracking: a stall ends the moment pos > prev.
    if (pos > prev) {
      final stallMs = timeMs - lastProgressTimeMs;
      if (stallMs >= 2000) {
        result.stallBurstCount++;
        result.totalStallMs += stallMs;
      }
      final stallEvents = i - lastProgressEventIdx;
      if (stallEvents > result.maxStallEvents) {
        result.maxStallEvents = stallEvents;
      }
      if (stallMs > result.maxStallMs) result.maxStallMs = stallMs;
      lastProgressTimeMs = timeMs;
      lastProgressEventIdx = i;
    }

    prev = pos;
  }
  // Trailing stall at end of stream
  final trailingMs = ((events.last as Map<String, dynamic>)['time_ms'] as int) -
      lastProgressTimeMs;
  if (trailingMs > result.maxStallMs) result.maxStallMs = trailingMs;
  if (trailingMs >= 2000) {
    result.stallBurstCount++;
    result.totalStallMs += trailingMs;
  }
  final trailingEvents = events.length - 1 - lastProgressEventIdx;
  if (trailingEvents > result.maxStallEvents) {
    result.maxStallEvents = trailingEvents;
  }

  result.finalPosition = prev;
  result.finalGtPosition = gt.positionAt(
    (events.last as Map<String, dynamic>)['time_ms'] as int,
  );
  final n = events.length;
  result.meanAbsError = absErrSum / n;
  result.meanOvershoot = overshootSum / n;
  result.meanLag = lagSum / n;

  jumps.sort((a, b) => b.delta.compareTo(a.delta));
  result.biggestJumps.addAll(jumps.take(5));
  return result;
}

String _fmtNum(double v, {int decimals = 2}) => v.toStringAsFixed(decimals);
String _fmtInt(int v) => v.toString();

void _pair(String label, String a, String b) {
  print('  ${label.padRight(30)} ${a.padLeft(10)}   ${b.padLeft(10)}');
}

void _report(
  String audioLabel,
  int totalWords,
  int scriptSentences,
  int eventCount,
  RunResult v1,
  RunResult v2,
) {
  print('');
  print('┌─────────────────────────────────────────────────────┐');
  print('│ $audioLabel');
  print('│ Script: $totalWords words, $scriptSentences sentences');
  print('│ Events: $eventCount');
  print('│ Ground truth end position: ${v1.finalGtPosition}');
  print('└─────────────────────────────────────────────────────┘');
  print('');
  print('  ${'metric'.padRight(30)} ${'V1'.padLeft(10)}   ${'V2'.padLeft(10)}');
  print('  ${'─' * 30} ${'─' * 10}   ${'─' * 10}');
  _pair('Final position',
      _fmtInt(v1.finalPosition), _fmtInt(v2.finalPosition));
  _pair('Max reached position',
      _fmtInt(v1.maxPositionReached), _fmtInt(v2.maxPositionReached));
  _pair('Mean |error|',
      _fmtNum(v1.meanAbsError), _fmtNum(v2.meanAbsError));
  _pair('Max |error|',
      _fmtInt(v1.maxAbsError), _fmtInt(v2.maxAbsError));
  _pair('Mean overshoot (ahead)',
      _fmtNum(v1.meanOvershoot), _fmtNum(v2.meanOvershoot));
  _pair('Max overshoot',
      _fmtInt(v1.maxOvershoot), _fmtInt(v2.maxOvershoot));
  _pair('Mean lag (behind)',
      _fmtNum(v1.meanLag), _fmtNum(v2.meanLag));
  _pair('Max lag',
      _fmtInt(v1.maxLag), _fmtInt(v2.maxLag));
  _pair('Events on-target (±2)',
      _fmtInt(v1.eventsOnTarget), _fmtInt(v2.eventsOnTarget));
  _pair('Events ahead of GT',
      _fmtInt(v1.eventsAheadOfGt), _fmtInt(v2.eventsAheadOfGt));
  _pair('Events behind GT',
      _fmtInt(v1.eventsBehindGt), _fmtInt(v2.eventsBehindGt));
  _pair('Forward jumps (>5 words)',
      _fmtInt(v1.forwardJumpCount), _fmtInt(v2.forwardJumpCount));
  _pair('Max single forward jump',
      _fmtInt(v1.maxForwardJump), _fmtInt(v2.maxForwardJump));
  _pair('Backward jumps',
      _fmtInt(v1.backwardJumpCount), _fmtInt(v2.backwardJumpCount));
  _pair('Max single backward jump',
      _fmtInt(v1.maxBackwardJump), _fmtInt(v2.maxBackwardJump));
  _pair('Stale-advance firings',
      _fmtInt(v1.staleAdvanceCount), _fmtInt(v2.staleAdvanceCount));
  _pair('Max stall (events)',
      _fmtInt(v1.maxStallEvents), _fmtInt(v2.maxStallEvents));
  _pair('Max stall (ms)',
      _fmtInt(v1.maxStallMs), _fmtInt(v2.maxStallMs));
  _pair('Stall bursts ≥2 s',
      _fmtInt(v1.stallBurstCount), _fmtInt(v2.stallBurstCount));
  _pair('Total stall time (ms)',
      _fmtInt(v1.totalStallMs), _fmtInt(v2.totalStallMs));

  for (final (label, r) in [('V1', v1), ('V2', v2)]) {
    if (r.biggestJumps.isEmpty) continue;
    print('');
    print('  $label biggest forward jumps:');
    for (final j in r.biggestJumps) {
      final kind = j.isFinal ? 'final  ' : 'partial';
      final snippet = j.text.length > 55
          ? '${j.text.substring(0, 52)}...'
          : j.text;
      print('    [${j.eventIdx.toString().padLeft(3)}] '
          '${j.fromPos.toString().padLeft(3)}→${j.toPos.toString().padLeft(3)}'
          ' (+${j.delta.toString().padLeft(3)}) '
          'gt=${j.gtPos.toString().padLeft(3)} '
          '$kind "$snippet"');
    }
  }
}

// ---------------------------------------------------------------------------
// Event-stream transformations — stress tests
// ---------------------------------------------------------------------------

/// Pause mode: insert a 12-second silent gap at the midpoint. Forces the
/// stale-advance screen timer to fire, which in real use is perceived as a
/// "sudden jump" — we want to verify the jump lands at the right sentence.
List<dynamic> transformPause(List<dynamic> events) {
  if (events.isEmpty) return events;
  final mid = events.length ~/ 2;
  const gapMs = 12000;
  final out = <dynamic>[];
  for (var i = 0; i < events.length; i++) {
    final e = Map<String, dynamic>.from(events[i] as Map<String, dynamic>);
    if (i >= mid) {
      e['time_ms'] = (e['time_ms'] as int) + gapMs;
    }
    out.add(e);
  }
  return out;
}

/// Rapid mode: halve all inter-event gaps (2× read speed).
List<dynamic> transformRapid(List<dynamic> events) {
  if (events.isEmpty) return events;
  final out = <dynamic>[];
  final first = (events[0] as Map)['time_ms'] as int;
  for (var i = 0; i < events.length; i++) {
    final e = Map<String, dynamic>.from(events[i] as Map<String, dynamic>);
    e['time_ms'] = first + ((e['time_ms'] as int) - first) ~/ 2;
    out.add(e);
  }
  return out;
}

/// Tail-churn mode: for every partial with ≥4 words, rewrite the LAST word
/// to a common English word on every other partial. Simulates heavy ASR
/// tail prediction instability beyond what the recording naturally exhibits.
List<dynamic> transformTailChurn(List<dynamic> events) {
  const churn = [
    'the', 'a', 'and', 'with', 'for', 'that', 'this', 'of', 'in', 'on'
  ];
  final out = <dynamic>[];
  var flip = 0;
  for (final raw in events) {
    final e = Map<String, dynamic>.from(raw as Map<String, dynamic>);
    if (!(e['is_final'] as bool) && flip.isEven) {
      final text = e['text'] as String;
      final words = text.split(' ');
      if (words.length >= 4) {
        words[words.length - 1] = churn[flip % churn.length];
        e['text'] = words.join(' ');
      }
    }
    flip++;
    out.add(e);
  }
  return out;
}

/// Dropout mode: drop 40% of partials (simulates a cellular/poor-signal ASR
/// connection — fewer but larger updates). Finals are preserved.
List<dynamic> transformDropout(List<dynamic> events) {
  final out = <dynamic>[];
  var idx = 0;
  for (final raw in events) {
    final e = raw as Map<String, dynamic>;
    final keep = (e['is_final'] as bool) || (idx % 5 < 3);
    if (keep) out.add(e);
    idx++;
  }
  return out;
}

// ---------------------------------------------------------------------------

void runAudio(String stem, String label) {
  final here = File.fromUri(Platform.script).parent;
  final scriptPath = '${here.path}/real_audio/${stem}_script.txt';
  final eventsPath = '${here.path}/real_audio/${stem}_events.json';
  final gtPath = '${here.path}/real_audio/${stem}_gt.json';

  final scriptText = File(scriptPath).readAsStringSync();
  final baseEvents =
      jsonDecode(File(eventsPath).readAsStringSync()) as List<dynamic>;
  final gtJson =
      jsonDecode(File(gtPath).readAsStringSync()) as Map<String, dynamic>;
  final samples = (gtJson['samples'] as List<dynamic>)
      .map((s) => (s as List<dynamic>).map((v) => v as num).toList())
      .toList();
  final gt = GroundTruth(samples);

  final script = Script.fromText(scriptText);

  final modes = <(String, List<dynamic>, bool)>[
    // (label, events, simulateStaleAdvance)
    ('baseline (no stale-advance)', baseEvents, false),
    ('baseline (with stale-advance)', baseEvents, true),
    ('pause+12s (no stale-advance)', transformPause(baseEvents), false),
    ('pause+12s (with stale-advance)', transformPause(baseEvents), true),
    ('tail churn', transformTailChurn(baseEvents), true),
    ('partial dropout 40%', transformDropout(baseEvents), true),
  ];

  for (final (modeLabel, events, staleAdvance) in modes) {
    final v1 = run(
      name: 'V1',
      matcher: ScriptMatcher(),
      script: script,
      events: events,
      gt: gt,
      simulateStaleAdvance: staleAdvance,
    );
    final v2 = run(
      name: 'V2',
      matcher: ScriptMatcherV2(),
      script: script,
      events: events,
      gt: gt,
      simulateStaleAdvance: staleAdvance,
    );
    _report(
      '$label  —  mode: $modeLabel',
      script.tokens.length,
      script.sentences.length,
      events.length,
      v1,
      v2,
    );
  }
}

void main(List<String> args) {
  print('=== PromptPad Real-Audio Benchmark ===');
  print('(V1 = Classic, V2 = Advanced after tail-trim fix)');
  print('Ground truth is Vosk word-timings aligned to script via difflib.');
  print('5 transforms per audio: baseline / pause / rapid / churn / dropout');

  // Each entry: (stem, label). Add more audio clips here.
  final clips = <(String, String)>[
    ('jfk', 'JFK Inaugural Address (first 120 s)'),
    ('fdr', 'FDR Day of Infamy (first 120 s)'),
  ];

  for (final (stem, label) in clips) {
    try {
      runAudio(stem, label);
    } catch (e, st) {
      print('');
      print('ERROR on $stem: $e');
      print(st);
    }
  }
}
