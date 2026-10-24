import 'package:flutter/material.dart';

import '../theme/iridescent.dart';
import '../services/feature_flags_service.dart';
import '../widgets/poster_wall.dart';
import '../widgets/status_screen.dart';

class WelcomeScreen extends StatefulWidget {
  final VoidCallback onGetStarted;

  const WelcomeScreen({super.key, required this.onGetStarted});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  // Fade-in animation
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fadeController.forward();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: PosterWall()),

          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.1),
                    Colors.black.withValues(alpha: 0.6),
                    Colors.black.withValues(alpha: 0.95),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.2, 0.55, 0.75, 0.9],
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The app's own mark (as on the app icon and splash), not
                    // Popcorn mode's logo: this screen introduces all three
                    // modes.
                    Iridescent(
                      child: Image.asset(
                        'assets/icon-transparent.png',
                        width: 72,
                        height: 72,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Movies. Music. Books.',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    // Same script headline line as the status screens.
                    const IridescentScriptText('All in One Place.'),
                    const SizedBox(height: 16),
                    Text(
                      FeatureFlagsService().hidePlayback.value
                          ? 'Discover the latest movies, trending music,\nand your next great read.'
                          : 'Stream the latest movies, discover trending music,\nand dive into your next great read — all for free.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.6),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Same white primary button as the status screens — not
                    // Popcorn mode's cream.
                    StatusPrimaryButton(
                      label: 'Get Started',
                      onPressed: widget.onGetStarted,
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
