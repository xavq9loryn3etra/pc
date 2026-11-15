import 'package:flutter/material.dart';
import 'glass_blur.dart';

import '../theme/iridescent.dart';
import 'frosted_logo_layout.dart';

/// Full-screen, app-wide status page (update required, maintenance,
/// offline). Deliberately not tied to any one mode: it has the welcome
/// screen's look — the frosted poster wall with the app's icon cut out,
/// the words beside it on a wide window (FrostedLogoLayout) — and the
/// app's iridescent finish (which blends all three mode accents) in its
/// headline, so it fits whichever mode it appears over.
class StatusScreen extends StatefulWidget {
  /// Bundled (see pubspec `fonts:`), not fetched via google_fonts — the
  /// offline screen has to render it without a connection.
  static const String scriptFont = 'Yellowtail';

  /// First headline line, in white.
  final String title;

  /// Second headline line, in script and the app's iridescent finish.
  final String highlight;

  final String message;

  /// Draws the message instead, in the style given (a link in it, say).
  final Widget Function(TextStyle style)? messageBuilder;

  /// The button under the message, where the welcome screen's Get Started
  /// is. Without one, its place is kept (empty), so every one of these
  /// screens has the welcome screen's layout exactly.
  final Widget? footer;

  const StatusScreen({
    super.key,
    required this.title,
    required this.highlight,
    required this.message,
    this.messageBuilder,
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
    return FrostedLogoLayout(
      opacity: _fade,
      details: (context, sideBySide, large) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            sideBySide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Text(
            widget.title,
            textAlign: sideBySide ? TextAlign.start : TextAlign.center,
            style: TextStyle(
              fontSize: large ? 44 : 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: large ? -1 : -0.5,
            ),
          ),
          // Pulled back beside the logo so it starts flush with the title
          // (its padding keeps the swashes inside the colour).
          Transform.translate(
            offset: Offset(sideBySide ? -16 : 0, 0),
            child: IridescentScriptText(
              widget.highlight,
              fontSize: large ? 64 : 44,
            ),
          ),
          SizedBox(height: large ? 20 : 12),
          Builder(builder: (context) {
            final style = TextStyle(
              fontSize: large ? 18 : 14,
              color: Colors.white.withValues(alpha: 0.7),
              height: 1.5,
            );
            return widget.messageBuilder?.call(style) ??
                Text(
                  widget.message,
                  textAlign: sideBySide ? TextAlign.start : TextAlign.center,
                  style: style,
                );
          }),
          // As the welcome screen: the button's gap and place, kept even
          // without one.
          SizedBox(height: large ? 40 : 32),
          widget.footer ??
              const SizedBox(height: StatusPrimaryButton.height),
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
  final double fontSize;

  const IridescentScriptText(this.text, {super.key, this.fontSize = 44});

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
          style: TextStyle(
            fontFamily: StatusScreen.scriptFont,
            fontSize: fontSize,
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

  /// Null while it can't be pressed (e.g. "Downloading… 45%").
  final VoidCallback? onPressed;

  /// How far along a download is (0–1): the button fills with it, left to
  /// right, instead of a separate progress bar. Null: a plain button.
  final double? progress;

  const StatusPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.progress,
  });

  /// Also the room kept for it on a screen without one.
  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    // Full width on a phone; on a wide window a stretched bar looks broken,
    // so it stops at a normal button's width (centred by its column).
    final progress = this.progress;
    if (progress != null) return _filling(progress);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white.withValues(alpha: 0.75),
            disabledForegroundColor: Colors.black.withValues(alpha: 0.7),
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
      ),
    );
  }

  /// The button filling as [progress] goes: dim white, the done part
  /// solid white over it, gliding as it grows; the label on top.
  Widget _filling(double progress) {
    const radius = BorderRadius.all(Radius.circular(16));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Colors.white.withValues(alpha: 0.35)),
              TweenAnimationBuilder<double>(
                tween: Tween(end: progress.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                builder: (context, done, _) => FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: done,
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
              Center(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
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
            color: kGlassTint,
            border: Border.all(color: kGlassEdge),
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
