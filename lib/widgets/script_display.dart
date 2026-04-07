import 'dart:math';
import 'package:flutter/material.dart';
import '../models/script.dart';

/// Displays the script with word-level highlighting and auto-scroll.
/// Includes a reference line at 1/3 from top.
class ScriptDisplay extends StatefulWidget {
  final Script script;
  final int currentWord;
  final int currentSentence;
  final double fontSize;
  final bool mirror;

  const ScriptDisplay({
    super.key,
    required this.script,
    required this.currentWord,
    required this.currentSentence,
    required this.fontSize,
    this.mirror = false,
  });

  @override
  State<ScriptDisplay> createState() => _ScriptDisplayState();
}

class _ScriptDisplayState extends State<ScriptDisplay> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _wordKeys = {};

  @override
  void initState() {
    super.initState();
    _ensureKeys();
  }

  @override
  void didUpdateWidget(ScriptDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentWord != widget.currentWord) {
      _scrollToCurrentWord();
    }
    if (oldWidget.script != widget.script) {
      _wordKeys.clear();
      _ensureKeys();
    }
  }

  void _ensureKeys() {
    for (var i = 0; i < widget.script.tokens.length; i++) {
      _wordKeys.putIfAbsent(i, () => GlobalKey());
    }
  }

  void _scrollToCurrentWord() {
    final key = _wordKeys[widget.currentWord];
    if (key == null) return;

    final ctx = key.currentContext;
    if (ctx == null) return;

    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;

    final scrollable = _scrollController.position;
    final localOffset = box.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;

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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Build a sentence heading label widget.
  Widget _buildHeading(String heading, double fontSize) {
    return Padding(
      padding: EdgeInsets.only(top: fontSize * 0.4, bottom: 4),
      child: Text(
        heading,
        style: TextStyle(
          fontSize: fontSize * 0.35,
          color: Colors.white24,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.script.tokens;
    final sentences = widget.script.sentences;
    final screenHeight = MediaQuery.of(context).size.height;

    // Build a map: wordIndex -> sentenceIndex for coloring
    // and track which sentence each word belongs to
    final wordToSentence = <int, int>{};
    var wordIdx = 0;
    for (var si = 0; si < sentences.length; si++) {
      final sentenceWords = sentences[si].rawText.split(RegExp(r'\s+'));
      for (final _ in sentenceWords) {
        if (wordIdx < tokens.length) {
          wordToSentence[wordIdx] = si;
          wordIdx++;
        }
      }
    }

    // Build heading insertion points: sentenceIndex -> heading text
    final headingBefore = <int, String>{};
    for (final s in sentences) {
      if (s.heading != null) {
        headingBefore[s.index] = s.heading!;
      }
    }

    // Find first word index of each sentence
    final sentenceStartWord = <int, int>{};
    for (final entry in wordToSentence.entries) {
      sentenceStartWord.putIfAbsent(entry.value, () => entry.key);
    }

    final child = Stack(
        children: [
          SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: 32,
              vertical: screenHeight * 0.4,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: widget.fontSize * 0.4,
              children: List.generate(tokens.length, (i) {
                final token = tokens[i];
                final isCurrent = i == widget.currentWord;
                final isPast = i < widget.currentWord;

                final opacity = isCurrent
                    ? 1.0
                    : isPast
                        ? 0.3
                        : max(0.5, 1.0 - (i - widget.currentWord) * 0.01);

                // Check if we need a heading before this word
                final sentenceIdx = wordToSentence[i];
                final isFirstWordOfSentence =
                    sentenceIdx != null && sentenceStartWord[sentenceIdx] == i;
                final heading = isFirstWordOfSentence
                    ? headingBefore[sentenceIdx]
                    : null;

                final wordWidget = AnimatedOpacity(
                  key: _wordKeys[i],
                  opacity: opacity,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    token.raw,
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
                );

                if (heading != null) {
                  // Force a full-width line break before the heading
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(width: double.infinity),
                      _buildHeading(heading, widget.fontSize),
                      wordWidget,
                    ],
                  );
                }

                return wordWidget;
              }),
            ),
          ),

          // Reference line at 1/3 from top
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
