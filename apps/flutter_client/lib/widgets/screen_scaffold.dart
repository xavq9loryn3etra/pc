import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import 'desktop_details_panel.dart';
import '../widgets/custom_app_bar.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import 'glass_blur.dart';

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
  // Whether the body's scrolled from the top, which brings in the
  // title's island (see _TitleIsland). A notifier so only the title
  // rebuilds as it changes, not the body.
  final ValueNotifier<bool> _scrolled = ValueNotifier(false);

  @override
  void dispose() {
    _scrolled.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _scrolled.value = n.metrics.pixels > 4;
    }
    return false;
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
                // On its island once the page is scrolled, as the details
                // page's title is (see GlassBubbleBar) — instead of a black
                // fade over the content behind it.
                title: ValueListenableBuilder<bool>(
                  valueListenable: _scrolled,
                  builder: (context, scrolled, title) =>
                      _TitleIsland(shown: scrolled, child: title!),
                  child: widget.title,
                ),
                leading: widget.leading,
                actions: widget.actions,
                forceOpacity: 0,
                showActions: false,
                // Its 3 callers (Search/Favorites/Settings) all have the
                // floating bottom nav bar now — mode-switching lives in
                // Settings instead of a header icon.
                showModeSwitch: false,
              ),
              body: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child:                 widget.body(
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

/// A page's title, on an island of the app's frosted glass while [shown]
/// (the page is scrolled), as the details page's title is. The island
/// opens out from its middle and folds back into it, its tint fading
/// with it: the blur itself can't be faded (it popped off at the end),
/// only cut smaller. The title stays put, always room enough round it.
/// The glass is only there while showing, so it costs nothing at the top
/// of the page.
class _TitleIsland extends StatelessWidget {
  final bool shown;
  final Widget child;

  const _TitleIsland({required this.shown, required this.child});

  static const double _height = 40; // As GlassBubbleBar's
  static const double _padding = 14;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: shown ? 1 : 0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeInOutCubic,
      child: child,
      builder: (context, t, child) => SizedBox(
        height: _height,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (t > 0)
              Positioned.fill(
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.7 + 0.3 * t,
                    heightFactor: t,
                    child: ClipRRect(
                      borderRadius:
                          const BorderRadius.all(Radius.circular(_height / 2)),
                      // Grouped with the nav bar's glass, which it never
                      // overlaps.
                      child: GlassBlur(
                        grouped: true,
                        reducedTint: Colors.black.withValues(alpha: 0.55),
                        child: Opacity(
                          opacity: t,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: kGlassTint,
                              borderRadius: const BorderRadius.all(
                                  Radius.circular(_height / 2)),
                              border: Border.all(color: kGlassEdge),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _padding),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
