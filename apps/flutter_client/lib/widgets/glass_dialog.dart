import 'package:flutter/material.dart';

import 'glass_blur.dart';

/// Shows [builder]'s content in a frosted panel centred over a dimmed
/// screen — the app's glass, as on the season picker's menu — fading and
/// growing in. Replaces Material's grey AlertDialog.
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
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
    pageBuilder: (dialogContext, _, __) => SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: GlassPanel(child: builder(dialogContext)),
          ),
        ),
      ),
    ),
  );
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
                child: _DialogButton(
                  label: cancelLabel,
                  onTap: () => Navigator.pop(dialogContext, false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DialogButton(
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
class _DialogButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool destructive;

  const _DialogButton({
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
    return SizedBox(
      height: 44,
      child: Material(
        color: primary ? Colors.white : kGlassTint,
        shape: primary
            ? _shape
            : _shape.copyWith(side: BorderSide(color: kGlassEdge)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Center(child: text)),
      ),
    );
  }
}
