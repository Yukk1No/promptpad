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
  int _currentSentence = 0;
  double _fontSize = 42;
  bool _mirrorMode = false;
  String _lastTranscript = '';
  int _generation = 0; // increments on reset to ignore stale ASR events

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
        final gen = _generation;
        final pos = _matcher.match(event.text, isFinal: event.isFinal);
        if (gen != _generation) return; // reset happened during processing
        setState(() {
          _currentWord = pos;
          _currentSentence = _matcher.currentSentence;
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

  void _resetPosition() async {
    _generation++; // invalidate any in-flight ASR events
    final wasRunning = _isRunning;
    if (wasRunning) await _speech.stop();
    _matcher.reset();
    setState(() {
      _currentWord = 0;
      _currentSentence = 0;
      _lastTranscript = '';
      _isRunning = false;
    });
    // Restart ASR with a fresh session if it was running
    if (wasRunning) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) {
        _speech.start();
        setState(() => _isRunning = true);
      }
    }
  }

  void _skipSentence(int delta) {
    if (_script.sentences.isEmpty) return;
    final newIndex = (_currentSentence + delta)
        .clamp(0, _script.sentences.length - 1);
    _matcher.jumpToSentence(newIndex);
    setState(() {
      _currentSentence = newIndex;
      _currentWord = _matcher.confirmedPosition;
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
      body: SafeArea(
        child: Stack(
        children: [
          ScriptDisplay(
            script: _script,
            currentWord: _currentWord,
            currentSentence: _currentSentence,
            fontSize: _fontSize,
            mirror: _mirrorMode,
          ),

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
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),

          ControlsOverlay(
            initialized: _initialized,
            isRunning: _isRunning,
            fontSize: _fontSize,
            mirrorMode: _mirrorMode,
            currentWord: _currentWord,
            totalWords: _script.tokens.length,
            currentSentence: _currentSentence,
            totalSentences: _script.sentences.length,
            onToggle: _toggle,
            onReset: _resetPosition,
            onSkip: _skipSentence,
            onFontSizeChanged: (v) => setState(() => _fontSize = v),
            onMirrorChanged: (v) => setState(() => _mirrorMode = v),
            onExit: () => Navigator.pop(context),
          ),
        ],
      ),
      ),
    );
  }
}
