import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../models/script.dart';
import '../services/speech_service.dart';
import '../services/script_matcher_base.dart';
import '../services/script_matcher.dart';
import '../services/script_matcher_v2.dart';
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
  late ScriptMatcherBase _matcher;
  late final Script _script;

  StreamSubscription<SpeechEvent>? _sub;
  Timer? _healthTimer;
  Timer? _staleTimer;
  double? _savedBrightness;
  bool _isRunning = false;
  bool _initialized = false;
  String _error = '';
  int _currentWord = 0;
  int _currentSentence = 0;
  DateTime _lastProgressTime = DateTime.now();
  double _fontSize = 42;
  bool _mirrorMode = false;
  String _lastTranscript = '';
  String _locale = 'en-US';
  bool _onDevice = true;

  @override
  void initState() {
    super.initState();
    _script = Script.fromText(widget.scriptText);
    // Matcher is initialized in _initAll after loading prefs
    _matcher = ScriptMatcher(); // default, replaced after prefs load
    _matcher.loadScript(_script);
    _initAll();
  }

  Future<void> _initAll() async {
    // Load settings FIRST, then init speech with correct locale
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _locale = prefs.getString('speech_locale') ?? 'en-US';
    _onDevice = prefs.getBool('on_device') ?? true;
    final savedFontSize = prefs.getDouble('default_font_size');
    if (savedFontSize != null) {
      setState(() => _fontSize = savedFontSize);
    }

    // Select tracking algorithm
    final algorithm = prefs.getString('tracking_algorithm') ?? 'classic';
    if (algorithm == 'advanced') {
      final advMatcher = ScriptMatcherV2();
      advMatcher.loadScript(_script);
      _matcher = advMatcher;
    }

    await _initSpeech();
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
        if (event.epoch != _speech.epoch) return;
        final prevWord = _currentWord;
        final pos = _matcher.match(event.text, isFinal: event.isFinal);
        if (event.epoch != _speech.epoch) return;
        if (pos != prevWord) _lastProgressTime = DateTime.now();
        setState(() {
          _currentWord = pos;
          _currentSentence = _matcher.currentSentence;
          _lastTranscript = event.text;
        });
      } else if (event.type == SpeechEventType.error) {
        // Don't show transient ASR errors — auto-restart handles them
      }
    });
  }

  void _toggle() async {
    if (_isRunning) {
      _speech.stop();
      _stopScreenKeepAlive();
    } else {
      _speech.start(locale: _locale, onDevice: _onDevice);
      _startScreenKeepAlive();
    }
    setState(() => _isRunning = !_isRunning);
  }

  /// Keep screen on and brightness max while running.
  Future<void> _startScreenKeepAlive() async {
    WakelockPlus.enable();
    try {
      _savedBrightness = await ScreenBrightness().application;
      await ScreenBrightness().setApplicationScreenBrightness(1.0);
    } catch (_) {
      // brightness API may not be available
    }
    // Health check every 30s to prevent ASR stalling
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _speech.healthCheck(),
    );
    // Stale check every 5s: if no progress while ASR is active, auto-advance 1 sentence
    _lastProgressTime = DateTime.now();
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkStaleAndAdvance(),
    );
  }

  /// If no word progress for 8+ seconds while running, auto-advance 1 sentence.
  void _checkStaleAndAdvance() {
    if (!_isRunning || !mounted) return;
    if (_script.sentences.isEmpty) return;
    final elapsed = DateTime.now().difference(_lastProgressTime).inSeconds;
    if (elapsed >= 8 && _currentSentence < _script.sentences.length - 1) {
      _matcher.jumpToSentence(_currentSentence + 1);
      _lastProgressTime = DateTime.now();
      setState(() {
        _currentSentence = _matcher.currentSentence;
        _currentWord = _matcher.confirmedPosition;
      });
      if (_isRunning) _speech.restart();
    }
  }

  Future<void> _stopScreenKeepAlive() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    WakelockPlus.disable();
    try {
      if (_savedBrightness != null) {
        await ScreenBrightness()
            .setApplicationScreenBrightness(_savedBrightness!);
      } else {
        await ScreenBrightness().resetApplicationScreenBrightness();
      }
    } catch (_) {}
  }

  void _resetPosition() async {
    final wasRunning = _isRunning;
    if (wasRunning) await _speech.stop();
    _matcher.reset();
    setState(() {
      _currentWord = 0;
      _currentSentence = 0;
      _lastTranscript = '';
      _isRunning = false;
    });
    if (wasRunning) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) {
        _speech.start(locale: _locale, onDevice: _onDevice);
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
      _lastTranscript = '';
    });
    if (_isRunning) _speech.restart();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _healthTimer?.cancel();
    _staleTimer?.cancel();
    _speech.dispose();
    _stopScreenKeepAlive();
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

            // Transcript bar — last ~50 chars, right-aligned with left ellipsis
            if (_lastTranscript.isNotEmpty && _isRunning)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  height: 28,
                  alignment: Alignment.centerRight,
                  child: Text(
                    _lastTranscript.length > 50
                        ? '...\u200B${_lastTranscript.substring(_lastTranscript.length - 50)}'
                        : _lastTranscript,
                    style: const TextStyle(fontSize: 11, color: Colors.white30),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
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
              onFontSizeChanged: (v) => setState(() => _fontSize = v),
              onMirrorChanged: (v) => setState(() => _mirrorMode = v),
              onExit: () => Navigator.pop(context),
            ),

            // Skip buttons — above everything so they're always tappable
            if (_script.sentences.length > 1)
              Positioned(
                top: 8,
                left: 8,
                child: Opacity(
                  opacity: 0.5,
                  child: IconButton(
                    icon: const Icon(Icons.chevron_left, size: 28, color: Colors.white),
                    onPressed: () => _skipSentence(-1),
                    tooltip: 'Previous sentence',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                ),
              ),
            if (_script.sentences.length > 1)
              Positioned(
                top: 8,
                right: 8,
                child: Opacity(
                  opacity: 0.5,
                  child: IconButton(
                    icon: const Icon(Icons.chevron_right, size: 28, color: Colors.white),
                    onPressed: () => _skipSentence(1),
                    tooltip: 'Next sentence',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(8),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
