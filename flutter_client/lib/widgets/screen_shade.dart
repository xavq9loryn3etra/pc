import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'ask_orb.dart' show AskClock, AskClockSubscription;

/// A tab's soft glow across the top, as Ask's: three colours fading down
/// into black, drifting slowly about (on AskClock), and blooming down from
/// the top each time the tab's opened. Each tab its own colours (see
/// ScreenScaffold.glow). Plain gradients, drawn straight — no layers.
class TabGlow extends StatefulWidget {
  final List<Color> colors;

  const TabGlow({super.key, required this.colors});

  /// Settings' blues.
  static const settings = [
    Color(0xFF3B82C4),
    Color(0xFF2E6C8E),
    Color(0xFF8CC4EE),
  ];

  /// My List's roses.
  static const myList = [
    Color(0xFFE0457B),
    Color(0xFFB03A5B),
    Color(0xFFF4A3B8),
  ];

  /// Search's purples.
  static const search = [
    Color(0xFF8B5CF6),
    Color(0xFF6D4AB0),
    Color(0xFFC4B5FD),
  ];

  @override
  State<TabGlow> createState() => _TabGlowState();
}

class _TabGlowState extends State<TabGlow> with SingleTickerProviderStateMixin {
  // The bloom down from the top as the tab's opened, as Ask's entrance.
  late final _bloom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  final _clock = AskClockSubscription();
  ValueListenable<TickerModeData>? _tickerMode;
  bool _active = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clock.update(context);
    // The tab's shown when its TickerMode is on (see MovieTabShell): the
    // bloom plays again each time it is.
    _tickerMode?.removeListener(_onTickerMode);
    _tickerMode = TickerMode.getValuesNotifier(context)
      ..addListener(_onTickerMode);
    _onTickerMode();
  }

  void _onTickerMode() {
    final active = _tickerMode?.value.enabled ?? true;
    if (active && !_active) _bloom.forward(from: 0);
    _active = active;
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_onTickerMode);
    _clock.dispose();
    _bloom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _bloom,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_bloom.value);
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scaleY: 0.5 + 0.5 * t,
              alignment: Alignment.topCenter,
              child: child,
            ),
          );
        },
        child: CustomPaint(
          painter: _TabGlowPainter(widget.colors, AskClock.time),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _TabGlowPainter extends CustomPainter {
  final List<Color> colors;
  final ValueListenable<double> time;

  _TabGlowPainter(this.colors, this.time) : super(repaint: time);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final seconds = time.value;
    // As Ask's: where each sits across the top, how strong, how far down.
    const spots = [(0.30, 0.15, 0.95), (0.30, 0.6, 1.0), (0.16, 0.95, 0.85)];
    for (var i = 0; i < spots.length && i < colors.length; i++) {
      final (alpha, x, reach) = spots[i];
      final color = colors[i];
      // Each drifting slowly side to side and swelling a little, on its
      // own pace (a sway every 20–30 seconds).
      final a = seconds * 2 * math.pi / (20 + 5 * i) + i * 2.1;
      final centre = Offset(
          w * (x + 0.12 * math.sin(a)), -h * (0.12 + 0.04 * math.cos(a)));
      final radius = h * reach * (1 + 0.06 * math.sin(a * 0.8));
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: alpha * 0.85),
            color.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_TabGlowPainter old) => old.colors != colors;
}
