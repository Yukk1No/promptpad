import 'dart:async';
import 'package:flutter/material.dart';
import '../models/script.dart';
import '../services/speech_service.dart';
import '../services/script_matcher.dart';
import '../widgets/script_display.dart';
import '../widgets/controls_overlay.dart';

class TeleprompterScreen extends StatefulWidget {
  final String scriptText;
  const TeleprompterScreen({super.key, required this.scriptText});

  @override
  State<TeleprompterScreen> createState() => _TeleprompterScreenState();
}

class _TeleprompterScreenState extends State<TeleprompterScreen> {
  final SpeechService _speech = SpeechService();
  final ScriptMatcher _matcher = ScriptMatcher();
  late final Script _script;

  StreamSubscription<SpeechEvent>? _sub;
  bool _isRunning = false;
  bool _initialized = false;
  String _error = '';
  int _currentWord = 0;
  double _fontSize = 42;
  bool _mirrorMode = false;
  String _lastTranscript = '';

  @override
  void initState() {
    super.initState();
    _script = Script.fromText(widget.scriptText);
    _matcher.loadScript(_script);
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    final ok = await _speech.initialize();
    if (!ok) {
      setState(() => _error = 'Microphone permission denied');
      return;
    }
    setState(() => _initialized = true);

    _sub = _speech.events.listen((event) {
      if (event.type == SpeechEventType.transcript) {
        final pos = _matcher.match(event.text, isFinal: event.isFinal);
        setState(() {
          _currentWord = pos;
          _lastTranscript = event.text;
        });
      } else if (event.type == SpeechEventType.error) {
        setState(() => _error = event.text);
      }
    });
  }

  void _toggle() {
    if (_isRunning) {
      _speech.stop();
    } else {
      _speech.start();
    }
    setState(() => _isRunning = !_isRunning);
  }

  void _resetPosition() {
    _matcher.reset();
    setState(() {
      _currentWord = 0;
      _lastTranscript = '';
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _speech.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mic_off, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          // Script display — the core view
          ScriptDisplay(
            script: _script,
            currentWord: _currentWord,
            fontSize: _fontSize,
            mirror: _mirrorMode,
          ),

          // Debug transcript bar (top)
          if (_lastTranscript.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black54,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  _lastTranscript,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white38),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),

          // Controls overlay (bottom)
          ControlsOverlay(
            initialized: _initialized,
            isRunning: _isRunning,
            fontSize: _fontSize,
            mirrorMode: _mirrorMode,
            currentWord: _currentWord,
            totalWords: _script.tokens.length,
            onToggle: _toggle,
            onReset: _resetPosition,
            onFontSizeChanged: (v) => setState(() => _fontSize = v),
            onMirrorChanged: (v) => setState(() => _mirrorMode = v),
            onExit: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
