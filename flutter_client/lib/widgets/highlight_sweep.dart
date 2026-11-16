import 'package:flutter/material.dart';

/// [child] with a soft band of light sweeping across it — twice, over
/// about a second and a half — each time [trigger] changes: to point out
/// one card among many (the series page's episode being watched, once its
/// arrow has scrolled to it). Nothing's drawn over [child] otherwise.
class HighlightSweep extends StatefulWidget {
  final int trigger;
  final double radius;
  final Widget child;

  const HighlightSweep({
    super.key,
    required this.trigger,
    required this.radius,
    required this.child,
  });

  @override
  State<HighlightSweep> createState() => _HighlightSweepState();
}

class _HighlightSweepState extends State<HighlightSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didUpdateWidget(HighlightSweep old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger) _sweep.forward(from: 0);
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) {
                if (!_sweep.isAnimating) return const SizedBox.shrink();
                return ClipRRect(
                  borderRadius: BorderRadius.circular(widget.radius),
                  child: CustomPaint(painter: _SweepPainter(_sweep.value)),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _SweepPainter extends CustomPainter {
  /// 0 to 1 over both passes.
  final double t;

  _SweepPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // Two passes, each eased: the band slows as it leaves.
    final pass = t < 0.5 ? t * 2 : (t - 0.5) * 2;
    final p = Curves.easeInOut.transform(pass);
    final band = size.width * 0.45;
    final x = -band + (size.width + band * 2) * p;
    // Leaning, as light catching glass does.
    final shader = LinearGradient(
      colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: 0.28),
        Colors.white.withValues(alpha: 0),
      ],
    ).createShader(Rect.fromPoints(
      Offset(x - band, 0),
      Offset(x + band, size.height * 0.6),
    ));
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t;
}
