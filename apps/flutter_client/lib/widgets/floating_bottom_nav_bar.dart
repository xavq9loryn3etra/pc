import 'package:flutter/material.dart';
import 'ask_orb.dart';
import 'glass_blur.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/movie_tab_service.dart';
import 'app_icon.dart';

/// The tabs, in MovieTabShell's order. [ai] only in the movies mode (see
/// FloatingBottomNavBar.tabsFor).
enum BottomNavTab { home, search, favorites, settings, ai }

const _kTransitionDuration = Duration(milliseconds: 220);
const _kCircleSize = 52.0;
const _kGap = 12.0;

// One-time pop-in played when a bar is first built (see MovieHomeScreen,
// which only constructs its bar once the loading shimmer is done, so this
// plays right as the shimmer closes rather than sitting there statically).
// Each item's own window starts _kEntranceStagger later than the previous
// one's, so they cascade in left-to-right instead of all popping at once.
const _kEntranceDuration = Duration(milliseconds: 650);
const _kEntranceStagger = 0.11;
const _kEntranceWindow = 0.55;
const _kEntranceTravel = 24.0; // px the item slides up from

/// Floating tab bar for the Popcorn, Groovy, and Library experiences. Sits on a
/// bottom-fading gradient so it stays legible over whatever scrolls beneath it.
/// Selection is indicated by solid icon style and active mode color highlight.
class FloatingBottomNavBar extends StatefulWidget {
  final BottomNavTab activeTab;

  const FloatingBottomNavBar({super.key, required this.activeTab});

  /// The tabs [mode] has, left to right — Ask before Settings, though it's
  /// last in BottomNavTab (MovieTabShell's order). Ask (the AI) only
  /// suggests movies and shows, so it's only in the movies mode.
  static List<BottomNavTab> tabsFor(AppMode mode) => [
        BottomNavTab.home,
        BottomNavTab.search,
        BottomNavTab.favorites,
        if (mode == AppMode.movies) BottomNavTab.ai,
        BottomNavTab.settings,
      ];

  @override
  State<FloatingBottomNavBar> createState() => _FloatingBottomNavBarState();
}

class _FloatingBottomNavBarState extends State<FloatingBottomNavBar>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    _entranceController =
        AnimationController(vsync: this, duration: _kEntranceDuration)
          ..forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  /// Each item's rect within the bar's row: equal circles, packed together
  /// and centred as one group. (Search was a wide pill, until Ask needed
  /// the room.)
  List<Rect> _slots(int itemCount, double totalWidth) {
    final step = _kCircleSize + _kGap;
    final groupWidth = _kCircleSize * itemCount + _kGap * (itemCount - 1);
    final groupStart = ((totalWidth - groupWidth) / 2).clamp(0.0, totalWidth);
    return [
      for (var i = 0; i < itemCount; i++)
        Rect.fromLTWH(groupStart + i * step, 0, _kCircleSize, _kCircleSize),
    ];
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
          icon: Icons.home_rounded,
          activeIcon: Icons.home_rounded,
          isActive: widget.activeTab == BottomNavTab.home,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.home),
        );
      case BottomNavTab.search:
        return _NavCircle(
          icon: Icons.search_rounded,
          activeIcon: Icons.search_rounded,
          isActive: widget.activeTab == BottomNavTab.search,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.search),
        );
      case BottomNavTab.favorites:
        return _NavCircle(
          icon: Icons.favorite_rounded,
          activeIcon: Icons.favorite_rounded,
          isActive: widget.activeTab == BottomNavTab.favorites,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.favorites),
        );
      case BottomNavTab.settings:
        return _NavCircle(
          icon: Icons.settings_rounded,
          activeIcon: Icons.settings_rounded,
          isActive: widget.activeTab == BottomNavTab.settings,
          activeColor: activeColor,
          onTap: () => _navigate(context, BottomNavTab.settings),
        );
      case BottomNavTab.ai:
        return _AiCircle(
          isActive: widget.activeTab == BottomNavTab.ai,
          onTap: () => _navigate(context, BottomNavTab.ai),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final barHeight = 40 + _kCircleSize + bottomPadding + 16;

    return ValueListenableBuilder<AppMode>(
      valueListenable: AppModeService().currentMode,
      builder: (context, currentMode, _) {
        final activeColor = currentMode.accentColor;
        final tabs = FloatingBottomNavBar.tabsFor(currentMode);

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
                        animation: _entranceController,
                        builder: (context, _) {
                          final rects = _slots(itemCount, totalWidth);
                          final entrance = [
                            for (var i = 0; i < itemCount; i++)
                              _entranceProgress(i),
                          ];

                          return Stack(
                            // Ask's colours spill a little past its circle.
                            clipBehavior: Clip.none,
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
                                    // Grouped with the app bar's glass
                                    // (they never overlap).
                                    child: const GlassBlur(
                                      grouped: true,
                                      child: SizedBox.expand(),
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
      color: kGlassTint,
      clipBehavior: Clip.antiAlias,
      shape: CircleBorder(
        side: BorderSide(
          color: isActive ? activeColor.withValues(alpha: 0.45) : kGlassEdge,
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

/// Ask's button: its orb (see AskOrb) with the app's icon on it — in colour
/// on its own tab, dim greys on the others. No ring: its colour, spilling
/// a little past its edge, marks it out.
class _AiCircle extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _AiCircle({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: isActive ? 1 : 0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      builder: (context, colour, child) =>
          AskOrb(size: _kCircleSize, colour: colour, child: child),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          // The app's own icon, as before "Ask" in its title — not the
          // sparkles every AI feature has.
          child: Center(
            // As big as the other buttons' icons look: theirs are 24 with
            // room round the glyph, this fills its box.
            child: const AppIcon(
              size: 21,
              color: Colors.white,
              semanticLabel: 'Popcorn Ask',
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
