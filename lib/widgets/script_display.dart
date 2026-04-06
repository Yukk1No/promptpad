import 'dart:math';
import 'package:flutter/material.dart';
import '../models/script.dart';

/// Displays the script with word-level highlighting and auto-scroll.
class ScriptDisplay extends StatefulWidget {
  final Script script;
  final int currentWord;
  final double fontSize;
  final bool mirror;

  const ScriptDisplay({
    super.key,
    required this.script,
    required this.currentWord,
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

    // Target: keep current word at 1/3 from top
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

  @override
  Widget build(BuildContext context) {
    final tokens = widget.script.tokens;

    final child = SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(
        horizontal: 32,
        vertical: MediaQuery.of(context).size.height * 0.4,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: widget.fontSize * 0.4,
        children: List.generate(tokens.length, (i) {
          final token = tokens[i];
          final isCurrent = i == widget.currentWord;
          final isPast = i < widget.currentWord;

          // Fade: past words dim, future words slightly dim, current bright
          final opacity = isCurrent
              ? 1.0
              : isPast
                  ? 0.3
                  : max(0.5, 1.0 - (i - widget.currentWord) * 0.01);

          return AnimatedOpacity(
            key: _wordKeys[i],
            opacity: opacity,
            duration: const Duration(milliseconds: 200),
            child: Text(
              token.raw,
              style: TextStyle(
                fontSize: widget.fontSize,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w300,
                color: isCurrent
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
                height: 1.5,
              ),
            ),
          );
        }),
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
