import 'dart:async';
import 'dart:convert';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

/// P0.0 cadence calibration. Build with:
///   flutter run --dart-define=CADENCE_CALIBRATION=true
/// then `adb logcat | grep CADENCE` (Android) or read the Xcode console (iOS).
/// Pipe into benchmark/cadence/calibrate.py to extract profile parameters.
const bool _kCadenceCalib = bool.fromEnvironment('CADENCE_CALIBRATION');
void _calibLog(String kind, [Map<String, Object?> extra = const {}]) {
  if (!_kCadenceCalib) return;
  // ignore: avoid_print
  print('CADENCE: ${jsonEncode({
    't': DateTime.now().millisecondsSinceEpoch,
    'kind': kind,
    ...extra,
  })}');
}

/// Platform-agnostic speech recognition service.
/// iOS: SFSpeechRecognizer (on-device when available)
/// Android: Google Speech Services
class SpeechService {
  final SpeechToText _stt = SpeechToText();
  final _controller = StreamController<SpeechEvent>.broadcast();
  bool _isListening = false;
  bool _disposed = false;
  String _lastPartial = '';
  String _locale = 'en-US';
  int _resultEpoch = 0;
  bool _manualRestart = false;
  bool _onDevice = true;

  Stream<SpeechEvent> get events => _controller.stream;
  bool get isListening => _isListening;
  int get epoch => _resultEpoch;

  Future<bool> initialize() async {
    return _stt.initialize(
      onStatus: _onStatus,
      onError: (error) {
        if (!_disposed) {
          _controller.add(SpeechEvent.error(error.errorMsg));
        }
      },
    );
  }

  Future<void> start({String locale = 'en-US', bool onDevice = true}) async {
    if (_isListening) return;
    _lastPartial = '';
    _locale = locale;
    _onDevice = onDevice;
    try {
      final epoch = ++_resultEpoch;
      _calibLog('session_start', {'epoch': epoch, 'reason': 'manual_start'});
      _stt.listen(
        onResult: (result) => _onResult(result, epoch),
        localeId: locale,
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          onDevice: onDevice,
        ),
      );
      _isListening = true;
    } catch (e) {
      _isListening = false;
      if (!_disposed) {
        _controller.add(SpeechEvent.error(e.toString()));
      }
    }
  }

  void _onResult(SpeechRecognitionResult result, int epoch) {
    if (epoch != _resultEpoch) return; // discard stale session results
    _sessionStart = DateTime.now(); // got a result, session is alive
    final text = result.recognizedWords;
    _calibLog('result', {
      'epoch': epoch,
      'is_final': result.finalResult,
      'text_len': text.length,
      'text': text,
    });
    // Only suppress duplicate non-final partials. Always forward final results.
    if (text == _lastPartial && !result.finalResult) return;
    _lastPartial = text;

    if (!_disposed) {
      _controller.add(SpeechEvent.transcript(
        text: text,
        isFinal: result.finalResult,
        confidence: result.confidence,
        epoch: epoch,
      ));
    }
  }

  DateTime _sessionStart = DateTime.now();

  void _onStatus(String status) {
    _calibLog('status', {'status': status, 'manual_restart': _manualRestart});
    // speech_to_text stops after silence; auto-restart for continuous listening
    if (status == 'notListening' && _isListening && !_manualRestart) {
      _lastPartial = ''; // clear accumulated text for fresh session
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_isListening && !_disposed && !_manualRestart) _listen(_locale);
      });
    }
  }

  /// Periodic health check — call from a timer to prevent ASR stalling.
  /// iOS SFSpeechRecognizer can hang after ~1 min continuous use.
  /// Force-restarts the session if no result received for too long.
  Future<void> healthCheck() async {
    if (!_isListening || _disposed) return;
    final elapsed = DateTime.now().difference(_sessionStart).inSeconds;
    if (elapsed > 50) {
      _calibLog('health_check_restart', {'elapsed_s': elapsed});
      // Force restart before iOS kills the session at ~60s
      await restart();
      _sessionStart = DateTime.now();
    }
  }

  void _listen(String locale) {
    try {
      final epoch = ++_resultEpoch;
      _calibLog('session_start', {'epoch': epoch, 'reason': 'auto_relisten'});
      _stt.listen(
        onResult: (result) => _onResult(result, epoch),
        localeId: locale,
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          onDevice: _onDevice,
        ),
      );
    } catch (e) {
      _isListening = false;
      if (!_disposed) {
        _controller.add(SpeechEvent.error(e.toString()));
      }
    }
  }

  /// Restart the ASR session with a fresh accumulator.
  /// Call this when the matcher position changes (reset/jump).
  Future<void> restart() async {
    if (!_isListening) return;
    _calibLog('manual_restart_begin');
    _manualRestart = true;
    _resultEpoch++; // invalidate in-flight results before stop
    await _stt.stop();
    _lastPartial = '';
    _resultEpoch++; // invalidate any results queued during stop
    await Future.delayed(const Duration(milliseconds: 100));
    _manualRestart = false;
    if (_isListening && !_disposed) _listen(_locale);
  }

  Future<void> stop() async {
    _isListening = false;
    await _stt.stop();
  }

  void dispose() {
    _isListening = false;
    _disposed = true;
    _stt.stop();
    _controller.close();
  }
}

enum SpeechEventType { transcript, error }

class SpeechEvent {
  final SpeechEventType type;
  final String text;
  final bool isFinal;
  final double confidence;
  final int epoch;

  SpeechEvent._({
    required this.type,
    required this.text,
    this.isFinal = false,
    this.confidence = 0.0,
    this.epoch = 0,
  });

  factory SpeechEvent.transcript({
    required String text,
    required bool isFinal,
    required double confidence,
    required int epoch,
  }) =>
      SpeechEvent._(
        type: SpeechEventType.transcript,
        text: text,
        isFinal: isFinal,
        confidence: confidence,
        epoch: epoch,
      );

  factory SpeechEvent.error(String message) =>
      SpeechEvent._(type: SpeechEventType.error, text: message);
}
