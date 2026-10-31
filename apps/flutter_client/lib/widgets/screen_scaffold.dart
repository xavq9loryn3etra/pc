import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import 'desktop_details_panel.dart';
import '../widgets/custom_app_bar.dart';
import '../widgets/floating_bottom_nav_bar.dart';

typedef BodyBuilder = Widget Function(
    BuildContext context, bool isDesktop, EdgeInsets padding);

class ScreenScaffold extends StatefulWidget {
  final Widget title;
  final Widget? leading;
  final List<Widget>? actions;
  final BodyBuilder body;
  final Movie? selectedMovie;
  final VoidCallback? onCloseSidePanel;
  final bool extendBodyBehindAppBar;

  /// The tab this screen is, when it's one of MovieTabShell's: room is kept
  /// at the bottom for the shell's floating nav bar over it.
  final BottomNavTab? bottomNavTab;

  const ScreenScaffold({
    super.key,
    required this.title,
    required this.body,
    this.leading,
    this.actions,
    this.selectedMovie,
    this.onCloseSidePanel,
    this.extendBodyBehindAppBar = true,
    this.bottomNavTab,
  });

  @override
  State<ScreenScaffold> createState() => _ScreenScaffoldState();
}

class _ScreenScaffoldState extends State<ScreenScaffold> {
  // How far the top-edge fade has faded in (see _withTopFade), from the
  // body's scrolling. A notifier so only the fade repaints while scrolling,
  // not the body.
  final ValueNotifier<double> _fade = ValueNotifier(0.0);

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _fade.value = (n.metrics.pixels / 200).clamp(0.0, 1.0);
    }
    return false;
  }

  /// The home screen's top edge (see MovieHomeScreen._withTopFade): no
  /// glass behind the bar — it stays transparent, and a black-to-clear fade
  /// comes in over the content as it scrolls up under the title.
  Widget _withTopFade(BuildContext context, Widget body) {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: body,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: _fade,
              builder: (context, fade, child) =>
                  Opacity(opacity: fade, child: child),
              child: Container(
                height: MediaQuery.paddingOf(context).top + kToolbarHeight + 40,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black, Colors.transparent],
                    stops: [0.4, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth > 800;
        final bottomSafePadding = MediaQuery.of(context).padding.bottom;

        return Stack(
          children: [
            Scaffold(
              extendBodyBehindAppBar: widget.extendBodyBehindAppBar,
              appBar: CustomAppBar(
                title: widget.title,
                leading: widget.leading,
                actions: widget.actions,
                forceOpacity: 0,
                showActions: false,
                // Its 3 callers (Search/Favorites/Settings) all have the
                // floating bottom nav bar now — mode-switching lives in
                // Settings instead of a header icon.
                showModeSwitch: false,
              ),
              body: _withTopFade(
                context,
                widget.body(
                  context,
                  isDesktop,
                  // Reserve room for the floating nav bar (~110px including
                  // its own top/bottom padding) so scrollable content
                  // doesn't end up rendering underneath/overlapping its
                  // buttons.
                  EdgeInsets.only(
                    bottom: bottomSafePadding +
                        (widget.bottomNavTab != null ? 110 : 0),
                  ),
                ),
              ),
            ),


            // Side panel overlay for desktop
            if (isDesktop && widget.selectedMovie != null)
              Positioned.fill(
                child: Stack(
                  children: [
                    // Darkened background overlay
                    GestureDetector(
                      onTap: widget.onCloseSidePanel,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.6),
                      ),
                    ).animate().fadeIn(duration: 200.ms),

                    // Side panel
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      child: DesktopDetailsPanel(
                        movie: widget.selectedMovie!,
                        onClose: widget.onCloseSidePanel ?? () {},
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
