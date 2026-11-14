import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/visual_effects_service.dart';
import '../theme/app_theme.dart';
import 'ask_orb.dart';
import 'floating_bottom_nav_bar.dart' show kNavButtonHeight, windowIsWide;

/// Frosted glass: blurs whatever is painted behind [child], within the
/// nearest clip (wrap it in a ClipRect / ClipRRect / ClipPath), then
/// paints [child] — usually the glass's translucent tint — on top.
///
/// Use this instead of BackdropFilter directly, so every glass surface:
///  * goes plain where VisualEffectsService says to — on phones too slow
///    for the blur, and in battery saver: no blur, just [child] over
///    [reducedTint] so text on it stays readable without the blur behind
///    it;
///  * can share one backdrop capture with the app's other [grouped] glass
///    (the BackdropGroup at the app root), instead of each surface taking
///    its own copy of the screen every frame;
///  * shows [reducedTint] instead of blurring while its page slides in or
///    out, or another slides over it or back off it, and for a moment
///    after. With two pages sliding past each other, every blur — taking
///    its own copy of the screen — dropped some five frames per slide on a
///    Galaxy S25 Ultra at 120 Hz, against one or two without.
class GlassBlur extends StatefulWidget {
  final double sigma;

  /// Share the backdrop with the other grouped glass on screen. Only for
  /// glass that can never overlap other grouped glass — the app bar and
  /// the floating bottom nav bar — since overlapping filters in one group
  /// read a backdrop that doesn't include each other.
  final bool grouped;

  /// Painted behind [child] when the blur is off, to make up for it.
  final Color reducedTint;

  /// Off for now, as while its page slides: the glass itself is moving —
  /// a sheet being pulled down — and re-blurring all of it every frame
  /// stuttered. Frosts back over when it's let go of.
  final bool paused;

  /// Stays frosted while pages slide too: the bottom nav bar's, which
  /// visibly went flat and frosted back over each time a page opened or
  /// closed. Small, and sharing the grouped backdrop, it costs little.
  final bool keepsFrost;

  final Widget child;

  const GlassBlur({
    super.key,
    // Measured on a Galaxy S10: at 20, drawing the app's glass ran past
    // a 60 Hz frame's 16.7 ms several times a second while scrolling.
    this.sigma = 12,
    this.grouped = false,
    this.reducedTint = const Color(0xE6000000), // black, 90%
    this.paused = false,
    this.keepsFrost = false,
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
  State<GlassBlur> createState() => _GlassBlurState();
}

class _GlassBlurState extends State<GlassBlur> {
  // The page this glass is on: its animation runs while it slides in or
  // out, its secondaryAnimation while another page slides over it or
  // back off it.
  ModalRoute<dynamic>? _route;
  bool _pageMoving = false;

  bool get _routeMoving =>
      (_route?.animation?.isAnimating ?? false) ||
      (_route?.secondaryAnimation?.isAnimating ?? false);

  void _listen(ModalRoute<dynamic>? route, bool on) {
    for (final animation in [route?.animation, route?.secondaryAnimation]) {
      on
          ? animation?.addStatusListener(_onRouteStatus)
          : animation?.removeStatusListener(_onRouteStatus);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    _listen(_route, false);
    _route = route;
    _listen(route, true);
    _pageMoving = _routeMoving;
  }

  // Waits a moment before the blur starts up again (see _onRouteStatus).
  Timer? _settle;

  // Starting the blur up takes a frame longer than usual: right as the
  // slide ends, that was a hitch at its last frame — on top of a details
  // page's content appearing then. A moment later the screen's still, and
  // the late frame can't be seen. Not much later: the glass coming back
  // after 350 ms was noticed.
  static const _settleDelay = Duration(milliseconds: 150);

  // How long the frost takes to come back over the glass (see build):
  // switched straight back on, it snapped from tint to blur.
  static const _frostIn = Duration(milliseconds: 320);

  void _onRouteStatus(AnimationStatus _) {
    final moving = _routeMoving;
    _settle?.cancel();
    if (moving) {
      if (!_pageMoving) setState(() => _pageMoving = true);
    } else if (_pageMoving) {
      _settle = Timer(_settleDelay, () {
        if (mounted && !_routeMoving) setState(() => _pageMoving = false);
      });
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    _listen(_route, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: VisualEffectsService().reduceGlass,
      builder: (context, reduce, child) {
        final on = !reduce &&
            (!_pageMoving || widget.keepsFrost) &&
            !widget.paused &&
            widget.sigma > 0;
        // Coming back on, the blur grows from nothing as the tint fades
        // out: the glass frosts over. Going off, at once — the page is
        // starting to slide, and the change goes unseen in the motion.
        return TweenAnimationBuilder<double>(
          tween: Tween(end: on ? 1 : 0),
          duration: on ? _frostIn : Duration.zero,
          curve: Curves.easeOut,
          child: child,
          builder: (context, t, child) {
            final blur = t > 0;
            // The same widgets whether blurring or not, only switched: a
            // different structure would rebuild everything on the glass.
            final tinted = DecoratedBox(
              decoration: BoxDecoration(
                color: Color.lerp(widget.reducedTint,
                    widget.reducedTint.withValues(alpha: 0), t),
              ),
              child: child,
            );
            final filter = GlassBlur.filterFor(math.max(widget.sigma * t, 0.1));
            return widget.grouped
                ? BackdropFilter.grouped(
                    filter: filter, enabled: blur, child: tinted)
                : BackdropFilter(filter: filter, enabled: blur, child: tinted);
          },
        );
      },
      child: widget.child,
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
  final double? dimension;
  final bool showBorder;

  /// Shares its backdrop with the other grouped glass (see
  /// [GlassBlur.grouped]): for rows of glass that don't overlap, over
  /// moving video (the player's controls) — one capture of the video
  /// between them instead of one each.
  final bool grouped;

  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.iconSize = 20,
    this.dimension,
    this.showBorder = true,
    this.grouped = false,
  });

  /// The back chevron: heavier than the "iOS arrow" icon, like Apple's.
  static const IconData backIcon = Icons.chevron_left_rounded;
  static const double backIconSize = 30;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: GlassBlur(
        grouped: grouped,
        reducedTint: Colors.black.withValues(alpha: 0.9),
        child: Material(
          color: kGlassTint,
          shape: CircleBorder(
            side: showBorder ? BorderSide(color: kGlassEdge) : BorderSide.none,
          ),
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            customBorder: const CircleBorder(),
            onTap: onPressed,
            // As tall as the tab bar's buttons on a wide window.
            child: SizedBox.square(
              dimension:
                  dimension ?? (windowIsWide(context) ? kNavButtonHeight : 40),
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
          reducedTint: Colors.black.withValues(alpha: 0.9),
          child: Material(
            color: kGlassTint,
            shape: _shape.copyWith(side: BorderSide(color: kGlassEdge)),
            child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
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
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GlassBlur(
              reducedTint: Colors.black.withValues(alpha: 0.9),
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

  /// Its menu is open: a denser, brighter frost, as a pressed-in button.
  final bool selected;

  /// The larger size (a wide window's), whatever the space it's in: for a
  /// phone-wide panel on a wide window (the player's episode panel), whose
  /// round buttons are already the window's size (see GlassCircleButton).
  /// Null: the larger size on a screen 900 or more wide.
  final bool? large;

  /// A fill across it from the left, 0 to 1 — the player's Next Episode
  /// counting down to playing it (see PlayerScreen._updateUpNext).
  final Animation<double>? progress;

  /// The app's smart side is at work on what it stands for (the player's
  /// Subtitles: being synced): it's Ask's orb all over (see AskOrb), as
  /// Ask's own button is — "being taken care of", not "wait, loading".
  final bool busy;

  /// Shares its backdrop with the other grouped glass (see
  /// [GlassBlur.grouped]): for rows of glass that don't overlap, over
  /// moving video (the player's controls) — one capture of the video
  /// between them instead of one each.
  final bool grouped;

  const GlassPillButton({
    super.key,
    this.icon,
    required this.label,
    this.trailingIcon,
    required this.onPressed,
    this.selected = false,
    this.large,
    this.progress,
    this.busy = false,
    this.grouped = false,
  });

  static const _shape = StadiumBorder();

  @override
  Widget build(BuildContext context) {
    final wide = large ?? MediaQuery.sizeOf(context).width >= 900;
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: Stack(
        children: [
          // Busy: the orb inside the pill only (below) — its glow around
          // the pill, spilling onto the bar, was too much.
          ClipRRect(
            borderRadius: BorderRadius.circular(wide ? 24 : 20),
            child: GlassBlur(
              grouped: grouped,
              reducedTint: Colors.black.withValues(alpha: 0.9),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                decoration: ShapeDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.28)
                      : kGlassTint,
                  shape: _shape.copyWith(
                    side: BorderSide(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.45)
                          : kGlassEdge,
                    ),
                  ),
                ),
                child: Stack(
                  children: [
                    // Busy: the orb itself, over the glass, under the label.
                    Positioned.fill(child: BusyOrb(on: busy, spill: false)),
                    Material(
                      type: MaterialType.transparency,
                      shape: _shape,
                      child: InkWell(
                        mouseCursor: WidgetStateMouseCursor.clickable,
                        customBorder: _shape,
                        onTap: onPressed,
                        child: _withFill(Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: wide ? 18 : 14,
                            vertical: wide ? 11 : 8,
                          ),
                          // Grows and shrinks smoothly when its label changes
                          // ("Subtitles" ↔ "Syncing…").
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (icon != null) ...[
                                  Icon(icon,
                                      color: Colors.white,
                                      size: wide ? 20 : 16,
                                      shadows: busy ? kOnOrbShadows : null),
                                  SizedBox(width: wide ? 8 : 6),
                                ],
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: wide ? 14.5 : 12.5,
                                    fontWeight: FontWeight.w600,
                                    shadows: busy ? kOnOrbShadows : null,
                                  ),
                                ),
                                if (trailingIcon != null) ...[
                                  SizedBox(width: wide ? 6 : 4),
                                  Icon(
                                    trailingIcon,
                                    color: Colors.white70,
                                    size: wide ? 20 : 16,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft dark shadow under white text and icons on Ask's orb (see
/// BusyOrb), so they read on its lighter colours (the cream, the silver).
const kOnOrbShadows = [Shadow(color: Color(0x99000000), blurRadius: 6)];

/// Ask's orb (see AskOrb) filling whatever it's in, fading in while [on]
/// and out after — and gone once faded out, so Ask's clock isn't kept
/// running (and the screen redrawn) for nothing. [spill] and [body] as
/// AskOrb's.
class BusyOrb extends StatefulWidget {
  final bool on;
  final bool spill;
  final bool body;

  const BusyOrb(
      {super.key, required this.on, this.spill = true, this.body = true});

  @override
  State<BusyOrb> createState() => _BusyOrbState();
}

class _BusyOrbState extends State<BusyOrb> {
  late bool _shown = widget.on;

  @override
  void didUpdateWidget(covariant BusyOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.on) _shown = true;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.on ? 1 : 0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        onEnd: () {
          if (!widget.on && mounted) setState(() => _shown = false);
        },
        child: _shown
            ? AskOrb(
                // Its size is the space it's given.
                size: 0,
                width: double.infinity,
                spill: widget.spill,
                body: widget.body,
              )
            : null,
      ),
    );
  }
}

extension on GlassPillButton {
  /// [content] with [GlassPillButton.progress]'s fill behind it, when set.
  Widget _withFill(Widget content) {
    final progress = this.progress;
    if (progress == null) return content;
    return Stack(
      children: [
        Positioned.fill(child: _PillFill(progress)),
        content,
      ],
    );
  }
}

/// [GlassPillButton.progress]: a light fill from the left, under the label.
class _PillFill extends StatelessWidget {
  final Animation<double> progress;

  const _PillFill(this.progress);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, _) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: progress.value.clamp(0.0, 1.0),
          heightFactor: 1,
          child: const ColoredBox(color: Color(0x47FFFFFF)), // white, 28%
        ),
      ),
    );
  }
}
