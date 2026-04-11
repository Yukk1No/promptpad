// ignore_for_file: avoid_print
import 'dart:math';
import 'package:promptpad/models/script.dart';
import 'package:promptpad/services/script_matcher.dart';
import 'package:promptpad/services/script_matcher_v2.dart';
import 'package:promptpad/services/script_matcher_base.dart';

// ---------------------------------------------------------------------------
// Test script (~200 words, multi-paragraph, with anchors)
// ---------------------------------------------------------------------------

const _testScript = '''
Good evening and welcome to the 2024 Technology Summit hosted by NVIDIA in
San Francisco. Tonight we will explore how artificial intelligence is
transforming healthcare, education, and transportation across the globe.

Over the past 15 years, machine learning algorithms have achieved remarkable
breakthroughs. In 2019, researchers at Stanford University demonstrated that
neural networks could diagnose pneumonia from chest X-rays with 92 percent
accuracy. This was a turning point for the medical community.

However, challenges remain. Data privacy regulations such as HIPAA and GDPR
require careful handling of patient information. Organizations must balance
innovation with responsibility, ensuring that vulnerable populations are
protected from algorithmic bias.

Looking ahead to 2025, autonomous vehicles manufactured by Tesla and Waymo
are expected to operate in 30 major metropolitan areas. The Department of
Transportation has proposed new safety standards requiring 99.7 percent
reliability before commercial deployment begins.

In conclusion, the journey from laboratory research to real-world application
demands collaboration between scientists, engineers, policymakers, and the
public. Together we can build a future where technology serves everyone
equally. Thank you for joining us this evening.
''';

// ---------------------------------------------------------------------------
// ASR event
// ---------------------------------------------------------------------------

class AsrEvent {
  final String transcript;
  final bool isFinal;
  final int groundTruthWordIndex;

  const AsrEvent(this.transcript, this.isFinal, this.groundTruthWordIndex);
}

// ---------------------------------------------------------------------------
// Simulated ASR
// ---------------------------------------------------------------------------

class SimulatedAsr {
  final Random _rng;
  late final Script _script;
  late final List<String> _words;

  SimulatedAsr(this._rng) {
    _script = Script.fromText(_testScript);
    _words = _script.tokens.map((t) => t.raw).toList();
  }

  Script get script => _script;

  // --- Confusion pairs for noisy ASR ---
  static const _confusionPairs = <String, String>{
    'the': 'a',
    'their': 'there',
    'there': 'they\'re',
    'they\'re': 'their',
    'to': 'too',
    'too': 'to',
    'are': 'our',
    'our': 'are',
    'new': 'knew',
    'for': 'four',
    'from': 'form',
    'with': 'which',
    'that': 'than',
    'than': 'that',
    'has': 'as',
    'and': 'an',
    'can': 'ken',
    'we': 'wee',
    'in': 'inn',
    'is': 'his',
  };

  static const _fillerWords = ['um', 'uh', 'like', 'so', 'you know'];

  // --- Scenario 1: Perfect reading ---
  List<AsrEvent> perfectReading() {
    final events = <AsrEvent>[];
    // Simulate sentence-at-a-time reading with partial buildup
    var wordIdx = 0;

    while (wordIdx < _words.length) {
      // Determine chunk size (sentence-ish: 8-15 words)
      final chunkSize = min(8 + _rng.nextInt(8), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;

      // Emit partials: 2 words at a time building up
      for (var partialEnd = wordIdx + 2;
          partialEnd < chunkEnd;
          partialEnd += 2) {
        final partial =
            _words.sublist(wordIdx, min(partialEnd, chunkEnd)).join(' ');
        events.add(AsrEvent(partial, false, min(partialEnd - 1, _words.length - 1)));
      }

      // Emit final for the chunk
      final finalText = _words.sublist(wordIdx, chunkEnd).join(' ');
      events.add(AsrEvent(finalText, true, chunkEnd - 1));
      wordIdx = chunkEnd;
    }
    return events;
  }

  // --- Scenario 2: Noisy ASR ---
  List<AsrEvent> noisyAsr() {
    final events = <AsrEvent>[];
    var wordIdx = 0;

    while (wordIdx < _words.length) {
      final chunkSize = min(6 + _rng.nextInt(6), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;

      final noisyWords = <String>[];
      var gtIdx = wordIdx;
      for (var i = wordIdx; i < chunkEnd; i++) {
        final roll = _rng.nextDouble();
        final word = _words[i].toLowerCase();

        if (roll < 0.15) {
          // Substitution (15%)
          final sub = _confusionPairs[word];
          noisyWords.add(sub ?? _swapVowel(word));
          gtIdx = i;
        } else if (roll < 0.20) {
          // Insertion (5%)
          noisyWords.add(_fillerWords[_rng.nextInt(_fillerWords.length)]);
          noisyWords.add(word);
          gtIdx = i;
        } else if (roll < 0.25) {
          // Deletion (5%)
          gtIdx = i;
          continue;
        } else {
          noisyWords.add(word);
          gtIdx = i;
        }
      }

      // Emit a couple of partials then final
      if (noisyWords.length > 4) {
        final halfLen = noisyWords.length ~/ 2;
        final partial = noisyWords.sublist(0, halfLen).join(' ');
        events.add(AsrEvent(partial, false, wordIdx + halfLen - 1));
      }

      final finalText = noisyWords.join(' ');
      events
          .add(AsrEvent(finalText, true, min(gtIdx, _words.length - 1)));
      wordIdx = chunkEnd;
    }
    return events;
  }

  // --- Scenario 3: Skip-read ---
  List<AsrEvent> skipRead() {
    final events = <AsrEvent>[];
    var wordIdx = 0;
    final skipPoint = _words.length ~/ 3; // skip around 1/3 through
    final skipSize = 15 + _rng.nextInt(10); // skip 15-24 words

    while (wordIdx < _words.length) {
      // At the skip point, jump ahead
      if (wordIdx >= skipPoint && wordIdx < skipPoint + skipSize) {
        wordIdx = min(skipPoint + skipSize, _words.length);
        continue;
      }

      final chunkSize = min(8 + _rng.nextInt(6), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;

      // Partials
      for (var partialEnd = wordIdx + 3;
          partialEnd < chunkEnd;
          partialEnd += 3) {
        final partial =
            _words.sublist(wordIdx, min(partialEnd, chunkEnd)).join(' ');
        events.add(AsrEvent(partial, false, min(partialEnd - 1, _words.length - 1)));
      }

      final finalText = _words.sublist(wordIdx, chunkEnd).join(' ');
      events.add(AsrEvent(finalText, true, chunkEnd - 1));
      wordIdx = chunkEnd;
    }
    return events;
  }

  // --- Scenario 4: Pause & resume ---
  List<AsrEvent> pauseAndResume() {
    final events = <AsrEvent>[];
    var wordIdx = 0;
    final pausePoint = _words.length ~/ 2;
    const pauseFrames = 6;

    while (wordIdx < _words.length) {
      // Insert silence frames at pause point
      if (wordIdx == pausePoint) {
        for (var i = 0; i < pauseFrames; i++) {
          events.add(AsrEvent('', false, wordIdx));
        }
      }

      final chunkSize = min(8 + _rng.nextInt(6), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;

      // Partials
      for (var partialEnd = wordIdx + 2;
          partialEnd < chunkEnd;
          partialEnd += 3) {
        final partial =
            _words.sublist(wordIdx, min(partialEnd, chunkEnd)).join(' ');
        events.add(AsrEvent(partial, false, min(partialEnd - 1, _words.length - 1)));
      }

      final finalText = _words.sublist(wordIdx, chunkEnd).join(' ');
      events.add(AsrEvent(finalText, true, chunkEnd - 1));
      wordIdx = chunkEnd;
    }
    return events;
  }

  // --- Scenario 5: Partial result churn ---
  List<AsrEvent> partialChurn() {
    final events = <AsrEvent>[];
    var wordIdx = 0;

    // Words that "churn" in partials
    const churnPairs = [
      ['their', 'there', 'they\'re', 'their'],
      ['to', 'too', 'two', 'to'],
      ['new', 'knew', 'new', 'new'],
      ['are', 'our', 'are', 'are'],
    ];

    while (wordIdx < _words.length) {
      final chunkSize = min(8 + _rng.nextInt(6), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;
      final chunkWords = _words.sublist(wordIdx, chunkEnd);

      // Find words in this chunk that could churn
      final churnIndices = <int>[];
      for (var i = 0; i < chunkWords.length; i++) {
        final lower = chunkWords[i].toLowerCase();
        for (final pair in churnPairs) {
          if (pair.contains(lower)) {
            churnIndices.add(i);
            break;
          }
        }
      }

      // Emit partials with churn
      for (var pass = 0; pass < 3; pass++) {
        final partialWords = List<String>.from(chunkWords);
        // On intermediate passes, flip churn words
        if (pass < 2) {
          for (final ci in churnIndices) {
            final lower = partialWords[ci].toLowerCase();
            for (final pair in churnPairs) {
              if (pair.contains(lower)) {
                partialWords[ci] = pair[pass % pair.length];
                break;
              }
            }
          }
        }
        final partialLen = min(
            (chunkWords.length * (pass + 1)) ~/ 3 + 2, chunkWords.length);
        final partial = partialWords.sublist(0, partialLen).join(' ');
        events.add(AsrEvent(
            partial, false, min(wordIdx + partialLen - 1, _words.length - 1)));
      }

      // Final with correct words
      final finalText = chunkWords.join(' ');
      events.add(AsrEvent(finalText, true, chunkEnd - 1));
      wordIdx = chunkEnd;
    }
    return events;
  }

  // --- Scenario 6: Tail Hallucination ---
  // Models real ASR: each partial adds 1-2 words with a 50% chance of
  // a hallucinated extra word at the end that gets corrected on final.
  // The hallucinated word is pulled from further ahead in the script to
  // stress-test forward-jump protection.
  List<AsrEvent> tailHallucination() {
    final events = <AsrEvent>[];
    var wordIdx = 0;

    while (wordIdx < _words.length) {
      final chunkSize = min(8 + _rng.nextInt(5), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;
      final chunkWords = _words.sublist(wordIdx, chunkEnd);

      // Emit partials growing 1 word at a time
      for (var p = 2; p < chunkWords.length; p++) {
        final parts = chunkWords.sublist(0, p).toList();

        // 50% chance of hallucinated tail word from further ahead
        if (_rng.nextDouble() < 0.5 && wordIdx + p + 5 < _words.length) {
          final halluIdx = wordIdx + p + 3 + _rng.nextInt(5);
          parts.add(_words[halluIdx].toLowerCase());
        }

        events.add(AsrEvent(parts.join(' '), false, wordIdx + p - 1));
      }

      final finalText = chunkWords.join(' ');
      events.add(AsrEvent(finalText, true, chunkEnd - 1));
      wordIdx = chunkEnd;
    }
    return events;
  }

  // --- Scenario 7: Growing Tail Churn ---
  // Partials grow but the last word churns between common words on each
  // partial, simulating ASR uncertainty on the most recent word.
  List<AsrEvent> growingTailChurn() {
    final events = <AsrEvent>[];
    var wordIdx = 0;
    const churnPool = [
      'the', 'a', 'and', 'with', 'for', 'that', 'this', 'in', 'on', 'of'
    ];

    while (wordIdx < _words.length) {
      final chunkSize = min(10 + _rng.nextInt(5), _words.length - wordIdx);
      final chunkEnd = wordIdx + chunkSize;
      final chunkWords = _words.sublist(wordIdx, chunkEnd);

      for (var p = 3; p < chunkWords.length; p += 1) {
        final parts = chunkWords.sublist(0, p).toList();

        // 40% chance: replace the LAST word with a churned common word
        if (_rng.nextDouble() < 0.4) {
          parts[parts.length - 1] =
              churnPool[_rng.nextInt(churnPool.length)];
        }

        events.add(AsrEvent(parts.join(' '), false, wordIdx + p - 1));
      }

      final finalText = chunkWords.join(' ');
      events.add(AsrEvent(finalText, true, chunkEnd - 1));
      wordIdx = chunkEnd;
    }
    return events;
  }

  String _swapVowel(String word) {
    if (word.isEmpty) return word;
    const vowels = 'aeiou';
    final chars = word.split('');
    for (var i = 0; i < chars.length; i++) {
      final idx = vowels.indexOf(chars[i]);
      if (idx >= 0) {
        chars[i] = vowels[(idx + 1) % vowels.length];
        break;
      }
    }
    return chars.join();
  }
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

class BenchmarkMetrics {
  double meanAbsError = 0;
  int maxError = 0;
  double falseJumpRate = 0;
  double jitter = 0;
  double recoveryEvents = double.nan;
  double avgMatchMicroseconds = 0;
  // Count of events where reported position exceeded ground truth by > 2 words.
  // This directly measures "forward jumping" — the user-visible bug.
  int forwardOvershoots = 0;
  // Max forward overshoot in words
  int maxForwardOvershoot = 0;
}

BenchmarkMetrics runScenario(
  ScriptMatcherBase matcher,
  Script script,
  List<AsrEvent> events,
  {List<int>? recoveryPoints}
) {
  matcher.loadScript(script);
  matcher.reset();

  final metrics = BenchmarkMetrics();
  final errors = <int>[];
  final positions = <int>[];
  final timings = <int>[];

  final sw = Stopwatch();

  for (final event in events) {
    sw.reset();
    sw.start();
    matcher.match(event.transcript, isFinal: event.isFinal);
    sw.stop();

    // Use confirmedPosition (internal tracking) rather than the display
    // position returned by match(). V2's display output is gated by a
    // 300 ms hysteresis timer that never fires in a tight benchmark loop.
    final pos = matcher.confirmedPosition;
    timings.add(sw.elapsedMicroseconds);
    positions.add(pos);
    errors.add((pos - event.groundTruthWordIndex).abs());
  }

  // Mean Absolute Position Error
  if (errors.isNotEmpty) {
    metrics.meanAbsError = errors.reduce((a, b) => a + b) / errors.length;
  }

  // Max Error
  metrics.maxError = errors.isEmpty ? 0 : errors.reduce(max);

  // False Jump Rate: jumps > 5 words between consecutive events
  var falseJumps = 0;
  for (var i = 1; i < positions.length; i++) {
    if ((positions[i] - positions[i - 1]).abs() > 5) {
      falseJumps++;
    }
  }
  metrics.falseJumpRate =
      events.length > 1 ? falseJumps / (events.length - 1) : 0;

  // Forward overshoot: how often reported position runs AHEAD of truth.
  // This is the user-visible "jumping forward" bug.
  var maxOvershoot = 0;
  for (var i = 0; i < positions.length; i++) {
    final overshoot = positions[i] - events[i].groundTruthWordIndex;
    if (overshoot > 2) {
      metrics.forwardOvershoots++;
      if (overshoot > maxOvershoot) maxOvershoot = overshoot;
    }
  }
  metrics.maxForwardOvershoot = maxOvershoot;

  // Jitter: std dev of position changes
  if (positions.length > 1) {
    final deltas = <int>[];
    for (var i = 1; i < positions.length; i++) {
      deltas.add((positions[i] - positions[i - 1]).abs());
    }
    final meanDelta = deltas.reduce((a, b) => a + b) / deltas.length;
    var sumSqDiff = 0.0;
    for (final d in deltas) {
      sumSqDiff += (d - meanDelta) * (d - meanDelta);
    }
    metrics.jitter = sqrt(sumSqDiff / deltas.length);
  }

  // Recovery time
  if (recoveryPoints != null && recoveryPoints.isNotEmpty) {
    var totalRecovery = 0;
    var recoveryCount = 0;
    for (final rp in recoveryPoints) {
      if (rp >= events.length) continue;
      for (var i = rp; i < events.length; i++) {
        if (errors[i] < 3) {
          totalRecovery += (i - rp);
          recoveryCount++;
          break;
        }
      }
    }
    metrics.recoveryEvents =
        recoveryCount > 0 ? totalRecovery / recoveryCount : double.nan;
  }

  // Avg match() time
  if (timings.isNotEmpty) {
    metrics.avgMatchMicroseconds =
        timings.reduce((a, b) => a + b) / timings.length;
  }

  return metrics;
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

String _fmtNum(double v, {int decimals = 2}) {
  if (v.isNaN) return '-';
  return v.toStringAsFixed(decimals);
}

String _fmtInt(int v) => v.toString();

void _printRow(String label, String classic, String advanced) {
  print('  ${label.padRight(24)} ${classic.padLeft(10)}  ${advanced.padLeft(10)}');
}

void _printScenario(
  String name,
  BenchmarkMetrics classic,
  BenchmarkMetrics advanced,
) {
  print('');
  print('--- Scenario: $name ---');
  _printRow('', 'Classic', 'Advanced');
  _printRow(
      'Mean Position Error:', _fmtNum(classic.meanAbsError), _fmtNum(advanced.meanAbsError));
  _printRow('Max Error:', _fmtInt(classic.maxError), _fmtInt(advanced.maxError));
  _printRow(
      'False Jump Rate:', _fmtNum(classic.falseJumpRate), _fmtNum(advanced.falseJumpRate));
  _printRow('Fwd Overshoots:',
      _fmtInt(classic.forwardOvershoots), _fmtInt(advanced.forwardOvershoots));
  _printRow('Max Overshoot:',
      _fmtInt(classic.maxForwardOvershoot),
      _fmtInt(advanced.maxForwardOvershoot));
  _printRow('Jitter (sigma):', _fmtNum(classic.jitter), _fmtNum(advanced.jitter));
  _printRow('Recovery Events:',
      _fmtNum(classic.recoveryEvents), _fmtNum(advanced.recoveryEvents));
  _printRow('Avg match() us:',
      _fmtNum(classic.avgMatchMicroseconds, decimals: 0),
      _fmtNum(advanced.avgMatchMicroseconds, decimals: 0));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  final rng = Random(42);
  final asr = SimulatedAsr(rng);
  final script = asr.script;

  print('=== PromptPad Matcher Benchmark ===');
  print('');
  print('Script: ${script.tokens.length} words, ${script.sentences.length} sentences');

  final classicMatcher = ScriptMatcher();
  final advancedMatcher = ScriptMatcherV2();

  // Collect overall metrics for summary
  final allClassic = <BenchmarkMetrics>[];
  final allAdvanced = <BenchmarkMetrics>[];

  // --- Scenario 1: Perfect Reading ---
  {
    final events = asr.perfectReading();
    final c = runScenario(classicMatcher, script, events);
    final a = runScenario(advancedMatcher, script, events);
    _printScenario('Perfect Reading', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Scenario 2: Noisy ASR (15% sub) ---
  {
    final events = asr.noisyAsr();
    final c = runScenario(classicMatcher, script, events);
    final a = runScenario(advancedMatcher, script, events);
    _printScenario('Noisy ASR (15% sub)', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Scenario 3: Skip-Read ---
  {
    final events = asr.skipRead();
    // Find the event index right after the skip for recovery measurement
    final recoveryPoints = <int>[];
    for (var i = 1; i < events.length; i++) {
      final jump = events[i].groundTruthWordIndex -
          events[i - 1].groundTruthWordIndex;
      if (jump > 10) {
        recoveryPoints.add(i);
      }
    }
    final c = runScenario(classicMatcher, script, events,
        recoveryPoints: recoveryPoints);
    final a = runScenario(advancedMatcher, script, events,
        recoveryPoints: recoveryPoints);
    _printScenario('Skip-Read', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Scenario 4: Pause & Resume ---
  {
    final events = asr.pauseAndResume();
    // Recovery point is the first non-empty event after the silence block
    final recoveryPoints = <int>[];
    for (var i = 1; i < events.length; i++) {
      if (events[i - 1].transcript.isEmpty && events[i].transcript.isNotEmpty) {
        recoveryPoints.add(i);
      }
    }
    final c = runScenario(classicMatcher, script, events,
        recoveryPoints: recoveryPoints);
    final a = runScenario(advancedMatcher, script, events,
        recoveryPoints: recoveryPoints);
    _printScenario('Pause & Resume', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Scenario 5: Partial Result Churn ---
  {
    final events = asr.partialChurn();
    final c = runScenario(classicMatcher, script, events);
    final a = runScenario(advancedMatcher, script, events);
    _printScenario('Partial Result Churn', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Scenario 6: Tail Hallucination (real-world ASR tail prediction) ---
  {
    final events = asr.tailHallucination();
    final c = runScenario(classicMatcher, script, events);
    final a = runScenario(advancedMatcher, script, events);
    _printScenario('Tail Hallucination', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Scenario 7: Growing Tail Churn (churning last word per partial) ---
  {
    final events = asr.growingTailChurn();
    final c = runScenario(classicMatcher, script, events);
    final a = runScenario(advancedMatcher, script, events);
    _printScenario('Growing Tail Churn', c, a);
    allClassic.add(c);
    allAdvanced.add(a);
  }

  // --- Summary ---
  print('');
  print('=== Summary ===');
  _printRow('', 'Classic', 'Advanced');

  double avgMetric(List<BenchmarkMetrics> list, double Function(BenchmarkMetrics) f) {
    final vals = list.map(f).toList();
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  _printRow(
    'Overall MAPE:',
    _fmtNum(avgMetric(allClassic, (m) => m.meanAbsError)),
    _fmtNum(avgMetric(allAdvanced, (m) => m.meanAbsError)),
  );

  final totalFalseJumpsC = allClassic.map((m) => m.falseJumpRate).reduce((a, b) => a + b);
  final totalFalseJumpsA = allAdvanced.map((m) => m.falseJumpRate).reduce((a, b) => a + b);
  _printRow(
    'Overall False Jump Rate:',
    _fmtNum(totalFalseJumpsC / allClassic.length),
    _fmtNum(totalFalseJumpsA / allAdvanced.length),
  );

  final totalOvershootsC =
      allClassic.map((m) => m.forwardOvershoots).reduce((a, b) => a + b);
  final totalOvershootsA =
      allAdvanced.map((m) => m.forwardOvershoots).reduce((a, b) => a + b);
  _printRow(
    'Total Fwd Overshoots:',
    _fmtInt(totalOvershootsC),
    _fmtInt(totalOvershootsA),
  );

  _printRow(
    'Overall Jitter:',
    _fmtNum(avgMetric(allClassic, (m) => m.jitter)),
    _fmtNum(avgMetric(allAdvanced, (m) => m.jitter)),
  );

  _printRow(
    'Avg Latency (us):',
    _fmtNum(avgMetric(allClassic, (m) => m.avgMatchMicroseconds), decimals: 0),
    _fmtNum(avgMetric(allAdvanced, (m) => m.avgMatchMicroseconds), decimals: 0),
  );

  print('');
}
