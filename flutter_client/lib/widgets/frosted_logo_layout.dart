import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/visual_effects_service.dart';
import 'app_icon.dart';
import 'poster_wall.dart';

/// The app-wide screens' look (welcome, update, offline, maintenance): the
/// poster wall frosted over, with the app's icon cut out of the frost —
/// large, no outline, the posters moving sharp through the cut — and the
/// words beside it on a wide window, below it on a phone.
class FrostedLogoLayout extends StatelessWidget {
  /// The words and actions, laid out for [sideBySide] (beside the logo, on
  /// a wide window) and [large] (a wide window or a tablet).
  final Widget Function(BuildContext context, bool sideBySide, bool large)
      details;

  /// Fades the words in.
  final Animation<double> opacity;

  const FrostedLogoLayout({
    super.key,
    required this.details,
    required this.opacity,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final sideBySide = size.width >= 900 && size.width > size.height;
    // A tablet held upright: phone-sized words look lost on it.
    final large = sideBySide || size.width >= 700;

    final Rect logoRect;
    if (sideBySide) {
      final frostWidth = size.width * 0.55;
      final side = math.min(frostWidth * 0.7, size.height * 0.62);
      logoRect = Rect.fromCenter(
        center: Offset(frostWidth / 2, size.height / 2),
        width: side,
        height: side,
      );
    } else {
      final side = math.min(size.width * 0.8, size.height * 0.42);
      logoRect = Rect.fromCenter(
        center: Offset(
          size.width / 2,
          padding.top + (size.height - padding.top) * 0.3,
        ),
        width: side,
        height: side,
      );
    }

    final words = details(context, sideBySide, large);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Smaller artwork where the logo is smaller, so a good few
          // posters still show through it.
          Positioned.fill(
            child: PosterWall(
              scale: sideBySide ? 1.0 : (large ? 0.8 : 0.6),
              // A row of movies through the middle of the logo.
              focus: logoRect.center.dy / size.height,
            ),
          ),

          // Frost over the whole wall, with the icon's silhouette left
          // clear. Where the phone has the app's glass turned down (too
          // slow, or saving power), a heavier tint stands in for the blur.
          Positioned.fill(
            child: ClipPath(
              clipper: _FrostClipper(logoRect),
              clipBehavior: Clip.antiAlias,
              child: ValueListenableBuilder<bool>(
                valueListenable: VisualEffectsService().reduceGlass,
                builder: (context, reduced, _) => reduced
                    ? ColoredBox(color: Colors.black.withValues(alpha: 0.75))
                    : BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.35),
                        ),
                      ),
              ),
            ),
          ),

          // A little darker behind the words, so they read on the frost.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: sideBySide
                      ? LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.0),
                            Colors.black.withValues(alpha: 0.45),
                          ],
                          stops: const [0.55, 1.0],
                        )
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.0),
                            Colors.black.withValues(alpha: 0.55),
                          ],
                          stops: const [0.5, 1.0],
                        ),
                ),
              ),
            ),
          ),

          if (sideBySide)
            Positioned(
              left: size.width * 0.55,
              top: 0,
              right: 0,
              bottom: 0,
              child: FadeTransition(
                opacity: opacity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 64),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: words,
                    ),
                  ),
                ),
              ),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FadeTransition(
                opacity: opacity,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      32, 0, 32, (large ? 64 : 40) + padding.bottom),
                  child: words,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The frost's shape: all of it except the app icon's silhouette in
/// [logoRect].
class _FrostClipper extends CustomClipper<Path> {
  final Rect logoRect;

  const _FrostClipper(this.logoRect);

  @override
  Path getClip(Size size) => Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        AppIcon.silhouetteIn(logoRect.size).shift(logoRect.topLeft),
      );

  @override
  bool shouldReclip(_FrostClipper old) => old.logoRect != logoRect;
}
