import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Smooth mouse-wheel scrolling for the Windows app.
///
/// Out of the box, Flutter on Windows moves a list the whole distance of a
/// wheel notch in a single frame, so scrolling looks steppy. This binding
/// catches each wheel notch before any list sees it and plays it out as many
/// small steps, one per frame, easing to a stop — the way a browser scrolls.
///
/// Because it works on the wheel events themselves, every list, grid,
/// carousel and sheet in the app gets it, with no change to the screens.
/// Precision touchpads aren't affected: they already send their own smooth
/// pan events rather than wheel notches.
class SmoothWheelBinding extends WidgetsFlutterBinding {
  SmoothWheelBinding._();

  /// Use in place of [WidgetsFlutterBinding.ensureInitialized], as the first
  /// line of `main`. Off Windows it is the stock binding.
  static WidgetsBinding ensureInitialized() {
    if (!_created && !kIsWeb && Platform.isWindows) {
      _created = true;
      SmoothWheelBinding._();
    }
    return WidgetsFlutterBinding.ensureInitialized();
  }

  static bool _created = false;

  /// The list moves as if on a critically damped spring pulled toward
  /// where the wheel says it should be (as Firefox scrolls): it eases in
  /// rather than jumping, glides, and settles without overshooting. At
  /// this stiffness a notch is ~70% travelled in 100 ms and settled by
  /// ~250 ms; spinning the wheel keeps the speed up between notches.
  static const double _stiffness = 22; // The spring's ω, per second.

  /// Close enough, and slow enough, to finish in one step.
  static const double _snapPixels = 0.5;
  static const double _snapSpeed = 20; // Pixels a second.

  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  /// Distance still to scroll and the speed it's being scrolled at, and the
  /// wheel event it came from (its pointer position decides which list
  /// scrolls).
  Offset _remaining = Offset.zero;
  Offset _velocity = Offset.zero;
  PointerScrollEvent? _source;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerScrollEvent &&
        event.kind == PointerDeviceKind.mouse &&
        event.scrollDelta != Offset.zero) {
      _addNotch(event);
      return;
    }
    super.handlePointerEvent(event);
  }

  void _addNotch(PointerScrollEvent event) {
    // Turning the wheel the other way drops what was left, so the list
    // reverses at once instead of first finishing the old notch.
    final reversed = _remaining.dx * event.scrollDelta.dx < 0 ||
        _remaining.dy * event.scrollDelta.dy < 0;
    if (reversed) {
      _remaining = event.scrollDelta;
      _velocity = Offset.zero;
    } else {
      _remaining += event.scrollDelta;
    }
    _source = event;

    final ticker = _ticker ??= Ticker(_tick, debugLabel: 'SmoothWheel');
    if (!ticker.isActive) {
      _lastTick = Duration.zero;
      ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final source = _source;
    if (source == null) {
      _stop();
      return;
    }

    final dt =
        (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    if (dt <= 0) return; // The first tick: no time has passed yet.

    // The spring, stepped in short slices so it stays steady at any frame
    // rate (and through a dropped frame).
    var step = Offset.zero;
    var left = math.min(dt, 0.1); // A long stall doesn't fling the list.
    while (left > 0) {
      final h = math.min(left, 0.004);
      left -= h;
      final pull =
          _remaining * (_stiffness * _stiffness) - _velocity * (2 * _stiffness);
      _velocity += pull * h;
      final move = _velocity * h;
      _remaining -= move;
      step += move;
    }
    if (_remaining.distance < _snapPixels && _velocity.distance < _snapSpeed) {
      step += _remaining;
      _remaining = Offset.zero;
    }

    super.handlePointerEvent(PointerScrollEvent(
      viewId: source.viewId,
      timeStamp: source.timeStamp + elapsed,
      kind: source.kind,
      device: source.device,
      position: source.position,
      embedderId: source.embedderId,
      scrollDelta: step,
    ));

    if (_remaining == Offset.zero) _stop();
  }

  void _stop() {
    _ticker?.stop();
    _remaining = Offset.zero;
    _velocity = Offset.zero;
    _source = null;
  }
}
