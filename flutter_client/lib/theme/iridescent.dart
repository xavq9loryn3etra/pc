import 'package:flutter/material.dart';

/// The app's own look, built from the modes' accent colours: shapes that
/// are silver across the top and melt into the three modes' colours round
/// the bottom — Popcorn's cream up the left, Library's tan underneath,
/// Groovy's pink up the right. For the app's icon, wordmark, big headings
/// and the odd highlight on shared screens — not body text or small
/// labels, and not inside a mode, which keeps its own accent.
class AppIridescence {
  AppIridescence._();

  // Hues around the centre, clockwise from the right (y points down): the
  // three modes' accents round the bottom — Groovy's pink up the right,
  // Library's tan underneath, Popcorn's cream up the left — and silver
  // across the top, mostly covered by the silver fade (see [fade]).
  //
  // The accents are pastels of the modes' hues. Between each pair the
  // sweep dips halfway into silver (their blend, half silvered): as one
  // straight band, three warm hues read as a single peach glow, but split
  // by pure silver they read as separate patches. The dips keep them
  // flowing into each other with a metallic shimmer in between.
  static const List<Color> colors = [
    Color(0xFFF8B4CB), // Groovy pink (AppMode.music.accentColor), pastel
    Color(0xFFECD2D1), // pink/tan, half silvered
    Color(0xFFF4CDA6), // Library tan (AppMode.books.accentColor), pastel
    Color(0xFFEDE1CC), // tan/cream, half silvered
    Color(0xFFFBEFB8), // Popcorn cream (AppMode.movies.accentColor)
    _silver,
    _silver,
    Color(0xFFF8B4CB), // back round to Groovy
  ];
  static const List<double> _stops = [0, 0.12, 0.25, 0.37, 0.5, 0.7, 0.82, 1];
  static const _silver = Color(0xFFE3E5EA);

  /// The colour sweep over [rect], optionally faded to [opacity]. It turns
  /// around a point below the middle — the hole of the icon's bottom loop
  /// — so the colours run round that loop, with no seam on the shape.
  static Shader sweep(Rect rect, {double opacity = 1}) => SweepGradient(
        center: const Alignment(0, 0.3),
        colors: [
          for (final c in colors) c.withValues(alpha: c.a * opacity),
        ],
        stops: _stops,
      ).createShader(rect);

  /// Soft silver over the top of [rect] — faint light and darker bands, as
  /// polished metal reflects — fading out towards the bottom so the colour
  /// shows there.
  static Shader fade(Rect rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFFF4F5F7),
          Color(0xFFDADDE2),
          Color(0xE6EEEFF2),
          Color(0x99D6D9DE),
          Color(0x00DDE0E5),
        ],
        stops: [0, 0.2, 0.32, 0.46, 0.7],
      ).createShader(rect);
}

/// Gives [child] (text, an SVG, an image — anything opaque) the app's
/// iridescent finish. Only the child's shape matters, not its colour.
class Iridescent extends StatelessWidget {
  final Widget child;

  const Iridescent({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: AppIridescence.sweep,
          child: child,
        ),
        ExcludeSemantics(
          child: ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: AppIridescence.fade,
            child: child,
          ),
        ),
      ],
    );
  }
}
