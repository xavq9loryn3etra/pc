import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import 'desktop_details_panel.dart';
import '../widgets/custom_app_bar.dart';

typedef BodyBuilder = Widget Function(
    BuildContext context, bool isDesktop, EdgeInsets padding);

class ScreenScaffold extends StatelessWidget {
  final Widget title;
  final List<Widget>? actions;
  final BodyBuilder body;
  final double opacity;
  final Movie? selectedMovie;
  final VoidCallback? onCloseSidePanel;
  final bool extendBodyBehindAppBar;

  const ScreenScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.opacity = 0.0,
    this.selectedMovie,
    this.onCloseSidePanel,
    this.extendBodyBehindAppBar = true,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth > 800;
        final bottomSafePadding = MediaQuery.of(context).padding.bottom;

        return Stack(
          children: [
            Scaffold(
              extendBodyBehindAppBar: extendBodyBehindAppBar,
              appBar: CustomAppBar(
                title: title,
                actions: actions,
                forceOpacity: opacity,
                showActions: false, // Scaffold users provide their own actions
              ),
              body: body(
                context,
                isDesktop,
                EdgeInsets.only(bottom: bottomSafePadding),
              ),
            ),

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
