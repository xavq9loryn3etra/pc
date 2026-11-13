import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The time Ask's drifting visuals share, in seconds: ticking about 30
/// times a second while any of them is showing (see [AskClockSubscription]),
/// stopped otherwise. One clock, so several on screen redraw together in
/// one frame rather than each in its own — anything animating keeps the
/// whole screen being redrawn, glass and all. 30 a second, not every
/// frame, for the same reason: they drift slowly.
class AskClock {
  AskClock._();

  static final _time = ValueNotifier<double>(0);
  static ValueListenable<double> get time => _time;

  static final _stopwatch = Stopwatch();
  static Timer? _timer;
  static int _users = 0;

  static void _join() {
    if (_users++ > 0) return;
    _stopwatch.start();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _time.value = _stopwatch.elapsedMilliseconds / 1000;
    });
  }

  static void _leave() {
    if (--_users > 0) return;
    _stopwatch.stop();
    _timer?.cancel();
    _timer = null;
  }
}

/// Keeps [AskClock] running for a widget while it can be seen: not while
/// its page is covered (TickerMode) or the app's in the background. Call
/// [update] from didChangeDependencies and [dispose] from dispose.
class AskClockSubscription with WidgetsBindingObserver {
  ValueListenable<TickerModeData>? _mode;
  bool _observing = false;
  bool _foreground = true;
  bool _joined = false;

  void update(BuildContext context) {
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _mode?.removeListener(_sync);
    _mode = TickerMode.getValuesNotifier(context)..addListener(_sync);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final run = _foreground && (_mode?.value.enabled ?? true);
    if (run && !_joined) {
      AskClock._join();
      _joined = true;
    } else if (!run && _joined) {
      AskClock._leave();
      _joined = false;
    }
  }

  void dispose() {
    _mode?.removeListener(_sync);
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    if (_joined) AskClock._leave();
    _joined = false;
  }
}

/// Ask's orb, its logo: soft blobs of the app's colours drifting about
/// inside a circle [size] across, after Gemini's, with [child] (the
/// app's icon) over them. [colour] from 0, dim greys, to 1, full colour — and
/// then a little glow spilling past its edge. Drawn as plain radial
/// gradients: no blur, blend modes or layers.
///
/// Given a [width], it's a pill [size] high instead (as Ask's named button
/// on a wide window), the blobs drifting along its length.
///
/// [spill] false leaves out the glow past its edge, [body] false all but
/// it — for drawing them apart, the orb inside something that clips it and
/// the glow behind (as GlassPillButton.busy does).
class AskOrb extends StatefulWidget {
  final double size;
  final double? width;
  final double colour;
  final bool spill;
  final bool body;
  final Widget? child;

  const AskOrb({
    super.key,
    required this.size,
    this.width,
    this.colour = 1,
    this.spill = true,
    this.body = true,
    this.child,
  });

  @override
  State<AskOrb> createState() => _AskOrbState();
}

class _AskOrbState extends State<AskOrb> {
  final _clock = AskClockSubscription();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clock.update(context);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OrbPainter(AskClock.time, widget.colour,
          spill: widget.spill, body: widget.body),
      child: SizedBox(
          width: widget.width ?? widget.size,
          height: widget.size,
          child: widget.child),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final ValueListenable<double> time;

  /// How much of the blobs' colour shows: 1 full colour, 0 greys.
  final double colour;

  /// Whether its glow past the edge is drawn, and the orb itself.
  final bool spill;
  final bool body;

  _OrbPainter(this.time, this.colour, {this.spill = true, this.body = true})
      : super(repaint: time);

  // [color] as a dim grey of about the same brightness: on the other tabs
  // it's a quiet button among the rest, not lit up like the open one.
  static Color _grey(Color color) {
    // Spread apart enough that the blobs' drift still shows.
    final v = 0.16 + color.computeLuminance() * 0.5;
    return Color.from(alpha: 1, red: v, green: v, blue: v);
  }

  // The app's own colours, at full strength: the modes' accents, Popcorn's
  // cream, Library's tan and Groovy's pink, and the icon's silver. Each
  // blob its own pace (turns
  // a second) and path, so they never fall into step.
  static const _blobs = [
    (AppTheme.primaryColor, 0.075, 0.0),
    (Color(0xFFD4A574), 0.055, 2.1), // AppMode.books.accentColor
    (Color(0xFFE91E63), 0.095, 4.2), // AppMode.music.accentColor
    // And the icon's silver (see AppIridescence) drifting among them.
    (Color(0xFFE3E5EA), 0.065, 1.05),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final r = size.shortestSide / 2;
    // How far past a circle the shape runs each way: 0 for a circle; along
    // its length, in a pill.
    final reach = size.width / 2 - r;
    final pill = reach > 0.5;
    // In a pill, the blobs are spread from one end to the other, each
    // roaming a little about its own place, so no end is ever left dark
    // (were they all free to roam the whole length, at times they'd all be
    // at the other end) — and a long pill has more of them, the colours
    // over again. In a circle they all roam about its centre.
    final count = math.max(_blobs.length, (2 * reach / (r * 1.2)).ceil() + 1);
    final ends = pill ? reach + r * 0.3 : 0.0;
    final stretch = 2 * ends / (count - 1);
    final roam = pill ? r * 0.25 + stretch * 0.25 : r * 0.5;
    final centre = size.center(Offset.zero);
    final t = time.value;
    final blobs = [
      for (var i = 0; i < count; i++)
        () {
          final (hue, speed, phase) = _blobs[i % _blobs.length];
          // The colours' second round on a long pill, out of step with
          // the first.
          final a =
              t * speed * 2 * math.pi + phase + (i ~/ _blobs.length) * 2.4;
          final home = centre.dx - ends + stretch * i;
          return (
            Color.lerp(_grey(hue), hue, colour)!,
            // Where it's drifted to, and how big it's swelled.
            (
              Offset(home + math.cos(a) * roam,
                  centre.dy + math.sin(a * 1.3 + phase) * r * 0.5),
              // Small enough that each keeps its own colour where they
              // overlap less; in a pill, big enough to meet the next.
              (pill ? r * 1.15 + stretch * 0.6 : r) *
                  (0.8 + 0.12 * math.sin(a * 0.7)),
            ),
          );
        }(),
    ];

    // The glow spilling past the edge: the blobs again, bigger and fainter,
    // unclipped — only in colour.
    final glow = 0.18 * colour;
    if (spill) {
      for (final (color, (at, radius)) in blobs) {
        _blob(canvas, color.withValues(alpha: glow), at, radius * 1.12);
      }
    }
    if (!body) return;

    // The orb itself.
    canvas.save();
    final shape = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(r)); // A circle, or a pill.
    canvas.clipRRect(shape);
    canvas.drawRRect(shape, Paint()..color = const Color(0xFF17140F));
    for (final (color, (at, radius)) in blobs) {
      _blob(canvas, color.withValues(alpha: 0.6 + 0.35 * colour), at, radius);
    }
    canvas.restore();
  }

  // A soft round blob of [color], fading out to its edge.
  static void _blob(Canvas canvas, Color color, Offset at, double radius) {
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.time != time ||
      old.colour != colour ||
      old.spill != spill ||
      old.body != body;
}
