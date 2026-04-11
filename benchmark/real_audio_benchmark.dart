// ignore_for_file: avoid_print
//
// Real-audio benchmark for ScriptMatcher V1/V2.
//
// Replays a Vosk streaming-ASR event stream (pre-recorded from a real
// public-domain recording — JFK inaugural) against both matchers with
// the exact JFK transcript as the source script. Reports position
// trajectory and measures forward-jump bugs directly.
//
// Setup: run benchmark/real_audio/run_vosk.py first to regenerate
// benchmark/real_audio/jfk_events.json from the WAV. The generated
// JSON plus the transcript plus this script are enough to reproduce.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher.dart';
import 'package:promptpad/services/script_matcher_v2.dart';
import 'package:promptpad/services/script_matcher_base.dart';

class JumpRecord {
  final int eventIdx;
  final int fromPos;
  final int toPos;
  final String text;
  final bool isFinal;
  JumpRecord({
    required this.eventIdx,
    required this.fromPos,
    required this.toPos,
    required this.text,
    required this.isFinal,
  });
  int get delta => toPos - fromPos;
}

class RunResult {
  int finalPosition = 0;
  int maxPositionReached = 0;
  int forwardJumpCount = 0;
  int maxForwardJump = 0;
  double avgStep = 0;
  final List<JumpRecord> biggestJumps = [];
  final List<int> positionsAfterFinals = [];
}

RunResult run(ScriptMatcherBase matcher, Script script, List<dynamic> events) {
  matcher.loadScript(script);
  matcher.reset();

  final result = RunResult();
  int prev = 0;
  int totalStep = 0;
  int steps = 0;
  final jumps = <JumpRecord>[];

  for (var i = 0; i < events.length; i++) {
    final e = events[i] as Map<String, dynamic>;
    final text = e['text'] as String;
    final isFinal = e['is_final'] as bool;

    matcher.match(text, isFinal: isFinal);
    final pos = matcher.confirmedPosition;

    if (pos > result.maxPositionReached) result.maxPositionReached = pos;
    if (pos > prev) {
      totalStep += pos - prev;
      steps++;
    }
    // Forward jump: position advanced > 5 words in a single event.
    if (pos - prev > 5) {
      result.forwardJumpCount++;
      if (pos - prev > result.maxForwardJump) {
        result.maxForwardJump = pos - prev;
      }
      jumps.add(JumpRecord(
        eventIdx: i,
        fromPos: prev,
        toPos: pos,
        text: text,
        isFinal: isFinal,
      ));
    }
    if (isFinal) result.positionsAfterFinals.add(pos);
    prev = pos;
  }

  result.finalPosition = prev;
  result.avgStep = steps > 0 ? totalStep / steps : 0;
  jumps.sort((a, b) => b.delta.compareTo(a.delta));
  result.biggestJumps.addAll(jumps.take(5));
  return result;
}

void printResult(String name, RunResult r, int scriptWords) {
  print('');
  print('=== $name ===');
  print('  Final position reached:    ${r.finalPosition} / $scriptWords words');
  print('  Max position reached:      ${r.maxPositionReached}');
  print('  Forward jumps (>5 words):  ${r.forwardJumpCount}');
  print('  Max single-event jump:     ${r.maxForwardJump} words');
  print('  Avg forward step:          ${r.avgStep.toStringAsFixed(2)} words');
  if (r.biggestJumps.isNotEmpty) {
    print('  Biggest jumps:');
    for (final j in r.biggestJumps) {
      final kind = j.isFinal ? 'final  ' : 'partial';
      final snippet = j.text.length > 60
          ? '${j.text.substring(0, 57)}...'
          : j.text;
      print('    [${j.eventIdx.toString().padLeft(3)}] '
          '${j.fromPos.toString().padLeft(3)}→${j.toPos.toString().padLeft(3)}'
          ' (+${j.delta.toString().padLeft(3)}) $kind "$snippet"');
    }
  }
}

void main() {
  final here = File.fromUri(Platform.script).parent;
  final scriptPath = '${here.path}/real_audio/jfk_script.txt';
  final eventsPath = '${here.path}/real_audio/jfk_events.json';

  final scriptText = File(scriptPath).readAsStringSync();
  final eventsJson = File(eventsPath).readAsStringSync();
  final events = jsonDecode(eventsJson) as List<dynamic>;

  final script = Script.fromText(scriptText);
  final totalWords = script.tokens.length;

  final finals = events.where((e) => e['is_final'] == true).length;
  final partials = events.length - finals;

  print('=== PromptPad Real-Audio Benchmark (JFK, 120 s) ===');
  print('Script:     $totalWords words, ${script.sentences.length} sentences');
  print('ASR events: ${events.length} ($partials partials + $finals finals)');

  final v1 = ScriptMatcher();
  final v2 = ScriptMatcherV2();

  final r1 = run(v1, script, events);
  final r2 = run(v2, script, events);

  printResult('V1 Classic', r1, totalWords);
  printResult('V2 Advanced', r2, totalWords);

  print('');
  print('=== Delta (V2 − V1) ===');
  final delta = r2.forwardJumpCount - r1.forwardJumpCount;
  final sign = delta == 0 ? '' : (delta > 0 ? '+' : '');
  print('  Forward jumps:   $sign$delta  (V2 worse if >0)');
  print('  Max jump delta:  ${r2.maxForwardJump - r1.maxForwardJump}');
  print('  Final pos delta: ${r2.finalPosition - r1.finalPosition}');
  print('');
  print('Note: max meaningful position ≈ '
      '${max(r1.finalPosition, r2.finalPosition)}  (actual end of 120s).');
  print('If max position reached > final position, matcher jumped ahead then caught up.');
}
