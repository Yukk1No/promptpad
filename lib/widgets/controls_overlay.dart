import 'package:flutter/material.dart';

/// Bottom overlay with play/pause, font size, mirror toggle, and progress.
class ControlsOverlay extends StatefulWidget {
  final bool initialized;
  final bool isRunning;
  final double fontSize;
  final bool mirrorMode;
  final int currentWord;
  final int totalWords;
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

  @override
  Widget build(BuildContext context) {
    final progress = widget.totalWords > 0
        ? widget.currentWord / widget.totalWords
        : 0.0;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => setState(() => _visible = !_visible),
      child: Stack(
        children: [
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
              left: 16,
              right: 16,
              child: SafeArea(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      // Exit
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: widget.onExit,
                        tooltip: 'Exit',
                      ),

                      const SizedBox(width: 8),

                      // Play / Pause
                      FilledButton.icon(
                        onPressed: widget.initialized ? widget.onToggle : null,
                        icon: Icon(widget.isRunning
                            ? Icons.pause_rounded
                            : Icons.mic_rounded),
                        label: Text(widget.isRunning ? 'Pause' : 'Start'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // Reset
                      IconButton(
                        icon: const Icon(Icons.replay_rounded),
                        onPressed: widget.onReset,
                        tooltip: 'Reset to start',
                      ),

                      const Spacer(),

                      // Font size
                      const Icon(Icons.text_fields, size: 18,
                          color: Colors.white54),
                      SizedBox(
                        width: 120,
                        child: Slider(
                          value: widget.fontSize,
                          min: 24,
                          max: 72,
                          onChanged: widget.onFontSizeChanged,
                        ),
                      ),

                      // Mirror toggle
                      IconButton(
                        icon: Icon(
                          Icons.flip_rounded,
                          color: widget.mirrorMode
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white54,
                        ),
                        onPressed: () =>
                            widget.onMirrorChanged(!widget.mirrorMode),
                        tooltip: 'Mirror mode',
                      ),

                      // Word count
                      Text(
                        '${widget.currentWord}/${widget.totalWords}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white38),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
