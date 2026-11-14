import 'package:flutter/material.dart';

import 'floating_bottom_nav_bar.dart' show SideColumnScope, windowIsWide;
import 'glass_blur.dart';

/// Shows [builder]'s content in a frosted panel centred over a dimmed
/// screen — the app's glass, as on the season picker's menu — fading and
/// growing in. Replaces Material's grey AlertDialog.
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  // Wider for one with more to say (the Gemini key's steps over the
  // player, landscape): short ones read best narrow.
  double maxWidth = 360,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (_, animation, __, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
    // Above the keyboard when it's up (a field in it: the Gemini key's),
    // and scrolled within the screen's height by a builder that scrolls.
    pageBuilder: (dialogContext, _, __) => AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(dialogContext).bottom),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: GlassPanel(child: builder(dialogContext)),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Shows one of the app's sheets ([builder], built on EpisodeSheetFrame:
/// the quality picker, an episode's or a person's) — rising from the
/// bottom on a phone; on a wide window, a popup centred over the dimmed
/// page, fading and growing in as [showGlassDialog]'s, which a click
/// outside or Esc closes. [GlassSheetScope] tells the frame which.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final inColumn = SideColumnScope.inColumn(context);
  if (inColumn || !windowIsWide(context)) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: !inColumn,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black54,
      builder: builder,
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (_, animation, __, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (sheetContext, _, __) => SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 600,
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
            ),
            child: GlassSheetScope(
              popup: true,
              child: Material(
                type: MaterialType.transparency,
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Whether the sheets under it are shown as centred popups (see
/// [showGlassSheet]) rather than rising from the bottom.
class GlassSheetScope extends InheritedWidget {
  final bool popup;

  const GlassSheetScope({super.key, required this.popup, required super.child});

  static bool popupOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassSheetScope>()?.popup ??
      false;

  @override
  bool updateShouldNotify(GlassSheetScope old) => old.popup != popup;
}

/// Asks [title] / [message] with Cancel and [confirmLabel] buttons; true
/// when confirmed. [destructive] marks the confirm button red (Remove,
/// Delete, ...).
Future<bool> showGlassConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final confirmed = await showGlassDialog<bool>(
    context,
    builder: (dialogContext) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: GlassDialogButton(
                  label: cancelLabel,
                  onTap: () => Navigator.pop(dialogContext, false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassDialogButton(
                  label: confirmLabel,
                  primary: true,
                  destructive: destructive,
                  onTap: () => Navigator.pop(dialogContext, true),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  return confirmed ?? false;
}

/// The frosted, rounded panel behind the app's dialogs and menus.
class GlassPanel extends StatelessWidget {
  final Widget child;

  const GlassPanel({super.key, required this.child});

  static const _radius = BorderRadius.all(Radius.circular(20));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _radius,
      child: GlassBlur(
        sigma: 16,
        reducedTint: const Color(0xF2161616),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kGlassSheetTint,
            borderRadius: _radius,
            border: Border.all(color: kGlassEdge),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// A dialog's pill button: frosted for the secondary choice, solid white
/// for the main one (red text when [destructive]).
/// A button in a glass dialog: plain, or [primary] (filled), or
/// [destructive] (red).
class GlassDialogButton extends StatelessWidget {
  final String label;
  /// Null: shown faded, and can't be tapped.
  final VoidCallback? onTap;
  final bool primary;
  final bool destructive;

  const GlassDialogButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.destructive = false,
  });

  static const _shape = StadiumBorder();

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        color: !primary
            ? Colors.white
            : destructive
                ? const Color(0xFFD32F2F)
                : Colors.black,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    );
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: SizedBox(
        height: 44,
        child: Material(
          color: primary ? Colors.white : kGlassTint,
          shape: primary
              ? _shape
              : _shape.copyWith(side: BorderSide(color: kGlassEdge)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: onTap,
              child: Center(child: text)),
        ),
      ),
    );
  }
}
