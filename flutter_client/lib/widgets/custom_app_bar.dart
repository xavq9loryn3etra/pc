import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'glass_blur.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics/vector_graphics_compat.dart'
    show RenderingStrategy;
import '../theme/app_theme.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../screens/search_screen.dart';
import '../screens/favorites_screen.dart';
import 'mode_switcher_dialog.dart';
import 'floating_bottom_nav_bar.dart';
import 'screen_scaffold.dart' show TitleIsland;

class CustomAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final double scrollOffset;
  final double? forceOpacity;
  final VoidCallback? onSearchTap;
  final VoidCallback? onFavoritesTap;
  final VoidCallback? onModeSwitchTap;
  final VoidCallback? onLogoLongPress;
  final bool showActions;
  final bool showModeSwitch;
  final bool automaticallyImplyLeading;
  final bool centerTitle;
  final double? titleSpacing;
  final double? leadingWidth;

  /// The home's scroll: once it's scrolled, the logo sits on a frosted
  /// island, fading in over the first 200px (as the glass bar used to),
  /// instead of a glass bar or a dark fade across the top.
  final ScrollController? logoIslandScroll;

  /// Whether the page under is scrolled, for a page's header (ScreenScaffold):
  /// the top shade's in then (TopShade).
  final ValueListenable<bool>? scrolledShade;

  const CustomAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.scrollOffset = 0.0,
    this.forceOpacity,
    this.onSearchTap,
    this.onFavoritesTap,
    this.onModeSwitchTap,
    this.onLogoLongPress,
    this.showActions = true,
    this.showModeSwitch = true,
    this.automaticallyImplyLeading = true,
    this.centerTitle = false,
    this.titleSpacing,
    this.leadingWidth,
    this.logoIslandScroll,
    this.scrolledShade,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(_isWide ? wideToolbarHeight : kToolbarHeight);

  /// On a wide window the bar is taller, its row in line with the tab
  /// buttons at its top right (see FloatingBottomNavBar), which it keeps
  /// clear. preferredSize is read without a context, so this goes by the
  /// app's window.
  static const double wideToolbarHeight = 80;
  static bool get _isWide {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return false;
    return view.physicalSize.width / view.devicePixelRatio > kTopNavBreakpoint;
  }

  /// Renders the brand wordmark with a drop shadow shaped like the actual
  /// letterforms, not a rectangular box — a plain BoxShadow only shadows a
  /// widget's rectangular bounds, which would paint a visible box behind
  /// the mostly-transparent svg and does nothing useful against a light
  /// hero image behind it (this sits directly over the Home hero backdrop
  /// before the scroll-fade kicks in). Instead the same asset is rendered
  /// twice — once in translucent black, offset slightly behind the real,
  /// brand-colored one — so the shadow traces the letters.
  ///
  /// Both drawn as pictures made once (RenderingStrategy.raster), tinted
  /// as they're drawn, and the shadow unblurred: tinting a vector drawing,
  /// fading it and blurring it each took a layer of its own on every
  /// frame — four of them, still drawn under a details page sliding in.
  ///
  /// Popcorn's in cream; Ramen's in its own colours (its shadow still
  /// one shape).
  Widget _buildDefaultLogo() {
    final ramen = AppModeService().currentMode.value == AppMode.anime;
    Widget logo({Color? shadowTint}) => SvgPicture.asset(
          ramen ? AppMode.anime.logoAsset : 'assets/logo.svg',
          height: 32,
          renderingStrategy: RenderingStrategy.raster,
          colorFilter: ramen && shadowTint == null
              ? null
              : ColorFilter.mode(
                  shadowTint ?? AppTheme.primaryColor,
                  BlendMode.srcIn,
                ),
        );

    return Stack(
      // Stack's own bounds are set by the plain logo (the only non-Positioned
      // child), sized tight — Stack's default Clip.hardEdge would crop the
      // shadow where its offset pushes it past them. Let it show.
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 1.5,
          left: 0.5,
          child: logo(shadowTint: Colors.black.withValues(alpha: 0.35)),
        ),
        logo(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Gradual opacity calculation (divisor 200)
    final double opacity = forceOpacity ?? (scrollOffset / 200).clamp(0.0, 1.0);
    final wide = navBarAtTop(context);

    final inColumn = SideColumnScope.inColumn(context);

    return AppBar(
      toolbarHeight: (inColumn || wide) ? wideToolbarHeight : null,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: automaticallyImplyLeading,
      leading: leading,
      centerTitle: centerTitle,
      titleSpacing: titleSpacing,
      leadingWidth: leadingWidth,
      title: GestureDetector(
        onLongPress: onLogoLongPress,
        child: title ??
            (logoIslandScroll == null
                ? _buildDefaultLogo()
                : LogoIsland(
                    scroll: logoIslandScroll!, child: _buildDefaultLogo())),
      ),
      backgroundColor: Colors.transparent,
      flexibleSpace: logoIslandScroll != null
          ? ScrollShade(scroll: logoIslandScroll!)
          : scrolledShade != null
              ? ValueListenableBuilder<bool>(
                  valueListenable: scrolledShade!,
                  builder: (context, scrolled, _) => TopShade(shown: scrolled),
                )
              : opacity > 0.01
                  ? ClipRect(
                      child: GlassBlur(
                        // Lower peak sigma than the original 20 — this blur is live
                        // while scrolling (recomputed every frame), the single
                        // highest-frequency backdrop blur in the app, so its cost
                        // matters most. See mode_switcher_dialog.dart's comment.
                        // Grouped with the floating nav bar's glass (they never
                        // overlap). Its own tint is all it needs: 90% black, and
                        // solid black where the glass is plain — nothing shows
                        // through it then.
                        sigma: 10 * opacity,
                        grouped: true,
                        reducedTint: Colors.transparent,
                        child: Container(
                          color: Colors.black.withValues(
                              alpha: opacity *
                                  (PlainGlassScope.of(context) ? 1.0 : 0.9)),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
      actions: [
        ..._actions(context),
        // Room for the tab buttons, which sit here on a wide window.
        if (wide) SizedBox(width: topNavWidth(context) + kTopNavRight + 8),
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    return actions ??
        [
          if (showActions) ...[
            IconButton(
              icon: const Icon(Icons.search_rounded, size: 28),
              onPressed: onSearchTap ??
                  () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SearchScreen()),
                    );
                  },
            ),
            IconButton(
              icon: const Icon(Icons.favorite_border_rounded, size: 28),
              onPressed: onFavoritesTap ??
                  () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const FavoritesScreen()),
                    );
                  },
            ),
          ],
          // App Mode Switcher (Mobile Only)
          if (showModeSwitch)
            IconButton(
              icon: const Icon(Icons.grid_view_rounded, size: 28),
              onPressed:
                  onModeSwitchTap ?? () => showModeSwitcherDialog(context),
            ),
          const SizedBox(width: 16),
        ];
  }
}

/// The home's logo, as it is — no island round it once the page is
/// scrolled any more (it looked heavy): a soft dark shade comes down from
/// the top behind it instead (see TopShade, ScrollShade).
class LogoIsland extends StatelessWidget {
  final ScrollController scroll;
  final Widget child;

  const LogoIsland({super.key, required this.scroll, required this.child});

  @override
  Widget build(BuildContext context) => TitleIsland(shown: false, child: child);
}

/// A soft dark shade from the top edge, there while [shown] (the page
/// scrolled), as the Apple TV app's and Netflix's: the logo or a page's
/// title — and the clock above it — stay readable over what scrolls under,
/// with no island round them. No blur, so the same on plain glass and TVs.
class TopShade extends StatelessWidget {
  final bool shown;

  const TopShade({super.key, required this.shown});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        // Filling the space it's given (a bare box would size to nothing).
        child: const SizedBox.expand(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xB3000000),
                  Color(0x73000000),
                  Color(0x00000000)
                ],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [TopShade], in once [scroll] has left the top of the page — only the
/// change rebuilds, not every pixel of the scroll.
class ScrollShade extends StatefulWidget {
  final ScrollController scroll;

  const ScrollShade({super.key, required this.scroll});

  @override
  State<ScrollShade> createState() => _ScrollShadeState();
}

class _ScrollShadeState extends State<ScrollShade> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ScrollShade old) {
    super.didUpdateWidget(old);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final shown = widget.scroll.hasClients && widget.scroll.offset > 4;
    if (shown != _shown) setState(() => _shown = shown);
  }

  @override
  Widget build(BuildContext context) => TopShade(shown: _shown);
}
