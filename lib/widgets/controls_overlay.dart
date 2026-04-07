import 'package:flutter/material.dart';

/// Bottom overlay with play/pause, font size, mirror toggle, and progress.
/// Adapts to portrait (two rows) and landscape (single row).
/// Skip prev/next buttons have moved to ScriptDisplay corners.
class ControlsOverlay extends StatefulWidget {
  final bool initialized;
  final bool isRunning;
  final double fontSize;
  final bool mirrorMode;
  final int currentWord;
  final int totalWords;
  final int currentSentence;
  final int totalSentences;
  final VoidCallback onToggle;
  final VoidCallback onReset;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<bool> onMirrorChanged;
  final VoidCallback onExit;

  const ControlsOverlay({
    super.key,
    required this.initialized,
    required this.isRunning,
    required this.fontSize,
    required this.mirrorMode,
    required this.currentWord,
    required this.totalWords,
    required this.currentSentence,
    required this.totalSentences,
    required this.onToggle,
    required this.onReset,
    required this.onFontSizeChanged,
    required this.onMirrorChanged,
    required this.onExit,
  });

  @override
  State<ControlsOverlay> createState() => _ControlsOverlayState();
}

class _ControlsOverlayState extends State<ControlsOverlay> {
  bool _visible = true;

  Widget _iconBtn(IconData icon, VoidCallback? onPressed, String tooltip) {
    return IconButton(
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
      tooltip: tooltip,
      constraints: const BoxConstraints(),
      padding: const EdgeInsets.all(8),
    );
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.totalWords > 0
        ? widget.currentWord / widget.totalWords
        : 0.0;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Stack(
      children: [
        // Full-screen tap target to toggle visibility
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => setState(() => _visible = !_visible),
          ),
        ),

        // Progress bar (always visible)
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 3,
            backgroundColor: Colors.white10,
            valueColor: AlwaysStoppedAnimation(
              Theme.of(context).colorScheme.primary,
            ),
          ),
        ),

        // Controls panel
        if (_visible)
          Positioned(
            bottom: 8,
            left: 12,
            right: 12,
            child: SafeArea(
              child: GestureDetector(
                onTap: () {}, // absorb taps on panel
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: isLandscape
                      ? _buildLandscapeRow()
                      : _buildPortraitColumn(),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Single row for landscape
  Widget _buildLandscapeRow() {
    return Row(
      children: [
        _iconBtn(Icons.arrow_back_rounded, widget.onExit, 'Exit'),
        const SizedBox(width: 4),
        _playPauseButton(),
        const SizedBox(width: 4),
        _iconBtn(Icons.replay_rounded, widget.onReset, 'Reset'),
        const Spacer(),
        _fontSizeButtons(),
        _mirrorButton(),
        const SizedBox(width: 4),
        _sentenceCounter(),
      ],
    );
  }

  /// Two rows for portrait
  Widget _buildPortraitColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: main controls
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _iconBtn(Icons.arrow_back_rounded, widget.onExit, 'Exit'),
            const SizedBox(width: 8),
            _playPauseButton(),
            const SizedBox(width: 8),
            _iconBtn(Icons.replay_rounded, widget.onReset, 'Reset'),
          ],
        ),
        const SizedBox(height: 6),
        // Row 2: font size, mirror, counter
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _fontSizeButtons(),
            _mirrorButton(),
            const SizedBox(width: 4),
            _sentenceCounter(),
          ],
        ),
      ],
    );
  }

  Widget _playPauseButton() {
    return FilledButton.icon(
      onPressed: widget.initialized ? widget.onToggle : null,
      icon: Icon(
          widget.isRunning ? Icons.pause_rounded : Icons.mic_rounded,
          size: 18),
      label: Text(widget.isRunning ? 'Pause' : 'Start',
          style: const TextStyle(fontSize: 13)),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    );
  }

  Widget _fontSizeButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.text_decrease, size: 18),
          onPressed: widget.fontSize > 28
              ? () => widget.onFontSizeChanged(
                    (widget.fontSize - 4).clamp(28, 56))
              : null,
          tooltip: 'Smaller text',
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(6),
        ),
        Text(
          '${widget.fontSize.round()}',
          style: const TextStyle(fontSize: 11, color: Colors.white38),
        ),
        IconButton(
          icon: const Icon(Icons.text_increase, size: 18),
          onPressed: widget.fontSize < 56
              ? () => widget.onFontSizeChanged(
                    (widget.fontSize + 4).clamp(28, 56))
              : null,
          tooltip: 'Larger text',
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(6),
        ),
      ],
    );
  }

  Widget _mirrorButton() {
    return IconButton(
      icon: Icon(Icons.flip_rounded,
          size: 20,
          color: widget.mirrorMode
              ? Theme.of(context).colorScheme.primary
              : Colors.white54),
      onPressed: () => widget.onMirrorChanged(!widget.mirrorMode),
      tooltip: 'Mirror',
      constraints: const BoxConstraints(),
      padding: const EdgeInsets.all(8),
    );
  }

  Widget _sentenceCounter() {
    return Text(
      '${widget.currentSentence + 1}/${widget.totalSentences}',
      style: const TextStyle(fontSize: 11, color: Colors.white38),
    );
  }
}
