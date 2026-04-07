import 'dart:math';
import 'package:flutter/material.dart';
import '../models/script.dart';

/// Displays the script with sentence-level highlighting and auto-scroll.
/// Includes a horizontal reference line at 1/3 from the top of the screen.
class ScriptDisplay extends StatefulWidget {
  final Script script;
  final int currentSentence;
  final double fontSize;
  final bool mirror;
  final ValueChanged<int>? onTapSkip;

  const ScriptDisplay({
    super.key,
    required this.script,
    required this.currentSentence,
    required this.fontSize,
    this.mirror = false,
    this.onTapSkip,
  });

  @override
  State<ScriptDisplay> createState() => _ScriptDisplayState();
}

class _ScriptDisplayState extends State<ScriptDisplay> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _sentenceKeys = {};

  @override
  void initState() {
    super.initState();
    _ensureKeys();
  }

  @override
  void didUpdateWidget(ScriptDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSentence != widget.currentSentence) {
      _scrollToCurrentSentence();
    }
    if (oldWidget.script != widget.script) {
      _sentenceKeys.clear();
      _ensureKeys();
    }
  }

  void _ensureKeys() {
    for (var i = 0; i < widget.script.sentences.length; i++) {
      _sentenceKeys.putIfAbsent(i, () => GlobalKey());
    }
  }

  void _scrollToCurrentSentence() {
    final key = _sentenceKeys[widget.currentSentence];
    if (key == null) return;

    final ctx = key.currentContext;
    if (ctx == null) return;

    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;

    final scrollable = _scrollController.position;
    final localOffset = box.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;

    // Target: keep current sentence at 1/3 from top
    final targetY = screenHeight / 3;
    final diff = localOffset.dy - targetY;
    final newOffset = (_scrollController.offset + diff)
        .clamp(0.0, scrollable.maxScrollExtent);

    _scrollController.animateTo(
      newOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _handleTap(TapUpDetails details) {
    if (widget.onTapSkip == null) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final tapY = details.globalPosition.dy;

    if (tapY < screenHeight / 2) {
      // Upper half: advance to next sentence
      widget.onTapSkip!(1);
    } else {
      // Lower half: go back to previous sentence
      widget.onTapSkip!(-1);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sentences = widget.script.sentences;
    final screenHeight = MediaQuery.of(context).size.height;

    final child = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: _handleTap,
      child: Stack(
        children: [
          // Scrollable sentence list
          SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: 32,
              vertical: screenHeight * 0.4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(sentences.length, (i) {
                final sentence = sentences[i];
                final isCurrent = i == widget.currentSentence;
                final isPast = i < widget.currentSentence;

                // Opacity: current = 1.0, past = 0.3, future fades gently
                final opacity = isCurrent
                    ? 1.0
                    : isPast
                        ? 0.3
                        : max(0.5, 1.0 - (i - widget.currentSentence) * 0.05);

                return AnimatedOpacity(
                  key: _sentenceKeys[i],
                  opacity: opacity,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: widget.fontSize * 0.6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Markdown heading annotation
                        if (sentence.heading != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              sentence.heading!,
                              style: TextStyle(
                                fontSize: widget.fontSize * 0.35,
                                color: Colors.white24,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        // Sentence text
                        if (sentence.displayText.isNotEmpty)
                          Text(
                            sentence.displayText,
                            style: TextStyle(
                              fontSize: widget.fontSize,
                              fontWeight:
                                  isCurrent ? FontWeight.bold : FontWeight.w300,
                              color: isCurrent
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white,
                              height: 1.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),

          // Reference/guide line at 1/3 from top
          Positioned(
            top: screenHeight / 3,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: 2,
                color: Theme.of(context).colorScheme.primary.withAlpha(40),
              ),
            ),
          ),
        ],
      ),
    );

    if (widget.mirror) {
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
        child: child,
      );
    }

    return child;
  }
}
