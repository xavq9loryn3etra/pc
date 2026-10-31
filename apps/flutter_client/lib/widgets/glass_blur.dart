import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/visual_effects_service.dart';
import '../theme/app_theme.dart';

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
    // Measured on a Galaxy S10: at 20, drawing the app's glass ran past
    // a 60 Hz frame's 16.7 ms several times a second while scrolling.
    this.sigma = 12,
    this.grouped = false,
    this.reducedTint = const Color(0x4D000000), // black, 30%
    required this.child,
  });

  /// How much more vivid the blurred backdrop is made. Apple's materials
  /// do the same: without it, blurring mixes neighbouring colours into
  /// mud, and the glass reads as dirty grey rather than frosted.
  static const double _saturation = 1.8;

  /// The glass's colour boost on its own — for "glass" faked with an
  /// already-blurry image instead of a live blur (the mode selector's
  /// panel, the episode popups' backdrop), so it matches the real thing.
  static final ColorFilter saturate = () {
    // The standard saturation matrix (Rec. 709 luminance weights).
    const s = _saturation;
    const r = 0.2126 * (1 - s), g = 0.7152 * (1 - s), b = 0.0722 * (1 - s);
    return const ColorFilter.matrix([
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
  }();

  /// The glass's backdrop filter at [sigma]: [saturate], then blur. In
  /// that order, though either gives the same picture (both are linear):
  /// a blur is worked out on a scaled-down copy, and the other way round
  /// the colour boost ran on that copy before it was scaled back up,
  /// leaving a grid of little squares across the glass.
  static ImageFilter filterFor(double sigma) => ImageFilter.compose(
        outer: ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        ),
        inner: saturate,
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: VisualEffectsService().reduceGlass,
      builder: (context, reduce, child) {
        final blur = !reduce && sigma > 0;
        // The same widgets whether blurring or not, only switched: a
        // different structure would rebuild everything on the glass.
        final tinted = DecoratedBox(
          decoration: BoxDecoration(
            color: blur ? Colors.transparent : reducedTint,
          ),
          child: child,
        );
        final filter = filterFor(math.max(sigma, 0.1));
        return grouped
            ? BackdropFilter.grouped(
                filter: filter, enabled: blur, child: tinted)
            : BackdropFilter(filter: filter, enabled: blur, child: tinted);
      },
      child: child,
    );
  }
}

// The app's frosted glass on top of a [GlassBlur] (as on the details
// screen's back button and the bottom nav), after Apple's dark materials:
// a neutral dark grey rather than black, so what's behind shows through
// as soft colour, and only a hairline of an edge to keep it from vanishing
// against black.
const kGlassTint = Color(0x8C2C2C2E); // #2C2C2E, 55%
final kGlassEdge = Colors.white.withValues(alpha: 0.06);

// The thicker glass of big surfaces holding text — dialogs, sheets, side
// panels — like Apple's thick material: the same grey, darker, so text
// stays readable over anything behind.
const kGlassSheetTint = Color(0xB81C1C1E); // #1C1C1E, 72%

/// A round frosted-glass icon button — the back / close buttons over the
/// player and its episode browser, matching the details screen's.
class GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double iconSize;

  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.iconSize = 20,
  });

  /// The back chevron: heavier than the "iOS arrow" icon, like Apple's.
  static const IconData backIcon = Icons.chevron_left_rounded;
  static const double backIconSize = 30;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: GlassBlur(
        reducedTint: Colors.black.withValues(alpha: 0.45),
        child: Material(
          color: kGlassTint,
          shape: CircleBorder(side: BorderSide(color: kGlassEdge)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(icon, color: Colors.white, size: iconSize),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 50px-tall frosted-glass pill (round at [width] 50) for secondary
/// actions — the details screen's Trailer and Like, Settings' Export and
/// Import: the backdrop blurred under a dark tint, with a faint edge.
class GlassActionButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final double? width;

  const GlassActionButton({
    super.key,
    required this.child,
    required this.onTap,
    this.width,
  });

  static const _shape = StadiumBorder();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      width: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: GlassBlur(
          reducedTint: Colors.black.withValues(alpha: 0.45),
          child: Material(
            color: kGlassTint,
            shape: _shape.copyWith(side: BorderSide(color: kGlassEdge)),
            child: InkWell(
              customBorder: _shape,
              onTap: onTap,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// An on/off switch in the glass style: a frosted track with a faint edge
/// that fills with [activeColor] when on, and a white knob that slides
/// across.
class GlassSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color activeColor;

  const GlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor = AppTheme.primaryColor,
  });

  static const _duration = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GlassBlur(
              reducedTint: Colors.black.withValues(alpha: 0.45),
              child: AnimatedContainer(
                duration: _duration,
                curve: Curves.easeOut,
                width: 52,
                height: 32,
                padding: const EdgeInsets.all(3),
                decoration: ShapeDecoration(
                  color: value ? activeColor : kGlassTint,
                  shape: StadiumBorder(
                    side: BorderSide(
                        color: value ? Colors.transparent : kGlassEdge),
                  ),
                ),
                child: AnimatedAlign(
                  duration: _duration,
                  curve: Curves.easeOut,
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: value ? Colors.black : Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A frosted-glass pill with an optional [icon] before its [label] and an
/// optional [trailingIcon] after it — the player's bottom-row buttons and
/// the episode browser's season picker. Null [onPressed] shows it dimmed
/// and inert.
class GlassPillButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final IconData? trailingIcon;
  final VoidCallback? onPressed;

  const GlassPillButton({
    super.key,
    this.icon,
    required this.label,
    this.trailingIcon,
    required this.onPressed,
  });

  static const _shape = StadiumBorder();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: GlassBlur(
          reducedTint: Colors.black.withValues(alpha: 0.45),
          child: Material(
            color: kGlassTint,
            shape: _shape.copyWith(side: BorderSide(color: kGlassEdge)),
            child: InkWell(
              customBorder: _shape,
              onTap: onPressed,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (trailingIcon != null) ...[
                      const SizedBox(width: 4),
                      Icon(trailingIcon, color: Colors.white70, size: 16),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
