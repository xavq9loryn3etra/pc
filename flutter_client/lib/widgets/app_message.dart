import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass_blur.dart';

/// Shows the app's one kind of pop-up message: a frosted pill floating near
/// the bottom of the screen, replacing any message already up. Every screen
/// uses this instead of its own SnackBar, so they all look alike.
///
/// [error] marks something that went wrong with a red icon. Either way
/// [text] says what happened in plain words — never an exception's text.
/// [aboveNavBar] lifts it clear of the home screens' floating bottom nav
/// bar, which is drawn over the Scaffold rather than in it.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showAppMessage(
  BuildContext context,
  String text, {
  bool error = false,
  bool aboveNavBar = false,
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  final screenWidth = MediaQuery.sizeOf(context).width;
  // At most _maxWidth wide, centred: full width looked stretched on a
  // landscape player, and the transparent rest of a full-width bar still
  // took the taps meant for the controls under it.
  final side = math.max(16.0, (screenWidth - _maxWidth) / 2);
  final bottom =
      aboveNavBar ? 110 + MediaQuery.paddingOf(context).bottom : 16.0;
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    margin: EdgeInsets.fromLTRB(side, 0, side, bottom),
    duration: duration,
    content: _MessagePill(text: text, error: error),
  ));
}

const double _maxWidth = 480;

class _MessagePill extends StatelessWidget {
  final String text;
  final bool error;

  const _MessagePill({required this.text, required this.error});

  static const _radius = BorderRadius.all(Radius.circular(24));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _radius,
      child: GlassBlur(
        reducedTint: Colors.black.withValues(alpha: 0.6),
        child: DecoratedBox(
          // Darker than the buttons' glass: it shows over anything, and its
          // text has to stay readable over a bright picture too.
          decoration: BoxDecoration(
            color: const Color(0xC71C1C1E), // #1C1C1E, 78%
            borderRadius: _radius,
            border: Border.all(color: kGlassEdge),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                if (error) ...[
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFFF453A),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
