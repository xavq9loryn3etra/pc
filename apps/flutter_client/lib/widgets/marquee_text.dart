import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Single-line text that, when it doesn't fit, scrolls sideways on a loop
/// with both edges faded — pausing each time its start comes back to the
/// left edge. Text that fits (or reduced motion) is shown as-is.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  /// Shown between the end of [text] and its repeat.
  final String separator;

  /// Scroll speed, in logical pixels per second.
  final double velocity;

  /// How long the start of the text rests at the left edge.
  final Duration pause;

  /// Width of the faded edges.
  final double fadeWidth;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.separator = '',
    this.velocity = 30,
    this.pause = const Duration(seconds: 2),
    this.fadeWidth = 24,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  // Created up front, not lazily: text that fits never touches it before
  // dispose(), where creating it would look up an already-detached tree.
  late final AnimationController _controller;

  // Scroll distance of one loop (text + separator); null while not
  // scrolling.
  double? _cycle;
  // Bumped to end the current loop.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Layout decides whether to scroll, but the controller can't be touched
  // mid-build — so apply the decision after the frame.
  void _schedule(double? cycle) {
    if (cycle == _cycle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || cycle == _cycle) return;
      _cycle = cycle;
      _run++;
      _controller
        ..stop()
        ..value = 0;
      if (cycle == null) return;
      _controller.duration =
          Duration(milliseconds: (cycle / widget.velocity * 1000).round());
      _loop(_run);
    });
  }

  Future<void> _loop(int run) async {
    while (true) {
      await Future.delayed(widget.pause);
      if (!mounted || run != _run) return;
      try {
        await _controller.forward(from: 0).orCancel;
      } on TickerCanceled {
        return;
      }
      if (!mounted || run != _run) return;
      // The repeat now sits exactly where the start was, so jumping back
      // is seamless.
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    return LayoutBuilder(builder: (context, constraints) {
      final textScaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: 1,
        textDirection: direction,
        textScaler: textScaler,
      )..layout();
      final textWidth = painter.width;
      final height = painter.height;
      painter.dispose();

      final width = constraints.maxWidth;
      if (textWidth <= width || MediaQuery.disableAnimationsOf(context)) {
        _schedule(null);
        return Text(
          widget.text,
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }

      final separatorPainter = TextPainter(
        text: TextSpan(text: widget.separator, style: style),
        maxLines: 1,
        textDirection: direction,
        textScaler: textScaler,
      )..layout();
      final cycle = textWidth + separatorPainter.width;
      separatorPainter.dispose();
      _schedule(cycle);

      Widget line(String text) =>
          Text(text, style: style, maxLines: 1, softWrap: false);

      return SizedBox(
        width: width,
        height: height,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final dx = _controller.value * cycle;
              // The left fade eases in as the start leaves the edge and out
              // as the repeat arrives, so the first word reads clearly
              // while resting there.
              final left =
                  math.min(widget.fadeWidth, math.min(dx, cycle - dx)) / width;
              final right = widget.fadeWidth / width;
              return ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => LinearGradient(
                  colors: const [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [0, left, 1 - right, 1],
                ).createShader(rect),
                child: Transform.translate(
                  offset: Offset(-dx, 0),
                  child: child,
                ),
              );
            },
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  line(widget.text),
                  line(widget.separator),
                  ExcludeSemantics(child: line(widget.text)),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
