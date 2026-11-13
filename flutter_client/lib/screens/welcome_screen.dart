import 'package:flutter/material.dart';

import '../services/feature_flags_service.dart';
import '../widgets/frosted_logo_layout.dart';
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

  String get _blurb => FeatureFlagsService().hidePlayback.value
      ? 'Discover the latest movies, trending music,\nand your next great read.'
      : 'Stream the latest movies, discover trending music,\nand dive into your next great read — all for free.';

  /// The frosted poster wall with the app's icon cut out (see
  /// FrostedLogoLayout), and the welcome beside or below it.
  @override
  Widget build(BuildContext context) {
    return FrostedLogoLayout(
      opacity: _fadeAnimation,
      details: (context, sideBySide, large) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            sideBySide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Text(
            'Movies. Music. Books.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: large ? 44 : 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: large ? -1 : -0.5,
            ),
          ),
          // Its padding keeps the swashes inside the colour; beside the
          // logo it's pulled back so the line starts flush with the
          // headline.
          Transform.translate(
            offset: Offset(sideBySide ? -16 : 0, 0),
            child: IridescentScriptText(
              'All in One Place.',
              fontSize: large ? 64 : 44,
            ),
          ),
          SizedBox(height: large ? 20 : 12),
          Text(
            _blurb,
            textAlign: sideBySide ? TextAlign.start : TextAlign.center,
            style: TextStyle(
              fontSize: large ? 18 : 14,
              color: Colors.white.withValues(alpha: 0.7),
              height: 1.5,
            ),
          ),
          SizedBox(height: large ? 40 : 32),
          // Same white primary button as the status screens — not Popcorn
          // mode's cream.
          StatusPrimaryButton(
            label: 'Get Started',
            onPressed: widget.onGetStarted,
          ),
        ],
      ),
    );
  }
}
