import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

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

  Stream<SpeechEvent> get events => _controller.stream;
  bool get isListening => _isListening;

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

  Future<void> start({String locale = 'en-US'}) async {
    if (_isListening) return;
    _lastPartial = '';
    _locale = locale;
    try {
      _stt.listen(
        onResult: _onResult,
        localeId: locale,
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          onDevice: true,
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

  void _onResult(SpeechRecognitionResult result) {
    _sessionStart = DateTime.now(); // got a result, session is alive
    final text = result.recognizedWords;
    // Only suppress duplicate non-final partials. Always forward final results.
    if (text == _lastPartial && !result.finalResult) return;
    _lastPartial = text;

    if (!_disposed) {
      _controller.add(SpeechEvent.transcript(
        text: text,
        isFinal: result.finalResult,
        confidence: result.confidence,
      ));
    }
  }

  DateTime _sessionStart = DateTime.now();

  void _onStatus(String status) {
    // speech_to_text stops after silence; auto-restart for continuous listening
    if (status == 'notListening' && _isListening) {
      _lastPartial = ''; // clear accumulated text for fresh session
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_isListening && !_disposed) _listen(_locale);
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
      // Force restart before iOS kills the session at ~60s
      await restart();
      _sessionStart = DateTime.now();
    }
  }

  void _listen(String locale) {
    try {
      _stt.listen(
        onResult: _onResult,
        localeId: locale,
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          onDevice: true,
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
    await _stt.stop();
    _lastPartial = '';
    await Future.delayed(const Duration(milliseconds: 100));
    if (_isListening) _listen(_locale);
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

  SpeechEvent._({
    required this.type,
    required this.text,
    this.isFinal = false,
    this.confidence = 0.0,
  });

  factory SpeechEvent.transcript({
    required String text,
    required bool isFinal,
    required double confidence,
  }) =>
      SpeechEvent._(
        type: SpeechEventType.transcript,
        text: text,
        isFinal: isFinal,
        confidence: confidence,
      );

  factory SpeechEvent.error(String message) =>
      SpeechEvent._(type: SpeechEventType.error, text: message);
}
