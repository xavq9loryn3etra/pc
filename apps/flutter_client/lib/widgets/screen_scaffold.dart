import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import 'desktop_details_panel.dart';
import '../widgets/custom_app_bar.dart';
import '../widgets/floating_bottom_nav_bar.dart';

typedef BodyBuilder = Widget Function(
    BuildContext context, bool isDesktop, EdgeInsets padding);

class ScreenScaffold extends StatelessWidget {
  final Widget title;
  final Widget? leading;
  final List<Widget>? actions;
  final BodyBuilder body;
  final double opacity;
  // Scroll-driven app-bar fade, as a listenable instead of a plain double.
  // When set, only the AppBar repaints as it changes — the screen (and
  // this widget's own build()) never re-runs, so `body(...)` isn't
  // reinvoked and the scrollable content underneath isn't forced to
  // rebuild on every scroll tick. Falls back to the static [opacity]
  // field when absent (e.g. Settings, which has no scroll fade at all).
  final ValueListenable<double>? opacityListenable;
  final Movie? selectedMovie;
  final VoidCallback? onCloseSidePanel;
  final bool extendBodyBehindAppBar;
  final BottomNavTab? bottomNavTab;

  const ScreenScaffold({
    super.key,
    required this.title,
    required this.body,
    this.leading,
    this.actions,
    this.opacity = 0.0,
    this.opacityListenable,
    this.selectedMovie,
    this.onCloseSidePanel,
    this.extendBodyBehindAppBar = true,
    this.bottomNavTab,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth > 800;
        final bottomSafePadding = MediaQuery.of(context).padding.bottom;

        // An if/else into a pre-declared variable, not a ternary — Dart
        // infers a bare ternary's static type as the LUB of the two
        // branches' own types (here, Widget, since PreferredSize and
        // CustomAppBar only share the class hierarchy at that level), not
        // their shared PreferredSizeWidget interface, so Scaffold.appBar
        // rejects it even with an explicitly-typed target variable.
        // Independent if/else assignments don't have that problem — each
        // is checked against the variable's declared type on its own.
        final PreferredSizeWidget appBar;
        if (opacityListenable != null) {
          appBar = PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: ValueListenableBuilder<double>(
              valueListenable: opacityListenable!,
              builder: (context, liveOpacity, _) => CustomAppBar(
                title: title,
                leading: leading,
                actions: actions,
                forceOpacity: liveOpacity,
                showActions: false, // Scaffold users provide their own actions
                // Its 3 callers (Search/Favorites/Settings) all have the
                // floating bottom nav bar now — mode-switching lives in
                // Settings instead of a header icon.
                showModeSwitch: false,
              ),
            ),
          );
        } else {
          appBar = CustomAppBar(
            title: title,
            leading: leading,
            actions: actions,
            forceOpacity: opacity,
            showActions: false,
            showModeSwitch: false,
          );
        }

        return Stack(
          children: [
            Scaffold(
              extendBodyBehindAppBar: extendBodyBehindAppBar,
              appBar: appBar,
              body: body(
                context,
                isDesktop,
                // Reserve room for the floating nav bar (~110px including its
                // own top/bottom padding) so scrollable content doesn't end
                // up rendering underneath/overlapping its buttons.
                EdgeInsets.only(
                  bottom: bottomSafePadding + (bottomNavTab != null ? 110 : 0),
                ),
              ),
            ),

            if (bottomNavTab != null)
              FloatingBottomNavBar(activeTab: bottomNavTab!),

            // Side panel overlay for desktop
            if (isDesktop && selectedMovie != null)
              Positioned.fill(
                child: Stack(
                  children: [
                    // Darkened background overlay
                    GestureDetector(
                      onTap: onCloseSidePanel,
                      child: Container(
                        color: Colors.black.withOpacity(0.6),
                      ),
                    ).animate().fadeIn(duration: 200.ms),

                    // Side panel
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      child: DesktopDetailsPanel(
                        movie: selectedMovie!,
                        onClose: onCloseSidePanel ?? () {},
                      )
                          .animate()
                          .slideX(
                            begin: 1.0,
                            end: 0.0,
                            duration: 300.ms,
                            curve: Curves.easeOutCubic,
                          )
                          .fadeIn(duration: 200.ms),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
