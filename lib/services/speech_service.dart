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
  String _lastPartial = '';
  String _locale = 'en-US';

  Stream<SpeechEvent> get events => _controller.stream;
  bool get isListening => _isListening;

  Future<bool> initialize() async {
    return _stt.initialize(
      onStatus: _onStatus,
      onError: (error) {
        _controller.add(SpeechEvent.error(error.errorMsg));
      },
    );
  }

  Future<void> start({String locale = 'en-US'}) async {
    if (_isListening) return;
    _isListening = true;
    _lastPartial = '';
    _locale = locale;
    _listen(locale);
  }

  void _listen(String locale) {
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
  }

  void _onResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords;
    if (text == _lastPartial) return;
    _lastPartial = text;

    _controller.add(SpeechEvent.transcript(
      text: text,
      isFinal: result.finalResult,
      confidence: result.confidence,
    ));
  }

  void _onStatus(String status) {
    // speech_to_text stops after silence; auto-restart for continuous listening
    if (status == 'notListening' && _isListening) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_isListening) _listen(_locale);
      });
    }
  }

  Future<void> stop() async {
    _isListening = false;
    await _stt.stop();
  }

  void dispose() {
    _isListening = false;
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
