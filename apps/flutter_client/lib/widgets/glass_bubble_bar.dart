import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A frosted-glass back button with a title "bubble" that grows out of it,
/// joined by a thin, concave neck — like two water droplets barely touching.
///
/// The circle, the pill and the neck are one shape under one blur (same
/// recipe as the app's other glass: 10px blur, 35% black), so they read as
/// a single piece of glass. [reveal] (0–1) grows the title bubble out of
/// the button and back.
class GlassBubbleBar extends StatefulWidget {
  /// 0 = just the back button; 1 = title bubble fully out.
  final double reveal;

  /// Sits in the circle (e.g. a BackButton).
  final Widget leading;

  /// Sits in the bubble (logo or title text).
  final Widget title;

  const GlassBubbleBar({
    super.key,
    required this.reveal,
    required this.leading,
    required this.title,
  });

  /// Diameter of the back button circle, and the bubble's height.
  static const double size = 40;

  @override
  State<GlassBubbleBar> createState() => _GlassBubbleBarState();
}

class _GlassBubbleBarState extends State<GlassBubbleBar> {
  static const double _gap = 6; // circle edge → bubble edge
  static const double _padH = 14; // bubble's horizontal padding

  // The title's natural width, measured off-screen so the bubble (and the
  // glass shape around it) can be sized to fit any logo or text.
  double _titleWidth = 0;

  @override
  Widget build(BuildContext context) {
    const d = GlassBubbleBar.size;
    // No overshoot: an overshooting curve made the bubble briefly taller
    // than the button beside it mid-animation.
    final grow = Curves.easeOutCubic.transform(widget.reveal.clamp(0.0, 1.0));

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxTitle = math.max(
          0.0,
          constraints.maxWidth - d - _gap - _padH * 2,
        );
        final pillWidth = _titleWidth + _padH * 2;

        return SizedBox(
          height: d,
          width: d + _gap + pillWidth,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipPath(
                  clipper: _BubbleClipper(
                    diameter: d,
                    gap: _gap,
                    pillWidth: pillWidth,
                    grow: grow,
                  ),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                width: d,
                height: d,
                child: widget.leading,
              ),
              Positioned(
                left: d + _gap,
                top: 0,
                width: pillWidth,
                height: d,
                // Scaled from the bubble's left edge, matching how the
                // clipper grows the glass, so the content rides with it.
                child: Transform.scale(
                  scale: grow,
                  alignment: Alignment.centerLeft,
                  child: Opacity(
                    opacity: widget.reveal.clamp(0.0, 1.0),
                    // OverflowBox lets the title take its natural width
                    // (capped to the bar) regardless of the bubble's current
                    // size, so it can be measured — including on the first
                    // frame, before the bubble has been sized to it.
                    //
                    // Height is loosened too: OverflowBox otherwise passes
                    // the bubble's tight 40px height straight through, which
                    // stretched a plain-text title's box and left the text
                    // drawn at its top instead of vertically centred.
                    child: OverflowBox(
                      minWidth: 0,
                      maxWidth: maxTitle,
                      minHeight: 0,
                      maxHeight: d,
                      child: _SizeReporter(
                        onWidth: (w) {
                          if ((w - _titleWidth).abs() > 0.5) {
                            setState(() => _titleWidth = w);
                          }
                        },
                        child: widget.title,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Circle ∪ bubble ∪ a thin concave neck between them.
class _BubbleClipper extends CustomClipper<Path> {
  final double diameter;
  final double gap;
  final double pillWidth;
  final double grow;

  const _BubbleClipper({
    required this.diameter,
    required this.gap,
    required this.pillWidth,
    required this.grow,
  });

  // Half-thickness of the neck at its narrowest, when fully grown — small
  // relative to the 20px radius, so the connection reads as weak.
  static const double _neck = 4.5;
  // Where the neck meets each body, measured from horizontal.
  static const double _attach = 38 * math.pi / 180;

  @override
  Path getClip(Size size) {
    final r = diameter / 2;
    final cy = r;
    final circle = Path()
      ..addOval(Rect.fromCircle(center: Offset(r, cy), radius: r));

    // Nothing to join yet (also skips the pill when it'd be sub-pixel).
    if (grow <= 0.02) return circle;

    // The bubble, scaled about its left-centre, matching the content's
    // Transform.scale.
    final left = diameter + gap;
    final h = diameter * grow;
    final w = math.max(h, pillWidth * grow);
    final pillRect = Rect.fromLTWH(left, cy - h / 2, w, h);
    final pill = Path()
      ..addRRect(RRect.fromRectAndRadius(pillRect, Radius.circular(h / 2)));

    // Neck: from the circle's right side to the bubble's left cap, its top
    // and bottom edges curving in to meet at ±neck around the middle.
    final rp = h / 2; // bubble cap radius
    final sinA = math.sin(_attach), cosA = math.cos(_attach);
    final p1 = Offset(r + r * cosA, cy - r * sinA); // circle, upper
    final p2 = Offset(r + r * cosA, cy + r * sinA); // circle, lower
    final capCx = left + rp;
    final q1 = Offset(capCx - rp * cosA, cy - rp * sinA); // bubble, upper
    final q2 = Offset(capCx - rp * cosA, cy + rp * sinA); // bubble, lower
    final midX = (p1.dx + q1.dx) / 2;
    final neck = _neck * grow;
    // Quadratic control point chosen so the curve's midpoint lands at
    // cy ∓ neck: mid = (start + 2·control + end) / 4.
    final c1y = (4 * (cy - neck) - p1.dy - q1.dy) / 2;
    final c2y = (4 * (cy + neck) - p2.dy - q2.dy) / 2;
    final bridge = Path()
      ..moveTo(p1.dx, p1.dy)
      ..quadraticBezierTo(midX, c1y, q1.dx, q1.dy)
      ..lineTo(q2.dx, q2.dy)
      ..quadraticBezierTo(midX, c2y, p2.dx, p2.dy)
      ..close();

    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, circle, pill),
      bridge,
    );
  }

  @override
  bool shouldReclip(_BubbleClipper old) =>
      old.grow != grow ||
      old.pillWidth != pillWidth ||
      old.diameter != diameter ||
      old.gap != gap;
}

/// Reports its child's laid-out width after each layout.
class _SizeReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onWidth;

  const _SizeReporter({required this.onWidth, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onWidth);

  @override
  void updateRenderObject(
      BuildContext context, _RenderSizeReporter renderObject) {
    renderObject.onWidth = onWidth;
  }
}

class _RenderSizeReporter extends RenderProxyBox {
  ValueChanged<double> onWidth;
  double? _lastWidth;

  _RenderSizeReporter(this.onWidth);

  @override
  void performLayout() {
    super.performLayout();
    final width = size.width;
    if (width != _lastWidth) {
      _lastWidth = width;
      // Can't setState during layout; report once this frame is done.
      WidgetsBinding.instance.addPostFrameCallback((_) => onWidth(width));
    }
  }
}
