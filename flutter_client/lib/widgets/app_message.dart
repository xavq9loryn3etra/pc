import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'glass_blur.dart';

/// Shows the app's one kind of pop-up message: a frosted pill floating near
/// the bottom of the screen, replacing any message already up. Every screen
/// uses this instead of its own SnackBar, so they all look alike.
///
/// [error] marks something that went wrong with a red icon. Either way
/// [text] says what happened in plain words — never an exception's text.
/// [aboveNavBar] lifts it clear of the home screens' floating bottom nav
/// bar, which is drawn over the Scaffold rather than in it.
///
/// [actionLabel] with [onAction] adds a button at its end ("Undo"): tapping
/// it closes the message, then calls [onAction].
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showAppMessage(
  BuildContext context,
  String text, {
  bool error = false,
  bool aboveNavBar = false,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  final screenWidth = MediaQuery.sizeOf(context).width;
  // At most _maxWidth wide, centred: full width looked stretched on a
  // landscape player, and the transparent rest of a full-width bar still
  // took the taps meant for the controls under it.
  final side = math.max(16.0, (screenWidth - _maxWidth) / 2);
  // Above the nav bar: its buttons' top (16 from the foot, 52 high: see
  // FloatingBottomNavBar) and 12 more, the gap between them. The phone's
  // own bottom bar isn't added: the Scaffold already keeps a floating
  // message above it — added again, the message sat some 60 above the
  // buttons on a Galaxy S25 (owner, 24 Nov 2026: "too high").
  final bottom = aboveNavBar ? 16.0 + 52 + 12 : 16.0;
  messenger.hideCurrentSnackBar();
  final hasAction = actionLabel != null && onAction != null;
  return messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    margin: EdgeInsets.fromLTRB(side, 0, side, bottom),
    duration: duration,
    // Its own button (below) rather than SnackBar.action: kept in the
    // pill's look.
    content: _MessagePill(
      text: text,
      error: error,
      actionLabel: hasAction ? actionLabel : null,
      onAction: hasAction
          ? () {
              messenger.hideCurrentSnackBar(
                  reason: SnackBarClosedReason.action);
              onAction();
            }
          : null,
    ),
  ));
}

const double _maxWidth = 480;

class _MessagePill extends StatelessWidget {
  final String text;
  final bool error;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessagePill({
    required this.text,
    required this.error,
    this.actionLabel,
    this.onAction,
  });

  static const _radius = BorderRadius.all(Radius.circular(24));

  @override
  Widget build(BuildContext context) {
    final action = actionLabel;
    return ClipRRect(
      borderRadius: _radius,
      child: GlassBlur(
        reducedTint: Colors.black,
        child: DecoratedBox(
          // Darker than the buttons' glass: it shows over anything, and its
          // text has to stay readable over a bright picture too.
          decoration: BoxDecoration(
            color: const Color(0xC71C1C1E), // #1C1C1E, 78%
            borderRadius: _radius,
            border: Border.all(color: kGlassEdge),
          ),
          child: Padding(
            // With a button, less round it: the button's own padding (a
            // finger-sized target) makes up the rest.
            padding: action == null
                ? const EdgeInsets.symmetric(horizontal: 18, vertical: 14)
                : const EdgeInsets.fromLTRB(18, 2, 6, 2),
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
                    maxLines: action == null ? null : 2,
                    overflow: action == null ? null : TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ),
                if (action != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.accent,
                      minimumSize: const Size(64, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: Text(action),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
