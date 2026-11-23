import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'floating_bottom_nav_bar.dart' show windowIsWide;
import 'glass_blur.dart';

/// One row of a card's menu (see [showCardMenu]).
class CardMenuAction {
  final String label;
  final IconData icon;

  /// Red: it takes something away (Remove).
  final bool destructive;

  /// Called once the menu has started closing.
  final VoidCallback onSelected;

  const CardMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });
}

/// The global rect of [context]'s box — a card's, for [showCardMenu]'s
/// anchor. Null if it isn't laid out.
Rect? globalRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// A card's menu, after the Apple TV app's: the card ([preview], drawn
/// over [anchor] — the card's rect on screen, in global coordinates) lifts
/// a little where it is while the rest of the screen dims (and blurs,
/// where the glass is frosted), and a small glass menu of [actions] opens
/// right under it — above it when there's no room below, beside it when
/// there's room for neither — always kept on screen.
///
/// A tap outside, Back or Esc closes it. Choosing a row closes it, then
/// calls the row's [CardMenuAction.onSelected].
Future<void> showCardMenu(
  BuildContext context, {
  required Rect anchor,
  required Widget preview,
  required List<CardMenuAction> actions,
  double previewRadius = 8,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // The anchor in the menu's own coordinates (the root navigator's, the
  // whole window here — but not assumed).
  final overlayBox = navigator.overlay?.context.findRenderObject();
  final local = overlayBox is RenderBox && overlayBox.hasSize
      ? Rect.fromPoints(overlayBox.globalToLocal(anchor.topLeft),
          overlayBox.globalToLocal(anchor.bottomRight))
      : anchor;
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final chosen = await showGeneralDialog<CardMenuAction>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'Close',
    // The dim (and blur) is drawn by the menu itself (see _CardMenuLayer):
    // the route's barrier, under it, only takes the taps outside.
    barrierColor: Colors.transparent,
    transitionDuration: Duration(milliseconds: reduceMotion ? 120 : 180),
    transitionBuilder: (_, __, ___, child) => child,
    pageBuilder: (menuContext, animation, _) => _CardMenuLayer(
      animation: animation,
      anchor: local,
      preview: preview,
      previewRadius: previewRadius,
      actions: actions,
      reduceMotion: reduceMotion,
    ),
  );
  chosen?.onSelected();
}

class _CardMenuLayer extends StatelessWidget {
  final Animation<double> animation;
  final Rect anchor;
  final Widget preview;
  final double previewRadius;
  final List<CardMenuAction> actions;
  final bool reduceMotion;

  const _CardMenuLayer({
    required this.animation,
    required this.anchor,
    required this.preview,
    required this.previewRadius,
    required this.actions,
    required this.reduceMotion,
  });

  /// How much the card grows as it lifts.
  static const double _lift = 1.05;

  /// Between the lifted card and the menu.
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final plain = PlainGlassScope.of(context);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final lifted = Rect.fromCenter(
      center: anchor.center,
      width: anchor.width * _lift,
      height: anchor.height * _lift,
    );
    final padding = MediaQuery.paddingOf(context);
    final wide = windowIsWide(context);
    final width = MediaQuery.sizeOf(context).width;
    final menuWidth = math.min(wide ? 260.0 : 240.0, width - 32);
    final margin = EdgeInsets.fromLTRB(
      16 + padding.left,
      16 + padding.top,
      16 + padding.right,
      16 + padding.bottom,
    );
    // Which side of the card the menu lands on, for it to grow from that
    // side: from its rows' usual height (the real placement, below, uses
    // its measured size — the same side but where text is much enlarged).
    final estimate = placeMenu(
      screen: MediaQuery.sizeOf(context),
      card: lifted,
      menu: Size(menuWidth, actions.length * 48.0),
      gap: _gap,
      margin: margin,
    );
    final origin = estimate.dy >= lifted.bottom
        ? Alignment.topCenter
        : estimate.dy + actions.length * 48.0 <= lifted.top
            ? Alignment.bottomCenter
            : estimate.dx >= lifted.right
                ? Alignment.centerLeft
                : estimate.dx + menuWidth <= lifted.left
                    ? Alignment.centerRight
                    : Alignment.center;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The screen behind, dimmed — and blurred where glass is frosted
        // (plain glass: just dimmed, as its glass isn't see-through). Taps
        // go through to the route's barrier, which closes the menu.
        IgnorePointer(
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, _) {
              final t = curved.value;
              final dim = ColoredBox(
                color: Colors.black.withValues(alpha: (plain ? 0.7 : 0.45) * t),
              );
              if (plain) return dim;
              return BackdropFilter(
                enabled: t > 0,
                filter: ImageFilter.blur(
                  sigmaX: math.max(12 * t, 0.1),
                  sigmaY: math.max(12 * t, 0.1),
                  tileMode: TileMode.clamp,
                ),
                child: dim,
              );
            },
          ),
        ),
        // The card, lifted where it is: a touch larger, a soft shadow
        // under it. Tapping it closes the menu, as outside does.
        Positioned.fromRect(
          rect: anchor,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: curved,
              builder: (context, child) {
                final t = curved.value;
                // Reduced motion: already lifted (and fading in, below).
                final scale = reduceMotion ? _lift : 1 + (_lift - 1) * t;
                final lifted = Transform.scale(
                  scale: scale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(previewRadius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55 * t),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: child,
                  ),
                );
                // Reduced motion: it fades in over the card instead.
                return reduceMotion
                    ? Opacity(opacity: t, child: lifted)
                    : lifted;
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(previewRadius),
                child: preview,
              ),
            ),
          ),
        ),
        CustomSingleChildLayout(
          delegate: _MenuPlacement(
            card: lifted,
            gap: _gap,
            margin: margin,
            width: menuWidth,
          ),
          child: _AnimatedMenu(
            animation: curved,
            origin: origin,
            reduceMotion: reduceMotion,
            child: _MenuPanel(actions: actions),
          ),
        ),
      ],
    );
  }
}

/// Grows the menu out of the card's side of it ([origin]), fading in.
class _AnimatedMenu extends StatelessWidget {
  final Animation<double> animation;
  final Alignment origin;
  final bool reduceMotion;
  final Widget child;

  const _AnimatedMenu({
    required this.animation,
    required this.origin,
    required this.reduceMotion,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: animation, child: child);
    if (reduceMotion) return faded;
    return ScaleTransition(
      alignment: origin,
      scale: Tween(begin: 0.9, end: 1.0).animate(animation),
      child: faded,
    );
  }
}

/// Puts the menu under the card, else above it, else beside it, else as
/// near as fits — inside [margin] of the screen's edges, its left edge in
/// line with the card's.
class _MenuPlacement extends SingleChildLayoutDelegate {
  final Rect card;
  final double gap;
  final EdgeInsets margin;
  final double width;

  _MenuPlacement({
    required this.card,
    required this.gap,
    required this.margin,
    required this.width,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight:
          math.max(0, constraints.maxHeight - margin.top - margin.bottom),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => placeMenu(
      screen: size, card: card, menu: childSize, gap: gap, margin: margin);

  @override
  bool shouldRelayout(_MenuPlacement old) =>
      old.card != card ||
      old.gap != gap ||
      old.margin != margin ||
      old.width != width;
}

/// Where a menu of size [menu] goes for a card at [card] on a [screen]:
/// under it if it fits, else above, else beside it (right, else left),
/// else as low as fits — always within [margin] of the edges.
@visibleForTesting
Offset placeMenu({
  required Size screen,
  required Rect card,
  required Size menu,
  double gap = 10,
  EdgeInsets margin = const EdgeInsets.all(16),
}) {
  final minX = margin.left;
  final maxX = math.max(minX, screen.width - margin.right - menu.width);
  final minY = margin.top;
  final maxY = math.max(minY, screen.height - margin.bottom - menu.height);
  double clampX(double x) => x.clamp(minX, maxX);
  double clampY(double y) => y.clamp(minY, maxY);

  final below = card.bottom + gap;
  if (below + menu.height <= screen.height - margin.bottom) {
    return Offset(clampX(card.left), below);
  }
  final above = card.top - gap - menu.height;
  if (above >= margin.top) {
    return Offset(clampX(card.left), above);
  }
  final right = card.right + gap;
  if (right + menu.width <= screen.width - margin.right) {
    return Offset(right, clampY(card.top));
  }
  final left = card.left - gap - menu.width;
  if (left >= margin.left) {
    return Offset(left, clampY(card.top));
  }
  return Offset(clampX(card.left), clampY(below));
}

/// The menu's glass panel and its rows.
class _MenuPanel extends StatelessWidget {
  final List<CardMenuAction> actions;

  const _MenuPanel({required this.actions});

  static const _radius = BorderRadius.all(Radius.circular(16));

  @override
  Widget build(BuildContext context) {
    // No blur of its own: the screen behind it is already blurred (see
    // _CardMenuLayer) — the thick glass's tint over that is the frost.
    return ClipRRect(
      borderRadius: _radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: glassSheetTint(context),
          borderRadius: _radius,
          border: Border.all(color: kGlassEdge),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  _MenuRow(action: actions[i]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final CardMenuAction action;

  const _MenuRow({required this.action});

  static const _red = Color(0xFFFF453A);

  @override
  Widget build(BuildContext context) {
    final color = action.destructive ? _red : Colors.white;
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: () => Navigator.of(context).pop(action),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Text(
                action.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Icon(action.icon, color: color, size: 20),
          ],
        ),
      ),
    );
  }
}
