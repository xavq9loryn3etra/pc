import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/app_mode_service.dart';
import 'ask_orb.dart' show AskClock, AskClockSubscription;

/// A tab's soft glow across the top, as Ask's: three colours fading down
/// into black, drifting slowly about (on AskClock), and blooming down from
/// the top as it comes on screen. One glow for every tab but Ask's, in the
/// open mode's colour ([forMode]; owner, 24 Nov 2026) — so going from one
/// of those tabs to another (or back from Settings' own pages) it stays
/// as it is rather than blooming again. Plain gradients, drawn straight —
/// no layers.
class TabGlow extends StatefulWidget {
  final List<Color> colors;

  /// Whether it blooms in as it's shown. Off for Settings' own pages (Sync,
  /// Gemini key): the same glow is already on the screen they open over.
  final bool blooms;

  const TabGlow({super.key, required this.colors, this.blooms = true});

  /// The glow of the open mode's tabs (all but Ask): its colour (Popcorn's
  /// cream, Ramen's orange), a deeper shade of it and a lighter one.
  static List<Color> get forMode {
    final base = AppModeService().currentMode.value.accentColor;
    final hsl = HSLColor.fromColor(base);
    return [
      base,
      hsl
          .withLightness((hsl.lightness - 0.22).clamp(0.0, 1.0))
          .toColor(),
      hsl
          .withLightness((hsl.lightness + 0.12).clamp(0.0, 0.92))
          .toColor(),
    ];
  }

  // How many glows are on screen, and when the last one went: one coming
  // on while another is, or just was (a tab switch, a page closing), is
  // the same glow carrying on — it doesn't bloom again.
  static int _onScreen = 0;
  static DateTime _lastLeft = DateTime.fromMillisecondsSinceEpoch(0);
  static bool get _glowShowing =>
      _onScreen > 0 ||
      DateTime.now().difference(_lastLeft) < const Duration(milliseconds: 600);

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
  ModalRoute<dynamic>? _route;
  bool _active = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
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
    if (active && !_active) {
      // Coming back from a page that was over this one (Sync, Gemini key),
      // or from another tab with the same glow: it's been on screen all
      // along, so it isn't played again.
      final uncovered = (_route?.secondaryAnimation?.value ?? 0) > 0;
      if (widget.blooms && !uncovered && !TabGlow._glowShowing) {
        _bloom.forward(from: 0);
      } else {
        _bloom.value = 1;
      }
      TabGlow._onScreen++;
    } else if (!active && _active) {
      _leave();
    }
    _active = active;
  }

  void _leave() {
    TabGlow._onScreen--;
    TabGlow._lastLeft = DateTime.now();
  }

  @override
  void dispose() {
    if (_active) _leave();
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
