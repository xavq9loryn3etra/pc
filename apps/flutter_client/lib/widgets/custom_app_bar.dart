import 'package:flutter/material.dart';
import 'glass_blur.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics/vector_graphics_compat.dart'
    show RenderingStrategy;
import '../theme/app_theme.dart';
import '../screens/search_screen.dart';
import '../screens/favorites_screen.dart';
import 'mode_switcher_dialog.dart';

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
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

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
  Widget _buildDefaultLogo() {
    Widget logo({Color? shadowTint}) => SvgPicture.asset(
          'assets/logo.svg',
          height: 32,
          renderingStrategy: RenderingStrategy.raster,
          colorFilter: ColorFilter.mode(
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

    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: automaticallyImplyLeading,
      leading: leading,
      centerTitle: centerTitle,
      titleSpacing: titleSpacing,
      title: GestureDetector(
        onLongPress: onLogoLongPress,
        child: title ?? _buildDefaultLogo(),
      ),
      backgroundColor: Colors.transparent,
      flexibleSpace: opacity > 0.01
          ? ClipRect(
              child: GlassBlur(
                // Lower peak sigma than the original 20 — this blur is live
                // while scrolling (recomputed every frame), the single
                // highest-frequency backdrop blur in the app, so its cost
                // matters most. See mode_switcher_dialog.dart's comment.
                // Grouped with the floating nav bar's glass (they never
                // overlap), and its own 90% tint needs no extra when the
                // blur is reduced.
                sigma: 10 * opacity,
                grouped: true,
                reducedTint: Colors.transparent,
                child: Container(
                  color: Colors.black.withOpacity(
                      opacity * 0.9), // Increased to 0.9 as requested
                ),
              ),
            )
          : const SizedBox.shrink(),
      actions: actions ??
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
          ],
    );
  }
}
