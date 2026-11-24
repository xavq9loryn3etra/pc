import 'package:flutter/material.dart';

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

  /// Draws the message instead, in the style and alignment given (a link
  /// in it, say).
  final Widget Function(TextStyle style, TextAlign align)? messageBuilder;

  /// Other messages that can take this one's place as the screen goes on
  /// (the update's steps): room is kept for the longest, so nothing on the
  /// screen moves when they change. Beside the logo on a wide window the
  /// words are centred top to bottom, and a message a line longer or
  /// shorter moved the title and the button with it.
  final List<String> roomFor;

  /// The button under the message, where the welcome screen's Get Started
  /// is. Without one, its place is kept (empty), so every one of these
  /// screens has the welcome screen's layout exactly.
  final Widget? footer;

  /// Instead of a button, a line saying what the screen is waiting for
  /// ("Waiting for connection…"), fading gently in and out.
  final String? waitingFor;

  /// Under the message: what's new in the update (ReleaseNotesBox). It
  /// gets the room left between the logo and the rest, and scrolls inside
  /// that if it's longer; the screen itself never scrolls.
  final Widget? notes;

  const StatusScreen({
    super.key,
    required this.title,
    required this.highlight,
    required this.message,
    this.messageBuilder,
    this.roomFor = const [],
    this.footer,
    this.waitingFor,
    this.notes,
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
    // With notes, the gaps are tighter, so the notes get the room (owner,
    // 24 Nov 2026: the gaps were too big, the notes too short).
    final withNotes = widget.notes != null;
    return FrostedLogoLayout(
      opacity: _fade,
      fitWords: widget.notes != null,
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
              fontSize: withNotes ? (large ? 56 : 40) : (large ? 64 : 44),
              tight: withNotes,
            ),
          ),
          SizedBox(height: withNotes ? (large ? 4 : 2) : (large ? 20 : 12)),
          Builder(builder: (context) {
            final style = TextStyle(
              fontSize: large ? 18 : 14,
              color: Colors.white.withValues(alpha: 0.7),
              height: 1.5,
            );
            final align = sideBySide ? TextAlign.start : TextAlign.center;
            final message = widget.messageBuilder?.call(style, align) ??
                Text(widget.message, textAlign: align, style: style);
            // With notes, no room is kept: the notes give way to a longer
            // message instead (the room kept left a big gap above them).
            if (widget.roomFor.isEmpty || withNotes) return message;
            // The longest of them sets the height, unseen; the message is
            // drawn over it, from the top.
            return Stack(
              alignment: sideBySide
                  ? AlignmentDirectional.topStart
                  : AlignmentDirectional.topCenter,
              children: [
                for (final other in widget.roomFor)
                  Visibility(
                    visible: false,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(other, textAlign: align, style: style),
                    ),
                  ),
                SizedBox(width: double.infinity, child: message),
              ],
            );
          }),
          if (withNotes) ...[
            SizedBox(height: large ? 16 : 12),
            Flexible(child: widget.notes!),
          ],
          // As the welcome screen: the button's gap and place, kept even
          // without one.
          SizedBox(height: withNotes ? (large ? 20 : 16) : (large ? 40 : 32)),
          if (widget.waitingFor != null)
            SizedBox(
              height: StatusPrimaryButton.height,
              child: Align(
                alignment: sideBySide
                    ? AlignmentDirectional.centerStart
                    : Alignment.center,
                child: _FadingText(
                  widget.waitingFor!,
                  style: TextStyle(
                    fontSize: large ? 17 : 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
            )
          else
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

  /// Less room above and below (just enough for the swashes): where the
  /// screen's room is wanted for something else (the update's notes).
  final bool tight;

  const IridescentScriptText(this.text,
      {super.key, this.fontSize = 44, this.tight = false});

  @override
  Widget build(BuildContext context) {
    return Iridescent(
      // Script glyphs' swashes overhang their text box; the padding keeps
      // them inside the mask so no tips render un-tinted.
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: tight ? 2 : 10),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: StatusScreen.scriptFont,
            fontSize: fontSize,
            height: tight ? 1.15 : 1.25,
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

/// Words that fade gently in and out, as something waited for: the offline
/// screen's "Waiting for connection…".
class _FadingText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _FadingText(this.text, {required this.style});

  @override
  State<_FadingText> createState() => _FadingTextState();
}

class _FadingTextState extends State<_FadingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween(begin: 1.0, end: 0.35)
      .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Text(widget.text, style: widget.style),
    );
  }
}
