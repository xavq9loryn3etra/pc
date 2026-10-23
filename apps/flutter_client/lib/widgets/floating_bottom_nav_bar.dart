import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/movie_tab_service.dart';

enum BottomNavTab { home, search, favorites, settings }

const _kTransitionDuration = Duration(milliseconds: 220);
const _kCircleSize = 52.0;
const _kGap = 12.0;

// The Search pill collapsing to a circle and all 4 items sliding into their
// packed group reads better with a bit of spring to it than a flat ease —
// longer duration than _kTransitionDuration so the overshoot has room to
// actually be visible instead of looking like a stutter.
const _kBounceDuration = Duration(milliseconds: 350);
const _kBounceCurve = Curves.easeOutBack;

// One-time pop-in played when a bar is first built (see MovieHomeScreen,
// which only constructs its bar once the loading shimmer is done, so this
// plays right as the shimmer closes rather than sitting there statically).
// Each item's own window starts _kEntranceStagger later than the previous
// one's, so they cascade in left-to-right instead of all popping at once.
const _kEntranceDuration = Duration(milliseconds: 650);
const _kEntranceStagger = 0.15;
const _kEntranceWindow = 0.55;
const _kEntranceTravel = 24.0; // px the item slides up from

/// Floating tab bar for the Popcorn, Groovy, and Library experiences. Sits on a
/// bottom-fading gradient so it stays legible over whatever scrolls beneath it.
/// Selection is indicated by solid icon style and active mode color highlight.
class FloatingBottomNavBar extends StatefulWidget {
  final BottomNavTab activeTab;

  const FloatingBottomNavBar({super.key, required this.activeTab});

  @override
  State<FloatingBottomNavBar> createState() => _FloatingBottomNavBarState();
}

class _FloatingBottomNavBarState extends State<FloatingBottomNavBar>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;

  // Packed (Search active) ⇄ normal layout transition. Driven here rather
  // than by AnimatedPositioned so the shared glass clip (see build) knows
  // every item's in-between rect on each frame.
  late final AnimationController _layoutController;
  late bool _fromSearchActive;

  bool get _isSearchActive => widget.activeTab == BottomNavTab.search;

  @override
  void initState() {
    super.initState();
    _entranceController =
        AnimationController(vsync: this, duration: _kEntranceDuration)
          ..forward();
    _layoutController = AnimationController(
      vsync: this,
      duration: _kBounceDuration,
      value: 1,
    );
    _fromSearchActive = _isSearchActive;
  }

  @override
  void didUpdateWidget(FloatingBottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasSearchActive = oldWidget.activeTab == BottomNavTab.search;
    if (wasSearchActive != _isSearchActive) {
      _fromSearchActive = wasSearchActive;
      _layoutController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _layoutController.dispose();
    super.dispose();
  }

  /// Each item's rect (within the bar's row) for one layout state.
  List<Rect> _slots(List<BottomNavTab> tabs, double totalWidth, bool packed) {
    final itemCount = tabs.length;
    if (packed) {
      // Search-active layout: every item becomes an equal circle, packed
      // tightly together and centered as one group.
      final step = _kCircleSize + _kGap;
      final groupWidth = _kCircleSize * itemCount + _kGap * (itemCount - 1);
      final groupStart =
          ((totalWidth - groupWidth) / 2).clamp(0.0, totalWidth);
      return [
        for (var i = 0; i < itemCount; i++)
          Rect.fromLTWH(groupStart + i * step, 0, _kCircleSize, _kCircleSize),
      ];
    }
    // Normal layout: Search fills whatever's left after every other
    // (fixed-size) item, in whatever order/count `tabs` is.
    final wideSearchWidth = (totalWidth -
            _kCircleSize * (itemCount - 1) -
            _kGap * (itemCount - 1))
        .clamp(_kCircleSize, double.infinity);
    final slots = <Rect>[];
    double x = 0;
    for (final tab in tabs) {
      final w = tab == BottomNavTab.search ? wideSearchWidth : _kCircleSize;
      slots.add(Rect.fromLTWH(x, 0, w, _kCircleSize));
      x += w + _kGap;
    }
    return slots;
  }

  /// This item's 0..1 entrance progress at the controller's current value —
  /// each item's window starts _kEntranceStagger later than the previous
  /// one's (see the constants above), so evaluating them all against the
  /// same controller value is what makes them cascade in staggered instead
  /// of moving together.
  double _entranceProgress(int index) {
    final start = index * _kEntranceStagger;
    final end = (start + _kEntranceWindow).clamp(0.0, 1.0);
    return Interval(start, end, curve: Curves.easeOutBack)
        .transform(_entranceController.value);
  }

  /// Interpolates an item's slot. The bouncy curve overshoots, which would
  /// briefly squeeze the collapsing Search pill narrower than a circle —
  /// so position overshoots (the spring) but width never drops below one.
  Rect _lerpSlot(Rect from, Rect to, double p) {
    final r = Rect.lerp(from, to, p)!;
    if (r.width >= _kCircleSize) return r;
    return Rect.fromLTWH(r.left, r.top, _kCircleSize, r.height);
  }

  /// An item's glass shape during its entrance: slides up with the item and
  /// grows in from its centre — the shared blur can't be faded like the
  /// item's content is, so it scales in instead. Empty before it starts.
  Rect _entranceGlassRect(Rect slot, double t) {
    final s = t.clamp(0.0, 1.0);
    if (s <= 0.01) return Rect.zero;
    return Rect.fromCenter(
      center: slot.center.translate(0, (1 - t) * _kEntranceTravel),
      width: slot.width * s,
      height: slot.height * s,
    );
  }

  void _navigate(BuildContext context, BottomNavTab tab) {
    if (tab == widget.activeTab) return;

    // Tabs live in MovieTabShell's Stack, so switching is just a
    // value flip — no rebuild, no refetch, scroll/search state stays put.
    // popUntil covers the case where this bar is on a screen pushed on top
    // of the shell: it unwinds back down so the newly selected tab is visible.
    MovieTabService().currentTab.value = tab;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Widget _circleFor(
    BuildContext context,
    BottomNavTab tab,
    Color activeColor,
  ) {
    switch (tab) {
      case BottomNavTab.home:
        return _NavCircle(
          icon: Icons.home_outlined,
          activeIcon: Icons.home_rounded,
          isActive: widget.activeTab == BottomNavTab.home,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.home),
        );
      case BottomNavTab.search:
        return _SearchPill(
          isActive: widget.activeTab == BottomNavTab.search,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.search),
        );
      case BottomNavTab.favorites:
        return _NavCircle(
          icon: Icons.favorite_border,
          activeIcon: Icons.favorite_rounded,
          isActive: widget.activeTab == BottomNavTab.favorites,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.favorites),
        );
      case BottomNavTab.settings:
        return _NavCircle(
          icon: Icons.settings_outlined,
          activeIcon: Icons.settings_rounded,
          isActive: widget.activeTab == BottomNavTab.settings,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.settings),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    final tabs = [
      BottomNavTab.home,
      BottomNavTab.search,
      BottomNavTab.favorites,
      BottomNavTab.settings,
    ];

    final barHeight = 40 + _kCircleSize + bottomPadding + 16;

    return ValueListenableBuilder<AppMode>(
      valueListenable: AppModeService().currentMode,
      builder: (context, currentMode, _) {
        final activeColor = currentMode.accentColor;

        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Stack(
            children: [
              // Bottom-fading gradient behind the buttons. Purely decorative
              IgnorePointer(
                child: Container(
                  width: double.infinity,
                  height: barHeight,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black],
                      stops: [0.0, 0.6],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 40, 20, bottomPadding + 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final totalWidth = constraints.maxWidth;
                    final itemCount = tabs.length;

                    return SizedBox(
                      width: totalWidth,
                      height: _kCircleSize,
                      child: AnimatedBuilder(
                        animation: Listenable.merge(
                            [_entranceController, _layoutController]),
                        builder: (context, _) {
                          final from =
                              _slots(tabs, totalWidth, _fromSearchActive);
                          final to =
                              _slots(tabs, totalWidth, _isSearchActive);
                          final p =
                              _kBounceCurve.transform(_layoutController.value);
                          final rects = [
                            for (var i = 0; i < itemCount; i++)
                              _lerpSlot(from[i], to[i], p),
                          ];
                          final entrance = [
                            for (var i = 0; i < itemCount; i++)
                              _entranceProgress(i),
                          ];

                          return Stack(
                            children: [
                              // One live blur for the whole bar, cut to every
                              // item's shape — instead of a BackdropFilter per
                              // item (four re-blurring the same strip of
                              // content on every scroll frame). Items keep
                              // their own tint and border on top of it.
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: ClipPath(
                                    clipper: _GlassShapesClipper([
                                      for (var i = 0; i < itemCount; i++)
                                        _entranceGlassRect(
                                            rects[i], entrance[i]),
                                    ]),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(
                                          sigmaX: 10, sigmaY: 10),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                              ),
                              for (var i = 0; i < itemCount; i++)
                                Positioned.fromRect(
                                  rect: rects[i],
                                  child: Opacity(
                                    opacity: entrance[i].clamp(0.0, 1.0),
                                    child: Transform.translate(
                                      offset: Offset(0,
                                          (1 - entrance[i]) * _kEntranceTravel),
                                      child: _circleFor(
                                        context,
                                        tabs[i],
                                        activeColor,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SearchPill extends StatelessWidget {
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _SearchPill({
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Blur comes from the bar's shared glass layer behind it; this paints
    // just the tint, border and ink (clipped to the pill).
    return Material(
      color: AppTheme.scaffoldColor.withValues(alpha: 0.35),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
        side: BorderSide(
          color: isActive
              ? activeColor.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.14),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          // Mid-collapse the pill reaches circle size a moment before its
          // "Search" label has finished shrinking away; OverflowBox lets the
          // row run over into the (clipped) edge instead of flagging a
          // RenderFlex overflow for those few frames.
          child: OverflowBox(
            minWidth: 0,
            maxWidth: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: _kTransitionDuration,
                  child: Icon(
                    isActive ? Icons.search_rounded : Icons.search_outlined,
                    key: ValueKey(isActive),
                    color: isActive ? activeColor : Colors.white,
                    size: 22,
                  ),
                ),
                AnimatedSize(
                  duration: _kBounceDuration,
                  curve: _kBounceCurve,
                  child: isActive
                      ? const SizedBox(height: 22)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            SizedBox(width: 10),
                            Text(
                              'Search',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                ),
              ],
          ),
          ),
        ),
      ),
    );
  }
}

class _NavCircle extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _NavCircle({
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Blur comes from the bar's shared glass layer behind it; this paints
    // just the tint, border and ink (clipped to the circle).
    return Material(
      color: AppTheme.scaffoldColor.withValues(alpha: 0.35),
      clipBehavior: Clip.antiAlias,
      shape: CircleBorder(
        side: BorderSide(
          color: isActive
              ? activeColor.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.14),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: _kCircleSize,
          height: _kCircleSize,
          child: Center(
            child: AnimatedSwitcher(
              duration: _kTransitionDuration,
              child: Icon(
                isActive ? activeIcon : icon,
                key: ValueKey(isActive),
                color: isActive ? activeColor : Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Union of rounded shapes (each fully rounded: circles and pills) for the
/// nav bar's shared glass blur. Empty rects (items not yet entered) skip.
class _GlassShapesClipper extends CustomClipper<Path> {
  final List<Rect> shapes;

  const _GlassShapesClipper(this.shapes);

  @override
  Path getClip(Size size) {
    final path = Path();
    for (final r in shapes) {
      if (r.isEmpty) continue;
      path.addRRect(
          RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide / 2)));
    }
    return path;
  }

  @override
  bool shouldReclip(_GlassShapesClipper old) {
    if (old.shapes.length != shapes.length) return true;
    for (var i = 0; i < shapes.length; i++) {
      if (old.shapes[i] != shapes[i]) return true;
    }
    return false;
  }
}
