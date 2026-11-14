import 'package:flutter/scheduler.dart';
import 'package:flutter/cupertino.dart';
import '../widgets/floating_bottom_nav_bar.dart';

/// Tracks which movies-mode tab (Home/Search/Favorites/Settings) is active.
///
/// A singleton rather than widget state because FloatingBottomNavBar can be
/// reached from a screen pushed on top of MovieTabShell (e.g. the desktop
/// home layout's own search/favorites icons), which isn't a descendant of
/// the shell in the widget tree -- it needs a way to switch tabs that
/// doesn't depend on widget ancestry.
class MovieTabService {
  static final MovieTabService _instance = MovieTabService._internal();
  factory MovieTabService() => _instance;
  MovieTabService._internal();

  final ValueNotifier<BottomNavTab> currentTab =
      ValueNotifier(BottomNavTab.home);

  /// The side details panels open over the tabs (the wide layout's — see
  /// DesktopHomeScreen and ScreenScaffold). While there are any, the tab
  /// bar steps aside, as a pushed details page covers it on a phone.
  final ValueNotifier<int> panelsOpen = ValueNotifier(0);

  // ── The side column (a wide window's — see MovieTabShell) ──

  /// The navigator of the column beside the home on a wide window, where
  /// the other tabs, and the titles opened from any of them, show as on a
  /// phone. Its first page is the open tab; titles go on top of it.
  final GlobalKey<NavigatorState> columnNavigator = GlobalKey();

  /// How many pages are open on top of the column's tab: while there are
  /// any, the column stays open even on the Home tab (a title opened from
  /// the home).
  final ValueNotifier<int> columnPages = ValueNotifier(0);

  /// Opens [page] in the column, over whatever was there, if this is a wide
  /// window's layout — true then; false (doing nothing) otherwise.
  bool openInColumn(Widget page) {
    final navigator = columnNavigator.currentState;
    if (navigator == null) return false;
    navigator.popUntil((route) => route.isFirst);
    // After closing any title open before: closing it may have selected
    // the home's poster again.
    rememberFocus();
    navigator.push(CupertinoPageRoute(builder: (_) => page));
    return true;
  }

  /// Back to the column's tab, closing any titles opened over it.
  void closeColumnPages() =>
      columnNavigator.currentState?.popUntil((route) => route.isFirst);

  // What a TV remote had selected outside the column (the poster a title
  // was opened from), to go back to once the column closes.
  FocusNode? _returnFocus;

  /// Notes what's selected now (or [selected]), unless it's in the column
  /// itself.
  void rememberFocus([FocusNode? selected]) {
    final node = selected ?? FocusManager.instance.primaryFocus;
    final columnContext = columnNavigator.currentContext;
    if (node == null || node.context == null) return;
    var inColumn = false;
    if (columnContext != null) {
      node.context!.visitAncestorElements((e) {
        if (identical(e, columnContext)) inColumn = true;
        return !inColumn;
      });
    }
    if (!inColumn) _returnFocus = node;
  }

  /// Selects again what was selected when the column opened, if it's still
  /// there.
  void restoreFocus() {
    final node = _returnFocus;
    _returnFocus = null;
    if (node == null) return;
    // Next frame: on a TV the home can't be selected while the column's
    // open (see _WideTabs), and the column closing takes effect then.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (node.context != null && node.context!.mounted) node.requestFocus();
    });
  }
}

/// Counts the column navigator's pages on top of its first, for
/// [MovieTabService.columnPages].
class ColumnPageCounter extends NavigatorObserver {
  int _depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A first page: a navigator new from scratch (the wide layout built
    // again — a window leaving full screen, say), its count from nothing.
    _depth = previousRoute == null ? 0 : _depth + 1;
    _publish();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth--;
    _publish();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth--;
    _publish();
  }

  /// The count, to MovieTabService.columnPages — after the frame, when
  /// told in the middle of one: a navigator built during a frame (the
  /// layout changing as the window leaves full screen) reports its first
  /// page then, and its listeners can't be rebuilt mid-build.
  void _publish() {
    void publish() {
      final tabs = MovieTabService();
      tabs.columnPages.value = _depth;
      // The last title closed on the Home tab: the column is going, so a
      // TV remote's selection goes back to where it was on the home.
      if (_depth == 0 && tabs.currentTab.value == BottomNavTab.home) {
        tabs.restoreFocus();
      }
    }

    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) => publish());
    } else {
      publish();
    }
  }
}
