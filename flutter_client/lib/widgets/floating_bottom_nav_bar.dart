import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'ask_orb.dart';
import 'glass_blur.dart';
import 'tv_focus.dart';
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

/// Wider than this, the bar sits at the top right instead of the bottom
/// (the breakpoint ScreenScaffold and the home use for their wide layouts).
const kTopNavBreakpoint = 800.0;

/// On a wide window the buttons are pills with their names beside their
/// icons, this high, sitting with their top and right edges here (below
/// the window's top inset): centred on the 80-high top bar's middle (see
/// CustomAppBar.wideToolbarHeight and the wide home's top bar).
const _kPillHeight = 44.0;

/// On a wide window, the height of the bar's buttons — and so of the back
/// buttons and the text fields (search, Ask's), which match them there.
const kNavButtonHeight = _kPillHeight;

/// Width and outer margin of a wide window's side column (see MovieTabShell).
const kSideColumnWidth = 480.0;
const kSideColumnGap = 16.0;

const _kPillGap = 10.0;
const kTopNavTop = (80 - _kPillHeight) / 2;
const kTopNavRight = kSideColumnGap;
const _kPillText = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

String _pillLabel(BottomNavTab tab) => switch (tab) {
      BottomNavTab.home => 'Home',
      BottomNavTab.search => 'Search',
      BottomNavTab.favorites => 'My List',
      BottomNavTab.settings => 'Settings',
      BottomNavTab.ai => 'Ask',
    };

/// The pills' label in the app's font. From the theme, not the ambient
/// DefaultTextStyle: the bar floats over the pages, outside any Material,
/// where that's Flutter's yellow-underlined fallback.
TextStyle _pillTextStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!.merge(_kPillText);

/// Each pill's rect along the top bar's row, sized to its icon and label,
/// packed with [_kPillGap] and centred over the side column's width.
List<Rect> _pillSlots(BuildContext context, List<BottomNavTab> tabs) {
  if (tabs.isEmpty) return const [];
  final style = _pillTextStyle(context);
  final scaler = MediaQuery.textScalerOf(context);
  final widths = [
    for (final tab in tabs)
      () {
        final text = TextPainter(
          text: TextSpan(text: _pillLabel(tab), style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        return 14 + 22 + 8 + text.width.ceilToDouble() + 18;
      }(),
  ];
  final totalButtonsWidth = widths.fold<double>(0, (sum, w) => sum + w);
  final groupWidth = totalButtonsWidth + _kPillGap * (tabs.length - 1);
  var x = ((kSideColumnWidth - groupWidth) / 2).clamp(0.0, kSideColumnWidth);
  return [
    for (final width in widths)
      () {
        final rect = Rect.fromLTWH(x, 0, width, _kPillHeight);
        x += width + _kPillGap;
        return rect;
      }(),
  ];
}

/// How wide the bar is at the top of a wide window, in the current mode,
/// so the top bars can keep that much of their right side clear for it.
double topNavWidth(BuildContext context) {
  final slots = _pillSlots(context,
      FloatingBottomNavBar.topTabsFor(AppModeService().currentMode.value));
  return slots.isEmpty ? 0 : slots.last.right;
}

/// Whether [context]'s window is wide enough for the bar at the top.
/// Inside the side column, whose screen is the column's own phone-sized
/// one (see MovieTabShell), it isn't.
bool navBarAtTop(BuildContext context) =>
    MediaQuery.sizeOf(context).width > kTopNavBreakpoint;

/// Whether the app's window itself is wide, wherever [context] is — the
/// side column included, for what opens over the whole window from it
/// (the popups: see showGlassSheet).
bool windowIsWide(BuildContext context) {
  final view = View.of(context);
  return view.physicalSize.width / view.devicePixelRatio > kTopNavBreakpoint;
}

/// Whether this is the desktop app (Windows; a native Mac or Linux build):
/// a mouse and a resizable window, not a phone or tablet however wide its
/// screen. (The iPad app on a Mac reports iOS, and counts as a tablet.)
final bool isComputer = !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Whether the player takes its desktop look (bigger controls, named
/// buttons, a click anywhere plays/pauses): a computer's wide window. Not
/// by width alone — a big phone on its side (an S25 Ultra is ~832 wide)
/// keeps the phone's player.
bool playerIsWide(BuildContext context) =>
    isComputer && windowIsWide(context);

/// Marks the side column beside a wide window's home (see MovieTabShell):
/// the tabs in it, though shown as on a phone, have no bar at their foot
/// to leave room for.
class SideColumnScope extends InheritedWidget {
  const SideColumnScope({super.key, required super.child});

  static bool inColumn(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SideColumnScope>() != null;

  @override
  bool updateShouldNotify(SideColumnScope oldWidget) => false;
}

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

  /// The tabs shown in a wide window's top bar (no Home button, since Home
  /// is always visible beside the side column).
  static List<BottomNavTab> topTabsFor(AppMode mode) => [
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
  Rect _entranceGlassRect(Rect slot, double t, double travel) {
    final s = t.clamp(0.0, 1.0);
    if (s <= 0.01) return Rect.zero;
    return Rect.fromCenter(
      center: slot.center.translate(0, (1 - t) * travel),
      width: slot.width * s,
      height: slot.height * s,
    );
  }

  void _navigate(BuildContext context, BottomNavTab tab) {
    // On a TV, the button the remote pressed: where Back returns to.
    final pressed = FocusManager.instance.primaryFocus;
    final hadColumnPages = MovieTabService().columnPages.value > 0;
    // A wide window's side column goes back to its tab, closing any title
    // opened in it.
    MovieTabService().closeColumnPages();
    if (tab == widget.activeTab) {
      // On a wide window (where there's no Home button), clicking the open
      // tab's pill when already at its root closes the side panel.
      if (navBarAtTop(context) && !hadColumnPages) {
        MovieTabService().currentTab.value = BottomNavTab.home;
      }
      return;
    }

    // Tabs live in MovieTabShell's Stack, so switching is just a
    // value flip — no rebuild, no refetch, scroll/search state stays put.
    // popUntil covers the case where this bar is on a screen pushed on top
    // of the shell: it unwinds back down so the newly selected tab is visible.
    if (tab != BottomNavTab.home) MovieTabService().rememberFocus(pressed);
    MovieTabService().currentTab.value = tab;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// [tab]'s pill for the bar at the top of a wide window: its icon and its
  /// name beside it.
  Widget _pillFor(BuildContext context, BottomNavTab tab, Color activeColor) {
    final isActive = widget.activeTab == tab;
    final label = _pillLabel(tab);
    final data = switch (tab) {
      BottomNavTab.home => Icons.home_rounded,
      BottomNavTab.search => Icons.search_rounded,
      BottomNavTab.favorites => Icons.favorite_rounded,
      BottomNavTab.settings => Icons.settings_rounded,
      // Ask's pill is its orb all over (see _AiCircle): colour on its own
      // tab, dim greys on the others.
      BottomNavTab.ai => null,
    };
    if (data == null) {
      return TweenAnimationBuilder<double>(
        tween: Tween(end: isActive ? 1 : 0),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        builder: (context, colour, child) => AskOrb(
            size: _kPillHeight,
            width: double.infinity,
            colour: colour,
            child: child),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: () => _navigate(context, tab),
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 18),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 22,
                    child: Center(
                      child: AppIcon(size: 17, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style:
                        _pillTextStyle(context).copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return _NavPill(
      icon: Icon(
        data,
        color: isActive ? activeColor : Colors.white,
        size: 20,
      ),
      label: label,
      isActive: isActive,
      activeColor: activeColor,
      onTap: () => _navigate(context, tab),
    );
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

        // A wide window: the buttons at the top right, in the top bar's row
        // (kept clear for them — see CustomAppBar), dropping in from above.
        if (navBarAtTop(context)) {
          final topTabs = FloatingBottomNavBar.topTabsFor(currentMode);
          final slots = _pillSlots(context, topTabs);
          return Positioned(
            top: MediaQuery.paddingOf(context).top + kTopNavTop,
            right: kTopNavRight,
            width: kSideColumnWidth,
            height: _kPillHeight,
            child: _buttons(context, topTabs, activeColor, kSideColumnWidth,
                travel: -_kEntranceTravel, pills: slots),
          );
        }

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
                  builder: (context, constraints) => _buttons(
                      context, tabs, activeColor, constraints.maxWidth,
                      travel: _kEntranceTravel),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The row of buttons, [totalWidth] wide: round ones centred in it, or,
  /// given [pills]' rects, named pills. Each slides in from [travel] px
  /// below (above, if negative) on the bar's entrance.
  Widget _buttons(BuildContext context, List<BottomNavTab> tabs,
      Color activeColor, double totalWidth,
      {required double travel, List<Rect>? pills}) {
    final itemCount = tabs.length;

    return SizedBox(
      width: totalWidth,
      height: pills == null ? _kCircleSize : _kPillHeight,
      child: AnimatedBuilder(
        animation: _entranceController,
        builder: (context, _) {
          final rects = pills ?? _slots(itemCount, totalWidth);
          final entrance = [
            for (var i = 0; i < itemCount; i++) _entranceProgress(i),
          ];

          return Stack(
            // Ask's colours spill a little past its circle.
            clipBehavior: Clip.none,
            children: [
              // One live blur for the whole bar, cut to every item's shape —
              // instead of a BackdropFilter per item (four re-blurring the
              // same strip of content on every scroll frame). Items keep
              // their own tint and border on top of it.
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: _GlassShapesClipper([
                      for (var i = 0; i < itemCount; i++)
                        _entranceGlassRect(rects[i], entrance[i], travel),
                    ]),
                    // Grouped with the app bar's glass (they never overlap).
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
                      offset: Offset(0, (1 - entrance[i]) * travel),
                      // A TV remote coming up to the bar lands on the open
                      // tab, not just the nearest.
                      child: TvPreferred(
                        preferred: tabs[i] == widget.activeTab,
                        child: pills == null
                            ? _circleFor(context, tabs[i], activeColor)
                            : _pillFor(context, tabs[i], activeColor),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _NavPill({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isActive ? activeColor : Colors.white;
    return Material(
      color: kGlassTint,
      clipBehavior: Clip.antiAlias,
      shape: StadiumBorder(
        side: BorderSide(
          color: isActive ? activeColor.withValues(alpha: 0.45) : kGlassEdge,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 18),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 22,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: _kTransitionDuration,
                    child: KeyedSubtree(key: ValueKey(isActive), child: icon),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedDefaultTextStyle(
                duration: _kTransitionDuration,
                style: _pillTextStyle(context).copyWith(color: textColor),
                child: Text(label, maxLines: 1, softWrap: false),
              ),
            ],
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
      color: kGlassTint,
      clipBehavior: Clip.antiAlias,
      shape: CircleBorder(
        side: BorderSide(
          color: isActive ? activeColor.withValues(alpha: 0.45) : kGlassEdge,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        customBorder: const CircleBorder(),
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
          mouseCursor: WidgetStateMouseCursor.clickable,
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
