
import 'package:flutter/material.dart';
import 'glass_blur.dart';

import '../theme/iridescent.dart';
import 'poster_wall.dart';

/// Full-screen, app-wide status page (update required, maintenance,
/// offline). Deliberately not tied to any one mode: it sits on the welcome
/// screen's poster wall and uses the app's iridescent finish (which blends
/// all three mode accents) in its headline, so it fits whichever mode it
/// appears over.
class StatusScreen extends StatefulWidget {
  /// Bundled (see pubspec `fonts:`), not fetched via google_fonts — the
  /// offline screen has to render it without a connection.
  static const String scriptFont = 'Yellowtail';

  /// First headline line, in white.
  final String title;

  /// Second headline line, in script and the app's iridescent finish.
  final String highlight;

  final String message;

  /// Optional action or status shown under the message.
  final Widget? footer;

  const StatusScreen({
    super.key,
    required this.title,
    required this.highlight,
    required this.message,
    this.footer,
  });

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();
  late final Animation<double> _fade =
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);

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

          // Darker than the welcome screen's fade, so the wall reads as a
          // backdrop and the message stays the focus.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.88),
                    Colors.black.withValues(alpha: 0.6),
                    Colors.black.withValues(alpha: 0.88),
                    Colors.black.withValues(alpha: 0.98),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.28, 0.48, 0.66, 0.82],
                ),
              ),
            ),
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fade,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
                child: Column(
                  children: [
                    const Spacer(),
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    IridescentScriptText(widget.highlight),
                    const SizedBox(height: 16),
                    Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.6),
                        height: 1.5,
                      ),
                    ),
                    if (widget.footer != null) ...[
                      const SizedBox(height: 32),
                      widget.footer!,
                    ],
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

/// Script headline in the app's iridescent finish (which already holds all
/// three mode accents — see AppIridescence). The second headline line on
/// the app-wide screens: these status pages and the welcome screen.
class IridescentScriptText extends StatelessWidget {
  final String text;

  const IridescentScriptText(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Iridescent(
      // Script glyphs' swashes overhang their text box; the padding keeps
      // them inside the mask so no tips render un-tinted.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: StatusScreen.scriptFont,
            fontSize: 44,
            height: 1.25,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Full-width primary action on the app-wide screens (these status pages
/// and the welcome screen's "Get Started"): plain white, since those
/// screens aren't tied to any one mode's accent.
class StatusPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const StatusPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

/// Frosted pill with a softly pulsing dot, for passive states such as
/// "Waiting for connection".
class StatusPill extends StatefulWidget {
  final String label;

  const StatusPill({super.key, required this.label});

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: GlassBlur(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: Colors.black.withValues(alpha: 0.35),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeTransition(
                opacity: Tween(begin: 1.0, end: 0.25).animate(_pulse),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
