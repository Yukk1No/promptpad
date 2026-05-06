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
import '../services/script_matcher_v3.dart';
import '../services/script_matcher_v4.dart';
import '../services/script_matcher_v5.dart';
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
  // V3+ session-reset detection: SpeechService bumps `epoch` on every
  // _listen() restart (silence-triggered, 50s health, manual jump).
  // When epoch changes, the underlying ASR cleared its cumulative-text
  // accumulator — V3 / V4 want to know so they can re-anchor without
  // teleporting the user.
  int _lastSeenEpoch = 0;

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

    // Select tracking algorithm. Accepts MAJOR ids per CLAUDE.md
    // Algorithm Version Policy: 'v1' / 'v2' / 'v3' / 'v3-noisy' / 'v4'.
    // Legacy aliases 'classic' (= v1) and 'advanced' (= v2) are kept
    // for back-compat with users who set the pref before V3 shipped.
    final algorithm = prefs.getString('tracking_algorithm') ?? 'classic';
    ScriptMatcherBase? newMatcher;
    switch (algorithm) {
      case 'v2':
      case 'advanced':
        newMatcher = ScriptMatcherV2();
        break;
      case 'v3':
        newMatcher = ScriptMatcherV3();
        break;
      case 'v3-noisy':
        final m = ScriptMatcherV3();
        m.setNoisyEnvironmentMode(true);
        newMatcher = m;
        break;
      case 'v4':
        newMatcher = ScriptMatcherV4();
        break;
      case 'v5':
        // V5 = V3 + discrimination-gated _resyncMatch. Production-safe
        // fix for the V3 cafe-noise regression (V4's confidence gate is
        // dead in iOS production where partial confidence is 0.0).
        // Beats V3 by 2-5× MAE across noisy conditions, ties on clean.
        newMatcher = ScriptMatcherV5();
        break;
      case 'v1':
      case 'classic':
      default:
        // V1 already loaded in initState as the default — keep it.
        break;
    }
    if (newMatcher != null) {
      newMatcher.loadScript(_script);
      _matcher = newMatcher;
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

    _lastSeenEpoch = _speech.epoch;
    _sub = _speech.events.listen((event) {
      if (event.type == SpeechEventType.transcript) {
        if (event.epoch != _speech.epoch) return;
        // Detect session reset: speech_to_text plugin clears its
        // cumulative-text accumulator on every _listen() restart and
        // SpeechService bumps `epoch`. V3+ wants the explicit signal
        // to re-anchor _matchStartOffset without teleporting the user.
        if (event.epoch != _lastSeenEpoch) {
          _matcher.onSessionReset();
          _lastSeenEpoch = event.epoch;
        }
        // V4 confidence-aware gate: forward the result-level confidence
        // before each match() so V4 can suppress speculative recovery on
        // low-confidence partials. V1/V2/V3 ignore this hook (no-op
        // default in ScriptMatcherBase). speech_to_text reports a single
        // overall confidence per result; V4 treats it as the mean.
        //
        // Default-trust on zero: speech_to_text only populates
        // `confidence` on the final result — partial results carry
        // 0.0 as a "no signal" sentinel, not as "fully untrusted".
        // Forwarding 0.0 verbatim would make V4's gate (threshold 0.6)
        // fire on every post-reset partial in production, silently
        // collapsing V4 to V2. Treat conf <= 0.0 as missing signal and
        // fall back to the default-trust 1.0 so V4 takes the V3 path.
        // See issue #10 for the cross-platform partial-confidence gap.
        final conf = event.confidence;
        _matcher.setNextEventConfidence(conf <= 0.0 ? 1.0 : conf);
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
    // Stale check: every 5 s, if ASR has been silent for long enough,
    // revive the recognizer (do NOT move the matcher — that caused
    // "乱往后跳" when natural pauses teleported the user forward).
    _lastProgressTime = DateTime.now();
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _reviveStaleAsr(),
    );
  }

  /// If no word progress for a long time while running, restart the ASR
  /// session so fresh partials can flow. Previously this also jumped the
  /// matcher forward by one sentence, but that teleported the user past
  /// their actual reading position on any natural 8-second pause. We now
  /// only restart the recognizer and leave position control to the matcher.
  void _reviveStaleAsr() {
    if (!_isRunning || !mounted) return;
    final elapsed = DateTime.now().difference(_lastProgressTime).inSeconds;
    if (elapsed >= 15) {
      _lastProgressTime = DateTime.now();
      _speech.restart();
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
