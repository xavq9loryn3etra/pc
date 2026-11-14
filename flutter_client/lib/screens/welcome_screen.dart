import 'package:flutter/material.dart';

import '../services/app_mode_service.dart';
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

  // Where the app is Popcorn only (the desktop app, a TV), it's about
  // movies and shows alone: music and books aren't there.
  static final _popcornOnly = !AppModeService.canSwitchMode;

  // "TV Shows" kept together (a no-break space) where the line wraps.
  String get _headline =>
      _popcornOnly ? 'Movies. TV Shows.' : 'Movies. Music. Books.';

  String get _blurb {
    final hidePlayback = FeatureFlagsService().hidePlayback.value;
    if (_popcornOnly) {
      return hidePlayback
          ? 'Discover the latest movies and TV shows, and find what to watch next.'
          : 'Stream the latest movies and TV shows, all for free.';
    }
    return hidePlayback
        ? 'Discover the latest movies, trending music,\nand your next great read.'
        : 'Stream the latest movies, discover trending music,\nand dive into your next great read — all for free.';
  }

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
            _headline,
            // Beside the logo, flush left like the lines below it.
            textAlign: sideBySide ? TextAlign.start : TextAlign.center,
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
