import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/movie.dart';
import 'glass_blur.dart';
import 'floating_bottom_nav_bar.dart' show kNavButtonHeight, windowIsWide;
import 'package:flutter/rendering.dart';

/// A frosted-glass back button with a title "bubble" that grows out of it,
/// joined by a thin, concave neck — like two water droplets barely touching.
///
/// The circle, the pill and the neck are one shape under one blur (same
/// recipe as the app's other glass: GlassBlur under kGlassTint), so they read as
/// a single piece of glass. [reveal] (0–1) grows the title bubble out of
/// the button and back.
class GlassBubbleBar extends StatefulWidget {
  /// 0 = just the back button; 1 = title bubble fully out.
  final double reveal;

  /// Sits in the circle (e.g. a BackButton).
  final Widget leading;

  /// Sits in the bubble (logo or title text).
  final Widget title;

  /// A second bubble, joined to the title's as that is to the circle — the
  /// player's episode browser's season picker (SeasonPicker.bare). Brings
  /// its own padding; it grows with the title's.
  final Widget? trailing;

  /// The title bubble's horizontal padding: 0 for a [title] that brings
  /// its own (SeasonPicker.bare), so its tap area fills the bubble.
  final double titlePadding;

  /// Mirrored: the circle on the right, the bubble growing out of it to the
  /// left — for a bar in a right-hand corner (the player's episode panel:
  /// its season picker, then close in the corner). No [trailing] then.
  final bool leadingOnRight;

  const GlassBubbleBar({
    super.key,
    required this.reveal,
    required this.leading,
    required this.title,
    this.trailing,
    this.titlePadding = 14,
    this.leadingOnRight = false,
  }) : assert(!leadingOnRight || trailing == null);

  /// Diameter of the back button circle, and the bubble's height.
  static const double size = 40;

  @override
  State<GlassBubbleBar> createState() => _GlassBubbleBarState();
}

class _GlassBubbleBarState extends State<GlassBubbleBar> {
  static const double _gap = 6; // circle edge → bubble edge

  // The title's natural width, measured off-screen so the bubble (and the
  // glass shape around it) can be sized to fit any logo or text.
  double _titleWidth = 0;
  // The trailing bubble's content's natural width, likewise.
  double _trailingWidth = 0;

  @override
  Widget build(BuildContext context) {
    // As tall as the tab bar's buttons on a wide window.
    final d = windowIsWide(context) ? kNavButtonHeight : GlassBubbleBar.size;
    // No overshoot: an overshooting curve made the bubble briefly taller
    // than the button beside it mid-animation.
    final grow = Curves.easeOutCubic.transform(widget.reveal.clamp(0.0, 1.0));

    return LayoutBuilder(
      builder: (context, constraints) {
        final padH = widget.titlePadding;
        final maxTitle = math.max(
          0.0,
          constraints.maxWidth - d - _gap - padH * 2,
        );
        final pillWidth = math.max(d, _titleWidth + padH * 2);
        final trailing = widget.trailing;
        final trailingLeft = d + _gap + pillWidth + _gap;
        final trailingWidth = math.max(d, _trailingWidth);
        final mirror = widget.leadingOnRight;
        final total = d + _gap + pillWidth;

        return SizedBox(
          height: d,
          width: trailing == null
              ? d + _gap + pillWidth
              : trailingLeft + trailingWidth,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipPath(
                  clipper: _BubbleClipper(
                    diameter: d,
                    gap: _gap,
                    pillWidth: pillWidth,
                    trailingWidth: trailing == null ? null : trailingWidth,
                    grow: grow,
                    mirror: mirror,
                  ),
                  child: const GlassBlur(
                    child: ColoredBox(color: kGlassTint),
                  ),
                ),
              ),
              Positioned(
                left: mirror ? total - d : 0,
                top: 0,
                width: d,
                height: d,
                child: widget.leading,
              ),
              Positioned(
                left: mirror ? 0 : d + _gap,
                top: 0,
                width: pillWidth,
                height: d,
                // Scaled from the bubble's edge by the circle, matching how
                // the clipper grows the glass, so the content rides with it.
                child: Transform.scale(
                  scale: grow,
                  alignment:
                      mirror ? Alignment.centerRight : Alignment.centerLeft,
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
              if (trailing != null)
                Positioned(
                  // Rides with the title's bubble as it grows (see
                  // _BubbleClipper), then its own grows from its left.
                  left: d + _gap + pillWidth * grow + _gap,
                  top: 0,
                  width: trailingWidth,
                  height: d,
                  child: Transform.scale(
                    scale: grow,
                    alignment: Alignment.centerLeft,
                    child: Opacity(
                      opacity: widget.reveal.clamp(0.0, 1.0),
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: 0,
                        maxWidth: constraints.maxWidth,
                        minHeight: d,
                        maxHeight: d,
                        child: _SizeReporter(
                          onWidth: (w) {
                            if ((w - _trailingWidth).abs() > 0.5) {
                              setState(() => _trailingWidth = w);
                            }
                          },
                          child: trailing,
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

/// Circle ∪ bubble ∪ a thin concave neck between them — and, with
/// [trailingWidth], a second bubble after the first, joined the same way.
class _BubbleClipper extends CustomClipper<Path> {
  final double diameter;
  final double gap;
  final double pillWidth;
  final double? trailingWidth;
  final double grow;

  /// Flipped left to right (GlassBubbleBar.leadingOnRight).
  final bool mirror;

  const _BubbleClipper({
    required this.diameter,
    required this.gap,
    required this.pillWidth,
    this.trailingWidth,
    required this.grow,
    this.mirror = false,
  });

  // Half-thickness of the neck at its narrowest, when fully grown — small
  // relative to the 20px radius, so the connection reads as weak.
  static const double _neck = 4.5;
  // Where the neck meets each body, measured from horizontal.
  static const double _attach = 38 * math.pi / 180;

  @override
  Path getClip(Size size) {
    final shape = _shape(size);
    if (!mirror) return shape;
    // x becomes width - x.
    final flip = Matrix4.identity()
      ..translateByDouble(size.width, 0, 0, 1)
      ..scaleByDouble(-1, 1, 1, 1);
    return shape.transform(flip.storage);
  }

  Path _shape(Size size) {
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

    var shape = Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, circle, pill),
      bridge,
    );

    final tw = trailingWidth;
    if (tw != null) {
      // The second bubble, after the first (as it is now, growing), and
      // a neck from the first's right cap to its left cap.
      final left2 = left + w + gap;
      final w2 = math.max(h, tw * grow);
      final pill2 = Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(left2, cy - h / 2, w2, h), Radius.circular(rp)));
      final aCx = left + w - rp; // first bubble's right cap
      final bCx = left2 + rp; // second's left cap
      final a1 = Offset(aCx + rp * cosA, cy - rp * sinA);
      final a2 = Offset(aCx + rp * cosA, cy + rp * sinA);
      final b1 = Offset(bCx - rp * cosA, cy - rp * sinA);
      final b2 = Offset(bCx - rp * cosA, cy + rp * sinA);
      final mid2 = (a1.dx + b1.dx) / 2;
      final d1y = (4 * (cy - neck) - a1.dy - b1.dy) / 2;
      final d2y = (4 * (cy + neck) - a2.dy - b2.dy) / 2;
      final bridge2 = Path()
        ..moveTo(a1.dx, a1.dy)
        ..quadraticBezierTo(mid2, d1y, b1.dx, b1.dy)
        ..lineTo(b2.dx, b2.dy)
        ..quadraticBezierTo(mid2, d2y, a2.dx, a2.dy)
        ..close();
      shape = Path.combine(
        PathOperation.union,
        Path.combine(PathOperation.union, shape, pill2),
        bridge2,
      );
    }
    return shape;
  }

  @override
  bool shouldReclip(_BubbleClipper old) =>
      old.mirror != mirror ||
      old.trailingWidth != trailingWidth ||
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

/// The title for a [GlassBubbleBar]'s bubble: [movie]'s logo, or its name
/// in text when it has none — on the details screen and over the player.
class MovieTitleLogo extends StatelessWidget {
  final Movie movie;

  const MovieTitleLogo({super.key, required this.movie});

  @override
  Widget build(BuildContext context) {
    final logo = movie.logoUrl;
    if (logo == null) {
      return Text(
        movie.title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      );
    }
    // Fixed width+height (not just a maxWidth cap) — CachedNetworkImage/
    // SvgPicture.network report zero size while their first frame is
    // still loading (octo_image's placeholder for the "loading" state is
    // a bare zero-size Container), so a maxWidth-only box collapsed to
    // nothing and then snapped to full size the instant the logo finished
    // decoding — only on first load, since after that it's served
    // synchronously from Flutter's image cache. A tight box keeps the
    // space stable from the very first frame, loaded or not.
    //
    // The box is sized to the logo's own aspect ratio (from TMDB) rather
    // than a flat 120 wide: the title bubble wraps this box, so a squarer
    // logo contain-fitted into 120×28 left the bubble with a long empty
    // tail. Capped at 120 wide; unknown ratio falls back to 120.
    final ratio = movie.logoAspectRatio;
    final width = ratio == null ? 120.0 : math.min(120.0, 28 * ratio);
    return SizedBox(
      width: width,
      height: 28,
      child: logo.toLowerCase().endsWith('.svg')
          ? SvgPicture.network(
              logo,
              alignment: Alignment.centerLeft,
              fit: BoxFit.contain,
            )
          : CachedNetworkImage(
              imageUrl: logo,
              memCacheHeight:
                  (28 * MediaQuery.of(context).devicePixelRatio).toInt(),
              alignment: Alignment.centerLeft,
              fit: BoxFit.contain,
            ),
    );
  }
}
