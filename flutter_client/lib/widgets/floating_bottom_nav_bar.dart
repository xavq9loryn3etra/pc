import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'ask_orb.dart';
import 'glass_blur.dart';
import 'tv_focus.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/app_update_service.dart';
import '../services/movie_tab_service.dart';
import '../services/tv_device.dart';
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

/// Ask's pill shows its logo (the icon and "ask", as on the Ask page and
/// the website) instead of an icon and a label: its icon as tall as the
/// other pills' (20), its "ask" level with their names.
const _kAskLogoHeight = 20.0;
const _kAskLogoWidth = _kAskLogoHeight * 439 / 169; // the SVG's proportions

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
        if (tab == BottomNavTab.ai) return 15 + _kAskLogoWidth.ceilToDouble() + 18;
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

/// Whether the player takes its desktop look (bigger title, controls and
/// text; settings and episodes as side panels): a computer's wide window,
/// or a TV — laid out like the Windows app (TvScreenScale), it showed the
/// phone's player, its title and text too small to read across a room.
/// Not by width alone — a big phone on its side (an S25 Ultra is ~832
/// wide) keeps the phone's player. (A click anywhere playing/pausing stays
/// a computer's: see isComputer.)
bool playerIsWide(BuildContext context) =>
    (isComputer || TvDevice.isTv) && windowIsWide(context);

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
  /// suggests movies and shows, so it's only in Popcorn and Ramen.
  static List<BottomNavTab> tabsFor(AppMode mode) => [
        BottomNavTab.home,
        BottomNavTab.search,
        BottomNavTab.favorites,
        if (mode.isVideo) BottomNavTab.ai,
        BottomNavTab.settings,
      ];

  /// The tabs shown in a wide window's top bar (no Home button, since Home
  /// is always visible beside the side column).
  static List<BottomNavTab> topTabsFor(AppMode mode) => [
        BottomNavTab.search,
        BottomNavTab.favorites,
        if (mode.isVideo) BottomNavTab.ai,
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
              padding: const EdgeInsets.only(left: 15, right: 18),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SvgPicture.asset(
                  'assets/ask-logo.svg',
                  height: _kAskLogoHeight,
                  width: _kAskLogoWidth,
                  semanticsLabel: label,
                ),
              ),
            ),
          ),
        ),
      );
    }
    Widget pill(double bump) => _NavPill(
          icon: Icon(
            data,
            color: isActive ? activeColor : Colors.white,
            size: 20,
          ),
          label: label,
          isActive: isActive,
          activeColor: activeColor,
          bump: bump,
          onTap: () => _navigate(context, tab),
        );
    if (tab != BottomNavTab.settings) return pill(0);
    return _WithUpdateBump(circle: false, builder: pill);
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
        return _WithUpdateBump(
          circle: true,
          builder: (bump) => _NavCircle(
            icon: Icons.settings_rounded,
            activeIcon: Icons.settings_rounded,
            isActive: widget.activeTab == BottomNavTab.settings,
            activeColor: activeColor,
            bump: bump,
            onTap: () => _navigate(context, BottomNavTab.settings),
          ),
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
    // Plain glass: each button paints its own black, so once it's in, the
    // shared layer below only doubled its edge — a second black cut to
    // the same outline, which left the round ends stepped (seen on
    // Windows at 125%). It still grows in under each button's entrance.
    final plain = PlainGlassScope.of(context);

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
                  child: ValueListenableBuilder<bool>(
                    valueListenable: AppUpdateService().showDot,
                    builder: (context, bumped, glass) {
                      final settings = tabs.indexOf(BottomNavTab.settings);
                      // Settings' update bump, once it's in: frosted too.
                      Path? bump;
                      if (bumped &&
                          !plain &&
                          settings >= 0 &&
                          entrance[settings] >= 1) {
                        final (centre, r) = _cornerOf(rects[settings],
                            circle: pills == null);
                        bump = _swellAt(centre, r, 1);
                      }
                      return ClipPath(
                        clipper: _GlassShapesClipper([
                          for (var i = 0; i < itemCount; i++)
                            plain && entrance[i] >= 1
                                ? Rect.zero
                                : _entranceGlassRect(
                                    rects[i], entrance[i], travel),
                        ], extra: bump),
                        child: glass,
                      );
                    },
                    // Grouped with the app bar's glass (they never overlap).
                    // Frosted all the time: going flat as pages opened and
                    // closed, and frosting back over, was seen.
                    child: const GlassBlur(
                      grouped: true,
                      keepsFrost: true,
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

/// The Settings button with its update bump: while a small update is
/// waiting that hasn't been installed (AppUpdateService.showDot), the
/// button's own outline swells out a little at its top right — one shape,
/// one edge, the button's glass — with a dot in the mode's colour in the
/// swell. It grows out when an update comes and back in once it's
/// installed. (A dot stuck on, and then a bump laid over the button, left
/// two edges crossing: owner, 24 Nov 2026.)
class _WithUpdateBump extends StatelessWidget {
  /// The button, given how far its bump is out (0 none, 1 all).
  final Widget Function(double bump) builder;

  /// A round button (else a pill).
  final bool circle;

  const _WithUpdateBump({required this.builder, required this.circle});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppUpdateService().showDot,
      builder: (context, show, _) => Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          // Its Material grows the shape (see _BumpedBorder's lerp).
          builder(show ? 1 : 0),
          IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: show ? 1 : 0),
              // As the Material's own shape change.
              duration: kThemeChangeDuration,
              curve: Curves.fastOutSlowIn,
              builder: (context, grow, _) => grow <= 0.02
                  ? const SizedBox.shrink()
                  : ValueListenableBuilder<AppMode>(
                      valueListenable: AppModeService().currentMode,
                      builder: (context, mode, _) => CustomPaint(
                        painter: _UpdateDotPainter(
                          circle: circle,
                          grow: grow,
                          colour: mode.accentColor,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The update bump's bead: its radius, grown (_swellAt).
const double _kBeadRadius = 6.5;

/// How far the bead's centre sits past the button's edge, grown.
const double _kBeadOut = 1.5;

/// How soft the join between the bead and the button is (the smooth
/// union's reach, in pixels).
const double _kBeadMelt = 10;

/// The bead's centre, from the button's top-right rounding's centre.
double _beadDistance(double r, double grow) =>
    r + _kBeadOut * grow - _kBeadRadius * (1 - grow);

/// Where the bump goes: the centre of a button's top-right rounding in
/// [rect] (the circle's centre, or the pill's right end's), and its radius.
(Offset, double) _cornerOf(Rect rect, {required bool circle}) {
  final r = rect.shortestSide / 2;
  return (
    circle ? rect.center : Offset(rect.right - r, rect.top + r),
    r,
  );
}

/// The diagonal to the top right, the bump's direction.
const double _kSwellAngle = -math.pi / 4;

/// The update bump round [centre] (a button's top-right rounding, of
/// radius [r]), [grow] (0–1) of the way out: a small round bead melted
/// into the button, as two drops of water joining — round over its top,
/// the join curving softly into the button's edge. (A bell-shaped swell
/// came to a point, the dot on its tip: owner, 24 Nov 2026.) Closed
/// through [centre], so in union with the button it's just the bump.
///
/// The outline is where a smooth union of the two circles' distances is
/// zero, found along rays from [centre].
Path _swellAt(Offset centre, double r, double grow) {
  final rb = _kBeadRadius * grow;
  final bd = _beadDistance(r, grow);
  const k = _kBeadMelt;
  // The smooth union's distance at polar (rho, a) round the centre, with
  // the bead along a = 0.
  double field(double rho, double a) {
    final d1 = rho - r;
    final dx = rho * math.cos(a) - bd, dy = rho * math.sin(a);
    final d2 = math.sqrt(dx * dx + dy * dy) - rb;
    final h = math.max(k - (d1 - d2).abs(), 0.0) / k;
    return math.min(d1, d2) - h * h * k / 4;
  }

  final path = Path()..moveTo(centre.dx, centre.dy);
  const steps = 72;
  // Wide enough that its ends are back on the button's edge.
  final halfAngle = math.min(1.2, (rb + k + 4) / r * 1.6);
  for (var i = 0; i <= steps; i++) {
    final a = -halfAngle + 2 * halfAngle * i / steps;
    // The edge along this ray: inside at the button's radius less a bit,
    // outside well past the bead.
    var lo = r - 2, hi = r + rb * 2 + k + 4;
    if (field(r, a) >= 0) {
      lo = hi = r;
    } else {
      for (var j = 0; j < 30; j++) {
        final mid = (lo + hi) / 2;
        if (field(mid, a) < 0) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
    }
    final rho = math.max(r, (lo + hi) / 2);
    final angle = _kSwellAngle + a;
    path.lineTo(
        centre.dx + rho * math.cos(angle), centre.dy + rho * math.sin(angle));
  }
  return path..close();
}

/// A nav button's shape (a circle or a pill) with the update bump swelling
/// out of its top right, [bump] (0–1) of the way. One outline, so the edge
/// runs round the bump too. Lerps, so the Material grows the bump in and
/// out as it changes.
class _BumpedBorder extends OutlinedBorder {
  final bool circle;
  final double bump;

  const _BumpedBorder({super.side, required this.circle, this.bump = 0});

  Path _shape(Rect rect) {
    final base = Path();
    if (circle) {
      base.addOval(rect);
    } else {
      base.addRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)));
    }
    if (bump <= 0.01) return base;
    final (centre, r) = _cornerOf(rect, circle: circle);
    return Path.combine(PathOperation.union, base, _swellAt(centre, r, bump));
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _shape(rect.deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _shape(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    // Inside the shape, as CircleBorder and StadiumBorder draw theirs.
    canvas.drawPath(_shape(rect.deflate(side.width / 2)), side.toPaint());
  }

  @override
  _BumpedBorder copyWith({BorderSide? side}) =>
      _BumpedBorder(side: side ?? this.side, circle: circle, bump: bump);

  @override
  ShapeBorder scale(double t) =>
      _BumpedBorder(side: side.scale(t), circle: circle, bump: bump);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is _BumpedBorder && a.circle == circle) {
      return _BumpedBorder(
        side: BorderSide.lerp(a.side, side, t),
        circle: circle,
        bump: lerpDouble(a.bump, bump, t)!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is _BumpedBorder && b.circle == circle) {
      return _BumpedBorder(
        side: BorderSide.lerp(side, b.side, t),
        circle: circle,
        bump: lerpDouble(bump, b.bump, t)!,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  bool operator ==(Object other) =>
      other is _BumpedBorder &&
      other.side == side &&
      other.circle == circle &&
      other.bump == bump;

  @override
  int get hashCode => Object.hash(side, circle, bump);
}

/// The dot in the update bump, in the mode's colour, in the bead's middle.
class _UpdateDotPainter extends CustomPainter {
  final bool circle;
  final double grow;
  final Color colour;

  const _UpdateDotPainter({
    required this.circle,
    required this.grow,
    required this.colour,
  });

  /// Crisp, with no glow, and well inside the bead: a glow round it
  /// spread over the bead's edge and smudged its curve at real size
  /// (owner, 24 Nov 2026).
  static const double _radius = 2.2;

  @override
  void paint(Canvas canvas, Size size) {
    final (centre, r) = _cornerOf(Offset.zero & size, circle: circle);
    // In the bead's middle.
    final d = _beadDistance(r, grow);
    final dot = centre +
        Offset(math.cos(_kSwellAngle), math.sin(_kSwellAngle)) * d;
    canvas.drawCircle(dot, _radius * grow, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_UpdateDotPainter old) =>
      old.grow != grow || old.colour != colour || old.circle != circle;
}

class _NavPill extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  /// Settings' update bump, 0–1 (_WithUpdateBump).
  final double bump;

  const _NavPill({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
    this.bump = 0,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isActive ? activeColor : Colors.white;
    return Material(
      color: glassTint(context),
      clipBehavior: Clip.antiAlias,
      shape: _BumpedBorder(
        circle: false,
        bump: bump,
        side: BorderSide(
          color: isActive ? activeColor.withValues(alpha: 0.45) : kGlassEdge,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        customBorder: _BumpedBorder(circle: false, bump: bump),
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

  /// Settings' update bump, 0–1 (_WithUpdateBump).
  final double bump;

  const _NavCircle({
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
    this.bump = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Blur comes from the bar's shared glass layer behind it; this paints
    // just the tint, border and ink (clipped to the circle).
    return Material(
      color: glassTint(context),
      clipBehavior: Clip.antiAlias,
      shape: _BumpedBorder(
        circle: true,
        bump: bump,
        side: BorderSide(
          color: isActive ? activeColor.withValues(alpha: 0.45) : kGlassEdge,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        customBorder: _BumpedBorder(circle: true, bump: bump),
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
              filled: true,
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

  /// Settings' update bump, added on (_swellAt).
  final Path? extra;

  const _GlassShapesClipper(this.shapes, {this.extra});

  @override
  Path getClip(Size size) {
    var path = Path();
    for (final r in shapes) {
      if (r.isEmpty) continue;
      path.addRRect(
          RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide / 2)));
    }
    final extra = this.extra;
    if (extra != null) path = Path.combine(PathOperation.union, path, extra);
    return path;
  }

  @override
  bool shouldReclip(_GlassShapesClipper old) {
    if ((old.extra == null) != (extra == null)) return true;
    if (old.shapes.length != shapes.length) return true;
    for (var i = 0; i < shapes.length; i++) {
      if (old.shapes[i] != shapes[i]) return true;
    }
    return false;
  }
}
