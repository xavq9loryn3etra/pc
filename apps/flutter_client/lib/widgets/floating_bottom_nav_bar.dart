import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
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

/// Floating tab bar for the Popcorn (movies) mobile experience, replacing
/// the old header icon buttons. Sits on a bottom-fading gradient so it stays
/// legible over whatever scrolls beneath it. Selection is indicated purely
/// by icon style (outline -> solid) rather than a background-color change,
/// since the background is already the app's own black.
///
/// Normally Search is a wide pill filling the space between Home and
/// Favorites/Settings. When Search itself becomes the active tab it
/// collapses to a circle matching the others, and all 4 items animate
/// together into a tightly-packed, centered group — using explicit
/// Stack + AnimatedPositioned (rather than a Row) so every item's position
/// animates in sync instead of only Search's own width changing while the
/// rest stay pinned where they were.
class FloatingBottomNavBar extends StatelessWidget {
  final BottomNavTab activeTab;

  const FloatingBottomNavBar({super.key, required this.activeTab});

  void _navigate(BuildContext context, BottomNavTab tab) {
    if (tab == activeTab) return;

    // Tabs live in MovieTabShell's IndexedStack, so switching is just a
    // value flip — no rebuild, no refetch, scroll/search state stays put.
    // popUntil covers the case where this bar is on a screen pushed on top
    // of the shell (e.g. desktop home's own search/favorites icons): it's
    // a no-op if we're already inside the shell, or unwinds back down to
    // it otherwise so the newly selected tab becomes visible.
    MovieTabService().currentTab.value = tab;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Widget _circleFor(BuildContext context, BottomNavTab tab) {
    switch (tab) {
      case BottomNavTab.home:
        return _NavCircle(
          icon: Icons.home_outlined,
          activeIcon: Icons.home_rounded,
          isActive: activeTab == BottomNavTab.home,
          onTap: () => _navigate(context, BottomNavTab.home),
        );
      case BottomNavTab.search:
        return _SearchPill(
          isActive: activeTab == BottomNavTab.search,
          onTap: () => _navigate(context, BottomNavTab.search),
        );
      case BottomNavTab.favorites:
        return _NavCircle(
          icon: Icons.favorite_border,
          activeIcon: Icons.favorite_rounded,
          isActive: activeTab == BottomNavTab.favorites,
          onTap: () => _navigate(context, BottomNavTab.favorites),
        );
      case BottomNavTab.settings:
        return _NavCircle(
          icon: Icons.settings_outlined,
          activeIcon: Icons.settings_rounded,
          isActive: activeTab == BottomNavTab.settings,
          onTap: () => _navigate(context, BottomNavTab.settings),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final isSearchActive = activeTab == BottomNavTab.search;

    final tabs = [
      BottomNavTab.home,
      BottomNavTab.search,
      BottomNavTab.favorites,
      BottomNavTab.settings,
    ];

    final barHeight = 40 + _kCircleSize + bottomPadding + 16;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        children: [
          // Bottom-fading gradient behind the buttons. Purely decorative —
          // IgnorePointer keeps it from swallowing touches. A plain
          // Container with a decoration hit-tests as a solid opaque
          // rectangle across its whole bounds no matter how transparent it
          // *looks*, so without this, the near-transparent top portion of
          // the gradient silently ate scroll/swipe gestures that should
          // have reached the content still visible behind it.
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
                final step = _kCircleSize + _kGap;

                // Normal layout: Search fills whatever's left after every
                // other (fixed-size) item, in whatever order/count `tabs` is.
                final wideSearchWidth = (totalWidth -
                        _kCircleSize * (itemCount - 1) -
                        _kGap * (itemCount - 1))
                    .clamp(_kCircleSize, double.infinity);
                final normalX = <double>[];
                double x = 0;
                for (final tab in tabs) {
                  normalX.add(x);
                  x += (tab == BottomNavTab.search
                          ? wideSearchWidth
                          : _kCircleSize) +
                      _kGap;
                }

                // Search-active layout: every item becomes an equal circle,
                // packed tightly together and centered as one group.
                final groupWidth =
                    _kCircleSize * itemCount + _kGap * (itemCount - 1);
                final groupStart =
                    ((totalWidth - groupWidth) / 2).clamp(0.0, totalWidth);

                return SizedBox(
                  width: totalWidth,
                  height: _kCircleSize,
                  child: Stack(
                    children: [
                      for (var i = 0; i < itemCount; i++)
                        AnimatedPositioned(
                          duration: _kBounceDuration,
                          curve: _kBounceCurve,
                          left: isSearchActive
                              ? groupStart + i * step
                              : normalX[i],
                          top: 0,
                          width:
                              tabs[i] == BottomNavTab.search && !isSearchActive
                                  ? wideSearchWidth
                                  : _kCircleSize,
                          height: _kCircleSize,
                          child: _circleFor(context, tabs[i]),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _SearchPill({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Same frosted-glass recipe as CustomAppBar/ModeSwitcherDialog: clip to
    // the pill shape, blur what's scrolling underneath, then a translucent
    // tint on top so the icon/text stay legible over any background.
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Material(
          color: AppTheme.scaffoldColor.withOpacity(0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
            side: BorderSide(color: Colors.white.withOpacity(0.14), width: 1),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(26),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: _kTransitionDuration,
                    child: Icon(
                      isActive ? Icons.search_rounded : Icons.search_outlined,
                      key: ValueKey(isActive),
                      color: isActive ? AppTheme.primaryColor : Colors.white,
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
      ),
    );
  }
}

class _NavCircle extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final bool isActive;
  final VoidCallback onTap;

  const _NavCircle({
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Material(
          color: AppTheme.scaffoldColor.withOpacity(0.35),
          shape: CircleBorder(
            side: BorderSide(color: Colors.white.withOpacity(0.14), width: 1),
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
                    color: isActive ? AppTheme.primaryColor : Colors.white,
                    size: 24,
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
