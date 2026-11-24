import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../enums/app_mode.dart';
import '../services/movie_tab_service.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/glass_blur.dart';
import '../widgets/tv_focus.dart';
import '../services/tv_device.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'favorites_screen.dart';
import 'settings_screen.dart';
import 'books_home_screen.dart';
import 'book_search_screen.dart';
import 'music_home_screen.dart';
import 'ask_screen.dart';

const _kTabFadeDuration = Duration(milliseconds: 200);

/// The tabs' indexes from [from], bottom to top: the open one first,
/// under the rest — whichever was open before fades out over it.
List<int> _tabOrder(int count, BottomNavTab open, {int from = 0}) => [
      if (open.index >= from && open.index < count) open.index,
      for (var i = from; i < count; i++)
        if (i != open.index) i,
    ];

/// Hosts the four mode tabs (Home, Search, Favorites, Settings), keeping
/// every tab's widget alive per mode so switching preserves scroll position,
/// search text, etc. and never refetches data. Uses a Stack of per-tab
/// AnimatedOpacity so switching cross-fades smoothly.
///
/// The bottom nav bar is one for all the tabs, over them, so it stays put
/// while they cross-fade under it. With a bar per tab, two see-through bars
/// faded over each other on every switch — the glass flickered lighter —
/// and the bar's own slide between the Home and Search layouts never ran.
class MovieTabShell extends StatelessWidget {
  /// Its mode, for good: a mode change builds a new shell (MainScreen), and
  /// this one, fading out, stays as it was — rather than rebuilding every
  /// tab in the new mode only to be thrown away.
  final AppMode mode;

  const MovieTabShell({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        final screens = _getScreensForMode(mode);

        return ValueListenableBuilder<BottomNavTab>(
          valueListenable: MovieTabService().currentTab,
          builder: (context, selectedTab, _) {
            // A mode without the tab that was open (Ask, only in movies)
            // shows its home instead.
            final activeTab = selectedTab.index < screens.length
                ? selectedTab
                : BottomNavTab.home;
            // A wide window: the home, and the other tabs in a column
            // beside it, shown as on a phone.
            if (navBarAtTop(context)) {
              return _WideTabs(
                mode: mode,
                home: screens.first,
                activeTab: activeTab,
                navBar: _navLayer(mode, activeTab),
              );
            }
            return Stack(
              children: [
                // The open tab underneath, there at once, and the one left
                // fading out over it (see _tabOrder): the tabs' shared glow
                // (TabGlow) stays as it is through a switch, instead of
                // dipping as two half-faded copies of it.
                for (final i in _tabOrder(screens.length, activeTab))
                  IgnorePointer(
                    key: ValueKey(i),
                    ignoring: BottomNavTab.values[i] != activeTab,
                    // Out of reach of a TV remote or keyboard too, not just
                    // of taps, while hidden.
                    child: ExcludeFocus(
                      excluding: BottomNavTab.values[i] != activeTab,
                      child: AnimatedOpacity(
                        opacity:
                            BottomNavTab.values[i] == activeTab ? 1.0 : 0.0,
                        duration: BottomNavTab.values[i] == activeTab
                            ? Duration.zero
                            : _kTabFadeDuration,
                        curve: Curves.easeOut,
                        // The hidden tabs' animations paused — Ask's glow,
                        // a loading shimmer — rather than running unseen.
                        child: TickerMode(
                          enabled: BottomNavTab.values[i] == activeTab,
                          child: screens[i],
                        ),
                      ),
                    ),
                  ),
                _navLayer(mode, activeTab),
              ],
            );
          },
        );
      },
    );
  }

  /// The tab bar over the tabs — stepping aside while a side details panel
  /// is open.
  Widget _navLayer(AppMode mode, BottomNavTab activeTab) {
    return Positioned.fill(
      child: ValueListenableBuilder<int>(
        valueListenable: MovieTabService().panelsOpen,
        builder: (context, panels, navBar) => AnimatedOpacity(
          opacity: panels > 0 ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: panels > 0,
            child: ExcludeFocus(excluding: panels > 0, child: navBar!),
          ),
        ),
        child: Stack(children: [_navBar(mode, activeTab)]),
      ),
    );
  }

  Widget _navBar(AppMode mode, BottomNavTab activeTab) {
    return ValueListenableBuilder<bool>(
      valueListenable: MovieHomeScreen.revealed,
      builder: (context, homeRevealed, _) {
        final onHome = activeTab == BottomNavTab.home;
        // Not built until the movie home has loaded: the bar plays a
        // staggered pop-in the first time it's built, which should show
        // as the home's skeleton fades rather than happen while it loads.
        if (onHome && mode.isVideo && !homeRevealed) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: ValueListenableBuilder<int>(
            valueListenable: MovieTabService().columnPages,
            builder: (context, pages, _) => Stack(
              children: [
                FloatingBottomNavBar(
                  activeTab: pages > 0 ? BottomNavTab.home : activeTab,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static List<Widget> _getScreensForMode(AppMode mode) {
    switch (mode) {
      // In BottomNavTab's order (see FloatingBottomNavBar.tabsFor).
      case AppMode.movies:
        return const [
          MovieHomeScreen(),
          SearchScreen(),
          FavoritesScreen(),
          SettingsScreen(),
          AskScreen(),
        ];
      // Ramen: Popcorn's tabs, each showing anime only.
      case AppMode.anime:
        return const [
          MovieHomeScreen(mode: AppMode.anime),
          SearchScreen(mode: AppMode.anime),
          FavoritesScreen(),
          SettingsScreen(),
          AskScreen(mode: AppMode.anime),
        ];
      case AppMode.books:
        return const [
          BooksHomeScreen(),
          BookSearchScreen(),
          FavoritesScreen(),
          SettingsScreen(),
        ];
      case AppMode.music:
        return const [
          MusicHomeScreen(),
          SearchScreen(),
          FavoritesScreen(),
          SettingsScreen(),
        ];
    }
  }
}

const _kColumnWidth = kSideColumnWidth;
const _kColumnGap = kSideColumnGap;
const _kColumnDuration = Duration(milliseconds: 280);

/// A wide window's tabs: the home on the left, and the other tabs — and
/// any title opened from any of them, home included — in a column on the
/// right, below the bar. The column's screen is a phone's (see
/// _SideColumn), so the tabs and the details page show there as they do
/// on a phone, with no layouts of their own for a wide window. It opens,
/// the home narrowing beside it, on any tab but Home or when a title is
/// open in it; Home closes it.
class _WideTabs extends StatelessWidget {
  final AppMode mode;
  final Widget home;
  final BottomNavTab activeTab;
  final Widget navBar;

  const _WideTabs({
    required this.mode,
    required this.home,
    required this.activeTab,
    required this.navBar,
  });

  // For the session's first three frames — as the screen fades in from
  // the mode picker — the column with all its tabs is drawn in its open
  // place, with the home's cut-out corner and glass circle and a tab bar
  // with a tab lit, all under a black cover: on Windows the graphics
  // engine readies each effect (the frosted glass, the clipping) the first
  // time it's drawn, and the first tap on a tab froze the panel's slide
  // for a quarter second. Measured in a profile build: the first open's
  // worst frame 260 ms → about 130, the first close's 170 → about 80, the
  // column's first tab switches smooth. (Flutter's newer engine, Impeller,
  // takes it to 19 ms — but Windows apps can't turn it on yet.)
  static final _warming = ValueNotifier<bool>(true);
  static bool _warmStarted = false;
  // The frame warming up ends on: what it showed goes at once.
  static bool _warmJustEnded = false;

  static void _startWarmUp() {
    if (_warmStarted) return;
    _warmStarted = true;
    var frames = 0;
    void next(Duration _) {
      if (++frames >= 3) {
        _warmJustEnded = true;
        _warming.value = false;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _warmJustEnded = false);
      } else {
        WidgetsBinding.instance.addPostFrameCallback(next);
        WidgetsBinding.instance.scheduleFrame();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(next);
  }

  @override
  Widget build(BuildContext context) {
    _startWarmUp();
    return ListenableBuilder(
      listenable:
          Listenable.merge([MovieTabService().columnPages, _warming]),
      builder: (context, _) {
        final pages = MovieTabService().columnPages.value;
        final open = activeTab != BottomNavTab.home || pages > 0;
        final warm = _warming.value && !open;
        return LayoutBuilder(
          builder: (context, box) {
            // Below the bar's row (see CustomAppBar.wideToolbarHeight).
            final top = MediaQuery.paddingOf(context).top + 80;
            final columnSize = Size(
              _kColumnWidth,
              math.max(0, box.maxHeight - top - _kColumnGap),
            );
            return Stack(
              children: [
                // Black round the column, as the app's pages are — not the
                // grey of whatever's behind the shell.
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                AnimatedPositioned(
                  duration: _kColumnDuration,
                  curve: Curves.easeOutCubic,
                  left: open ? _kColumnGap : 0,
                  // Below the top safe area, as the tab bar is (see
                  // FloatingBottomNavBar's top row), so the collapse button
                  // in the corner lines up with its pills: on an iPad, and
                  // the iPad app on a Mac, the area's not 0 as on Windows,
                  // and the button sat higher than the bar.
                  top: open
                      ? MediaQuery.paddingOf(context).top + _kColumnGap
                      : 0,
                  bottom: open ? _kColumnGap : 0,
                  right: open ? _kColumnWidth + _kColumnGap * 2 : 0,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: open ? 1.0 : 0.0),
                    duration: _kColumnDuration,
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => ClipPath(
                      clipper: _HomePanelClipper(t),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          child!,
                          if (t > 0.001) ...[
                            // Slightly larger than _HomePanelClipper's 22px
                            // circle (while still inside the 36px moat) so
                            // the blur and tint cover the entire circle before
                            // _HomePanelClipper clips it — preventing an
                            // un-tinted 1px halo around the anti-aliased edge.
                            Positioned(
                              top: 0,
                              right: 0,
                              width: 48 * t,
                              height: 48 * t,
                              child: IgnorePointer(
                                child: ClipOval(
                                  child: GlassBlur(
                                    child: ColoredBox(color: glassTint(context)),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 2 * t,
                              right: 2 * t,
                              width: kNavButtonHeight,
                              height: kNavButtonHeight,
                              child: IgnorePointer(
                                ignoring: !open,
                                child: Transform.scale(
                                  scale: t,
                                  child: Tooltip(
                                    message: 'Collapse side panel',
                                    child: Material(
                                      type: MaterialType.transparency,
                                      child: InkWell(
                                        mouseCursor: WidgetStateMouseCursor.clickable,
                                        customBorder: const CircleBorder(),
                                        onTap: () {
                                          MovieTabService().closeColumnPages();
                                          MovieTabService().currentTab.value =
                                              BottomNavTab.home;
                                          // On a TV, back to what was
                                          // selected on the home.
                                          MovieTabService().restoreFocus();
                                        },
                                        child: const Center(
                                          child: Icon(
                                            Icons.last_page_rounded,
                                            color: Colors.white,
                                            size: 22,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // On a TV, out of the remote's reach while the column's
                    // open: it stays in the column and the nav bar until the
                    // column's closed (Back, or collapse above).
                    child: ExcludeFocus(
                      excluding: open && TvDevice.isTv,
                      child: home,
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: _kColumnDuration,
                  curve: Curves.easeOutCubic,
                  top: top,
                  width: _kColumnWidth,
                  height: columnSize.height,
                  right: open ? _kColumnGap : -(_kColumnWidth + _kColumnGap),
                  child: IgnorePointer(
                    ignoring: !open,
                    // Off-screen while closed: out of a TV remote's or a
                    // keyboard's reach too.
                    child: ExcludeFocus(
                      excluding: !open,
                      child: TickerMode(
                        enabled: open,
                        // Warming up (see _warming): in its open place.
                        // Always wrapped, so the column isn't rebuilt when
                        // it ends.
                        child: Transform.translate(
                          offset: warm
                              ? const Offset(
                                  -(_kColumnWidth + _kColumnGap * 2), 0)
                              : Offset.zero,
                          child: _SideColumn(mode: mode, size: columnSize),
                        ),
                      ),
                    ),
                  ),
                ),
                // Warming up: the home's cut-out corner and glass circle at
                // the home's size, a tab bar with a tab lit, then black
                // over it all.
                if (warm) ...[
                  Positioned(
                    left: _kColumnGap,
                    top: _kColumnGap,
                    bottom: _kColumnGap,
                    right: _kColumnWidth + _kColumnGap * 2,
                    child: const IgnorePointer(
                      child: ClipPath(
                        clipper: _HomePanelClipper(0.5),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: Color(0xFF0A0A0A)),
                            Positioned(
                              top: 0,
                              right: 0,
                              width: 24,
                              height: 24,
                              child: ClipOval(
                                child: GlassBlur(
                                  child: ColoredBox(color: kGlassTint),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ExcludeFocus(
                        child: Stack(children: [
                          FloatingBottomNavBar(
                              activeTab: BottomNavTab.search),
                        ]),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Colors.black),
                    ),
                  ),
                ],
                navBar,
              ],
            );
          },
        );
      },
    );
  }
}

/// Clips the shrunk Home container with 24px outer rounded corners and a
/// smooth inverted-corner cutout at the top-right pocket ([t] = 0..1) that
/// houses the 44×44 collapse button.
class _HomePanelClipper extends CustomClipper<Path> {
  final double t;

  const _HomePanelClipper(this.t);

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    if (t <= 0.001) {
      return Path()..addRect(Offset.zero & size);
    }
    final r = 24.0 * t;
    final s = 60.0 * t;
    final r1 = 20.0 * t;
    final r2 = 36.0 * t;

    return Path()
      ..moveTo(0, r)
      ..arcToPoint(
        Offset(r, 0),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..lineTo(w - s - r1, 0)
      ..arcToPoint(
        Offset(w - s, r1),
        radius: Radius.circular(r1),
        clockwise: true,
      )
      ..lineTo(w - s, s - r2)
      ..arcToPoint(
        Offset(w - s + r2, s),
        radius: Radius.circular(r2),
        clockwise: false,
      )
      ..lineTo(w - r1, s)
      ..arcToPoint(
        Offset(w, s + r1),
        radius: Radius.circular(r1),
        clockwise: true,
      )
      ..lineTo(w, h - r)
      ..arcToPoint(
        Offset(w - r, h),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..lineTo(r, h)
      ..arcToPoint(
        Offset(0, h - r),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..close()
      // Keep the collapse button's circular patch of the Home hero backdrop
      // unclipped beneath the frosted GlassCircleButton so its blur samples
      // the actual hero edge at that corner.
      ..addOval(
        Rect.fromCircle(
          center: Offset(w - 24.0 * t, 24.0 * t),
          radius: 22.0 * t,
        ),
      );
  }

  @override
  bool shouldReclip(_HomePanelClipper oldClipper) => oldClipper.t != t;
}

/// The column: a rounded panel whose screen is phone-sized, holding its
/// own navigator — its first page the open tab (see _ColumnTabs), titles
/// opened over it as on a phone. Players and popups open over the whole
/// window instead (from the root navigator).
class _SideColumn extends StatefulWidget {
  final AppMode mode;
  final Size size;

  const _SideColumn({required this.mode, required this.size});

  @override
  State<_SideColumn> createState() => _SideColumnState();
}

class _SideColumnState extends State<_SideColumn> {
  final _counter = ColumnPageCounter();
  // Its own navigator key: the shell fading out on a mode change still has
  // its column for a moment, and with one key for both, the new shell took
  // the old one's whole column — Settings and its switch included, still
  // in the old mode, so the next switch did nothing.
  late final _navigatorKey = MovieTabService().newColumnNavigator();
  // Its own, as a navigator can't share the app's.
  final _heroes = MaterialApp.createMaterialHeroController();

  static const _radius = BorderRadius.all(Radius.circular(24));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _radius,
      child: ColoredBox(
        color: Colors.black,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: widget.size,
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
          ),
          child: SideColumnScope(
            child: HeroControllerScope(
              controller: _heroes,
              // Back is always the app's on this layout: MainScreen takes
              // it, closing this column's pages first. Left alone, this
              // navigator told Android the app had nothing to go back to
              // whenever it was down to its first page — and Android then
              // took Back itself, so on a TV one press left the app.
              child: NotificationListener<NavigationNotification>(
                onNotification: (notification) {
                  if (notification.canHandlePop) return false;
                  const NavigationNotification(canHandlePop: true)
                      .dispatch(context);
                  return true;
                },
                // Its pages are their own focus scopes: a TV remote's up
                // from a page's top goes on to the nav bar over it (and
                // left, to the home) rather than nowhere.
                child: TvFocusPassThrough(
                  child: Navigator(
                    key: _navigatorKey,
                    observers: [_counter],
                    onGenerateRoute: (_) => PageRouteBuilder(
                      pageBuilder: (_, __, ___) => _ColumnTabs(mode: widget.mode),
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

/// The column's first page: the open tab other than Home, cross-fading as
/// the shell's tabs do; nothing on Home (a title opened from the home is
/// over it).
class _ColumnTabs extends StatelessWidget {
  final AppMode mode;

  const _ColumnTabs({required this.mode});

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        final screens = MovieTabShell._getScreensForMode(mode);
        return ListenableBuilder(
          listenable: Listenable.merge(
              [MovieTabService().currentTab, _WideTabs._warming]),
          builder: (context, _) {
            final tab = MovieTabService().currentTab.value;
            return Stack(
            children: [
              // The open tab under the rest, there at once (see _tabOrder).
              for (final i in _tabOrder(screens.length, tab, from: 1))
                IgnorePointer(
                  key: ValueKey(i),
                  ignoring: BottomNavTab.values[i] != tab,
                  child: ExcludeFocus(
                    excluding: BottomNavTab.values[i] != tab,
                    // Warming up (see _WideTabs._warming): every tab
                    // drawn — shown and hidden again at once, with no fade,
                    // which wouldn't run while the column's closed and its
                    // animations are paused.
                    child: AnimatedOpacity(
                      opacity: BottomNavTab.values[i] == tab ||
                              _WideTabs._warming.value
                          ? 1.0
                          : 0.0,
                      duration: _WideTabs._warming.value ||
                              _WideTabs._warmJustEnded ||
                              BottomNavTab.values[i] == tab
                          ? Duration.zero
                          : _kTabFadeDuration,
                      curve: Curves.easeOut,
                      child: TickerMode(
                        enabled: BottomNavTab.values[i] == tab,
                        child: screens[i],
                      ),
                    ),
                  ),
                ),
            ],
          );
          },
        );
      },
    );
  }
}
