import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app's icon — its popcorn shape — [size] across, in [color] (white
/// unless given: an opaque shape, for Iridescent and the shimmer to
/// colour).
///
/// Drawn, not a picture: three rings of one round-ended stroke, measured
/// off the 1024px icon-transparent.png. That file's outline was lumpy —
/// traced from an image — and cut flat where the rings ran past its edges,
/// at the bottom most of all, and its curves came out jagged scaled down.
/// Drawn, it's smooth at any size, and whole.
class AppIcon extends StatelessWidget {
  final double size;
  final Color? color;
  final String? semanticLabel;

  const AppIcon(
      {super.key, required this.size, this.color, this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final icon = CustomPaint(
      size: Size.square(size),
      painter: _AppIconPainter(color ?? Colors.white),
    );
    return semanticLabel == null
        ? icon
        : Semantics(label: semanticLabel, image: true, child: icon);
  }
}

class _AppIconPainter extends CustomPainter {
  final Color color;

  const _AppIconPainter(this.color);

  // In the 1024px icon's units: the rings' centreline radius, the stroke's
  // width, and each ring as (centre, where its stroke starts and how far
  // round it goes, in degrees clockwise from 3 o'clock). Two end in the
  // round stubs inside the shape; the bottom one's ends are hidden where it
  // meets the others.
  static const _radius = 262.0;
  static const _stroke = 98.0;
  static const _rings = [
    (Offset(310.1, 368.3), 58.5, 257.0), // left
    (Offset(725.2, 308.5), 179.0, 270.0), // right
    (Offset(566.6, 713.4), 329.0, 230.0), // bottom
  ];

  // The square the shape sits centred in, in those units: its full
  // reach, edge to edge, which ran past the file's.
  static const _left = -0.9, _top = -7.6, _side = 1037.1;

  /// The outline of one ring's stroke: from [from] degrees round [sweep],
  /// with round ends.
  static Path _ring(Offset centre, double from, double sweep) {
    const outer = _radius + _stroke / 2, inner = _radius - _stroke / 2;
    const cap = _stroke / 2;
    final a = from * math.pi / 180, s = sweep * math.pi / 180;
    Offset at(double angle) =>
        centre + Offset(math.cos(angle), math.sin(angle)) * _radius;
    return Path()
      ..arcTo(Rect.fromCircle(center: centre, radius: outer), a, s, true)
      ..arcTo(Rect.fromCircle(center: at(a + s), radius: cap), a + s, math.pi,
          false)
      ..arcTo(Rect.fromCircle(center: centre, radius: inner), a + s, -s, false)
      ..arcTo(Rect.fromCircle(center: at(a), radius: cap), a + math.pi,
          math.pi, false)
      ..close();
  }

  static Path _hole(Offset centre) => Path()
    ..addOval(Rect.fromCircle(center: centre, radius: _radius - _stroke / 2));

  /// The whole shape, worked out once. Where a ring runs into another its
  /// round end would poke out into that one's hole — a knob beside the top
  /// notch, and at the bottom ring's joins — so those ends are cut back by
  /// the hole. (Not the stubs: the right ring's top one sits in the left's
  /// hole, the left's in the bottom's.)
  static final Path _shape = () {
    final [(l, lf, ls), (r, rf, rs), (b, bf, bs)] = _rings;
    final left = Path.combine(PathOperation.difference, _ring(l, lf, ls),
        _hole(r));
    final bottom = Path.combine(
      PathOperation.difference,
      Path.combine(PathOperation.difference, _ring(b, bf, bs), _hole(r)),
      _hole(l),
    );
    return Path.combine(PathOperation.union,
        Path.combine(PathOperation.union, left, _ring(r, rf, rs)), bottom);
  }();

  /// The shape, centred in [size].
  static Path shapeIn(Size size) {
    final scale = size.shortestSide / _side;
    final matrix = Matrix4.identity()
      ..translateByDouble(
        (size.width - _side * scale) / 2,
        (size.height - _side * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-_left, -_top, 0, 1);
    return _shape.transform(matrix.storage);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      shapeIn(size),
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_AppIconPainter old) => old.color != color;
}
