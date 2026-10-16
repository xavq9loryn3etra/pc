import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Startup intro shown while main.dart's config/first-launch checks run.
/// The popcorn icon behaves like a lump of jelly, straight out of the
/// (plain black) native launch screen:
///
///  1. It drops in from above, stretching slightly as it falls.
///  2. It lands with a squash, bounces once and wobbles (squash/stretch
///     plus a side-to-side sway anchored at its base) until it settles.
///
/// The icon then stays put until the intro has played *and* [ready] is
/// true, when [onFinished] fires and main.dart cross-fades to the next
/// screen.
///
/// Not a Scaffold — main.dart wraps it so the shader warmup widget can sit
/// alongside it.
class SplashScreen extends StatefulWidget {
  /// Whether the app has decided which screen comes next.
  final bool ready;
  final VoidCallback onFinished;

  const SplashScreen({
    super.key,
    required this.ready,
    required this.onFinished,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _iconSize = 130.0;
  static const _fallSeconds = 0.35;
  // The wobble has died down by about here.
  static const _settledSeconds = 1.1;
  // Short hold so the finished frame registers before moving on.
  static const _introSeconds = _settledSeconds + 0.4;

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_introSeconds * 1000).round()),
  );

  bool _started = false;
  bool _finished = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    // Respect the OS "remove animations" setting: show the finished frame
    // and move on as soon as the app is ready.
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
      _maybeFinish();
      return;
    }

    _intro.addStatusListener((status) {
      if (status == AnimationStatus.completed) _maybeFinish();
    });
    _intro.forward();
  }

  @override
  void didUpdateWidget(SplashScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready) _maybeFinish();
  }

  void _maybeFinish() {
    if (!widget.ready || !_intro.isCompleted) return;
    // onFinished rebuilds the parent, which mustn't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_finished || !mounted) return;
      _finished = true;
      widget.onFinished();
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  /// Icon pose for the current frame: vertical offset, horizontal/vertical
  /// scale and sway (horizontal skew), all pivoting on the icon's base.
  _Pose _pose(double screenHeight) {
    final t = _intro.value * _introSeconds;

    // 1. Falling: accelerates under "gravity", stretched along the fall.
    if (t < _fallSeconds) {
      final p = t / _fallSeconds;
      final dropFrom = screenHeight / 2 + _iconSize;
      return _Pose(dy: -dropFrom * (1 - p * p), sx: 0.9, sy: 1.12);
    }

    // 2. Landed: damped squash/stretch, one small bounce and a sway that
    // lags slightly behind, which is what sells it as jelly rather than
    // a rigid bouncing ball.
    final s = t - _fallSeconds;
    final squash = 0.3 * math.exp(-5 * s) * math.cos(2 * math.pi * 3.2 * s);
    final sway = 0.14 * math.exp(-4.2 * s) * math.sin(2 * math.pi * 2.3 * s);
    const hopSeconds = 0.3;
    final hop = s < hopSeconds ? 22 * math.sin(math.pi * s / hopSeconds) : 0.0;

    return _Pose(dy: -hop, sx: 1 + 0.8 * squash, sy: 1 - squash, skew: sway);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Center(
      child: AnimatedBuilder(
        animation: _intro,
        builder: (context, child) {
          final pose = _pose(screenHeight);
          return Transform.translate(
            offset: Offset(0, pose.dy),
            child: Transform(
              alignment: Alignment.bottomCenter,
              transform: Matrix4.diagonal3Values(pose.sx, pose.sy, 1)
                ..setEntry(0, 1, pose.skew),
              child: child,
            ),
          );
        },
        child: Image.asset(
          'assets/icon-transparent.png',
          width: _iconSize,
          height: _iconSize,
        ),
      ),
    );
  }
}

class _Pose {
  final double dy;
  final double sx;
  final double sy;
  final double skew;

  const _Pose({
    required this.dy,
    required this.sx,
    required this.sy,
    this.skew = 0,
  });
}
