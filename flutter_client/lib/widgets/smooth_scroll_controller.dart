import 'package:flutter/widgets.dart';

/// A [ScrollController] whose mouse-wheel scrolling glides, as Lenis does on
/// the web: each notch moves a target further, and the view eases towards
/// it instead of jumping a notch at a time. Touch, trackpad and scrollbar
/// dragging are unchanged (they don't come through [ScrollPosition.pointerScroll]).
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// How long the view takes to settle after the last notch.
  static const _glide = Duration(milliseconds: 450);

  // Where the wheel has asked to go, while the view is still on its way.
  double? _target;

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0) return;
    // Notches in quick succession add up from where the last one was
    // heading, not from where the view has got to.
    final from = _target ?? pixels;
    final target = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == from) return;
    _target = target;
    animateTo(target, duration: _glide, curve: Curves.easeOutQuart)
        .whenComplete(() {
      if (_target == target) _target = null;
    });
  }

  @override
  void jumpTo(double value) {
    _target = null;
    super.jumpTo(value);
  }
}
