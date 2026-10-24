import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/visual_effects_service.dart';

/// Frosted glass: blurs whatever is painted behind [child], within the
/// nearest clip (wrap it in a ClipRect / ClipRRect / ClipPath), then
/// paints [child] — usually the glass's translucent tint — on top.
///
/// Use this instead of BackdropFilter directly, so every glass surface:
///  * honours the "Reduce glass effects" setting (VisualEffectsService):
///    no blur, just [child] over [reducedTint] so text on it stays
///    readable without the blur behind it;
///  * can share one backdrop capture with the app's other [grouped] glass
///    (the BackdropGroup at the app root), instead of each surface taking
///    its own copy of the screen every frame.
class GlassBlur extends StatelessWidget {
  final double sigma;

  /// Share the backdrop with the other grouped glass on screen. Only for
  /// glass that can never overlap other grouped glass — the app bar and
  /// the floating bottom nav bar — since overlapping filters in one group
  /// read a backdrop that doesn't include each other.
  final bool grouped;

  /// Painted behind [child] when the blur is off, to make up for it.
  final Color reducedTint;

  final Widget child;

  const GlassBlur({
    super.key,
    this.sigma = 10,
    this.grouped = false,
    this.reducedTint = const Color(0x4D000000), // black, 30%
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: VisualEffectsService().reduceGlass,
      builder: (context, reduce, child) {
        if (reduce || sigma <= 0) {
          return DecoratedBox(
            decoration: BoxDecoration(color: reducedTint),
            child: child,
          );
        }
        final filter = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
        return grouped
            ? BackdropFilter.grouped(filter: filter, child: child!)
            : BackdropFilter(filter: filter, child: child!);
      },
      child: child,
    );
  }
}
