import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
  final bool automaticallyImplyLeading;
  final bool centerTitle;

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
    this.automaticallyImplyLeading = true,
    this.centerTitle = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

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
      title: GestureDetector(
        onLongPress: onLogoLongPress,
        child: title ??
            SvgPicture.asset(
              'assets/logo.svg',
              height: 32,
              colorFilter: const ColorFilter.mode(
                AppTheme.primaryColor,
                BlendMode.srcIn,
              ),
            ),
      ),
      backgroundColor: Colors.transparent,
      flexibleSpace: opacity > 0.01
          ? ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: 20 * opacity,
                  sigmaY: 20 * opacity,
                ),
                child: Container(
                  color: Colors.black.withOpacity(opacity * 0.9), // Increased to 0.9 as requested
                ),
              ),
            )
          : const SizedBox.shrink(),
      actions: actions ??
          [
            if (showActions) ...[
              IconButton(
                icon: const Icon(Icons.search, size: 28),
                onPressed: onSearchTap ??
                    () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SearchScreen()),
                      );
                    },
              ),
              IconButton(
                icon: const Icon(Icons.favorite_border, size: 28),
                onPressed: onFavoritesTap ??
                    () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const FavoritesScreen()),
                      );
                    },
              ),
            ],
            // App Mode Switcher (Mobile Only)
            IconButton(
              icon: const Icon(Icons.grid_view, size: 28),
              onPressed: onModeSwitchTap ??
                  () {
                    showGeneralDialog(
                      context: context,
                      barrierDismissible: true,
                      barrierLabel: 'Dismiss',
                      barrierColor: Colors.black.withOpacity(0.5),
                      transitionDuration: const Duration(milliseconds: 300),
                      pageBuilder: (context, animation, secondaryAnimation) {
                        return Stack(
                          children: [
                            // transparent dismiss layer
                            GestureDetector(
                              onTap: () => Navigator.of(context).pop(),
                              behavior: HitTestBehavior.opaque,
                              child: const SizedBox.expand(),
                            ),
                            // The actual dialog content
                            const Align(
                              alignment: Alignment.topCenter,
                              child: ModeSwitcherDialog(),
                            ),
                          ],
                        );
                      },
                      transitionBuilder:
                          (context, animation, secondaryAnimation, child) {
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, -1),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          )),
                          child: child,
                        );
                      },
                    );
                  },
            ),
            const SizedBox(width: 16),
          ],
    );
  }
}
