import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/visual_effects_service.dart';
import 'glass_blur.dart';

/// Measures, out of sight, how long this phone takes to draw the app's
/// frosted glass, and tells VisualEffectsService whether that's too slow
/// for it. Placed behind the mode selector's slideshow — which covers it,
/// and keeps the screen redrawing every frame — once per app version
/// (VisualEffectsService.needsProbe), so a slow phone has plain glass
/// before it reaches a page with glass on it.
///
/// The glass is about what a details page shows over the home as it
/// opens: a bar like the bottom nav's sharing one backdrop, and three
/// round buttons with one each.
class GlassProbe extends StatefulWidget {
  const GlassProbe({super.key});

  /// Changes whenever how this measures or judges does, so phones that
  /// were judged by an older probe are measured again.
  static const version = 2;

  @override
  State<GlassProbe> createState() => _GlassProbeState();
}

class _GlassProbeState extends State<GlassProbe>
    with SingleTickerProviderStateMixin {
  // Frames left out at the start — a blur's first frames are slow on any
  // phone, setting it up — then the frames measured.
  static const _settleFrames = 10;
  static const _measuredFrames = 40;

  // Too slow when a typical frame (the 75th percentile) with the glass
  // takes longer to draw than a frame lasts — it'd be late. A Galaxy S10
  // at 60 Hz, smooth with the glass in use, took 14.1 ms of 16.7 here;
  // 75% of a frame, tried first, had it go plain.
  static const _maxShareOfFrame = 1.0;

  final List<int> _rasterMicros = [];
  int _seen = 0;
  bool _done = false;

  // Keeps frames coming while measuring, should the slideshow be still.
  late final Ticker _ticker;
  final _tick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _tick.value++)..start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_done) return;
    for (final t in timings) {
      if (++_seen <= _settleFrames) continue;
      _rasterMicros.add(t.rasterDuration.inMicroseconds);
      if (_rasterMicros.length == _measuredFrames) {
        _finish();
        return;
      }
    }
  }

  void _finish() {
    _done = true;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.stop();
    final sorted = [..._rasterMicros]..sort();
    final typical = sorted[(sorted.length * 0.75).floor()];
    final frame = VisualEffectsService.frameMicros();
    final tooSlow = typical > frame * _maxShareOfFrame;
    debugPrint('[glass probe] typical frame drawn in '
        '${(typical / 1000).toStringAsFixed(1)} ms of '
        '${(frame / 1000).toStringAsFixed(1)} ms → '
        '${tooSlow ? 'plain glass' : 'frosted glass'}');
    VisualEffectsService().probeResult(tooSlow: tooSlow);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (!_done) SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();
    final filter = GlassBlur.filterFor(12);
    Widget circle(double left) => Positioned(
          top: 60,
          left: left,
          width: 50,
          height: 50,
          child: ClipOval(
            child: BackdropFilter(
              filter: filter,
              child: const SizedBox.expand(),
            ),
          ),
        );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 20,
              right: 20,
              bottom: 24,
              height: 66,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(33),
                child: BackdropFilter.grouped(
                  filter: filter,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            circle(20),
            circle(80),
            circle(140),
            // Repainted on every tick: a frame each time.
            CustomPaint(painter: _TickPainter(_tick)),
          ],
        ),
      ),
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter(Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_TickPainter old) => false;
}
