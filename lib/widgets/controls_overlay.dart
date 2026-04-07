import 'package:flutter/material.dart';

/// Bottom overlay with play/pause, skip, font size, mirror toggle, and progress.
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
  final ValueChanged<int> onSkip;
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
    required this.onSkip,
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

    final hasSkipTargets = widget.totalSentences > 0;

    return Stack(
      children: [
        // Bottom layer: full-screen transparent tap target to toggle visibility
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
            left: 16,
            right: 16,
            child: SafeArea(
              child: GestureDetector(
                // Prevent taps on the panel from toggling visibility
                onTap: () {},
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      // Exit
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, size: 20),
                        onPressed: widget.onExit,
                        tooltip: 'Exit',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(8),
                      ),

                      const SizedBox(width: 4),

                      // Play / Pause
                      FilledButton.icon(
                        onPressed: widget.initialized ? widget.onToggle : null,
                        icon: Icon(widget.isRunning
                            ? Icons.pause_rounded
                            : Icons.mic_rounded,
                            size: 18),
                        label: Text(widget.isRunning ? 'Pause' : 'Start'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      ),

                      const SizedBox(width: 4),

                      // Skip prev
                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded, size: 20),
                        onPressed: hasSkipTargets
                            ? () => widget.onSkip(-1)
                            : null,
                        tooltip: 'Previous sentence',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(8),
                      ),

                      // Skip next
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded, size: 20),
                        onPressed: hasSkipTargets
                            ? () => widget.onSkip(1)
                            : null,
                        tooltip: 'Next sentence',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(8),
                      ),

                      // Reset
                      IconButton(
                        icon: const Icon(Icons.replay_rounded, size: 20),
                        onPressed: widget.onReset,
                        tooltip: 'Reset',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(8),
                      ),

                      const Spacer(),

                      // Font size
                      const Icon(Icons.text_fields, size: 16,
                          color: Colors.white54),
                      SizedBox(
                        width: 100,
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
                          size: 20,
                          color: widget.mirrorMode
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white54,
                        ),
                        onPressed: () =>
                            widget.onMirrorChanged(!widget.mirrorMode),
                        tooltip: 'Mirror mode',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(8),
                      ),

                      const SizedBox(width: 4),

                      // Sentence counter
                      Text(
                        '${widget.currentSentence + 1}/${widget.totalSentences}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
