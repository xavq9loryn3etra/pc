import 'dart:async';
import 'package:flutter/material.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';

// Netflix/YouTube-style gestures

/// Netflix/YouTube-style vertical swipe overlay for volume (right) and brightness (left),
/// along with premium YouTube-style double-tap to seek (10s) with glowing animated overlays.
///
/// Wraps its [child] in a raw [Listener] so pointer events are captured as a
/// PARENT of the WebView — not as a sibling overlay. This guarantees we receive
/// pointer events even when a PlatformView (WebView) handles touches natively.
class PlayerGestureOverlay extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Like [onTap], but with where the tap landed, for callers that act
  /// differently depending on the area tapped. Called instead of [onTap]
  /// when set.
  ///
  /// Positions here are all in the overlay's own coordinates, which match
  /// its MediaQuery size as it fills the screen.
  final ValueChanged<Offset>? onTapAt;
  final VoidCallback? onSwipeUp;
  final ValueChanged<bool>? onDoubleTapSeek;

  /// A finger held still on the screen for [holdDelay] (e.g. to play at 2×
  /// speed), and its release. A hold is neither a tap nor a volume /
  /// brightness swipe.
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;
  static const holdDelay = Duration(milliseconds: 450);

  /// When false, all gesture processing is disabled (e.g. when the episode
  /// drawer is open and should receive all touches).
  final bool enabled;

  const PlayerGestureOverlay({
    super.key,
    required this.child,
    this.onTap,
    this.onTapAt,
    this.onSwipeUp,
    this.onDoubleTapSeek,
    this.onHoldStart,
    this.onHoldEnd,
    this.enabled = true,
  });

  @override
  State<PlayerGestureOverlay> createState() => _PlayerGestureOverlayState();
}

enum _GestureType { none, volume, brightness }

class _PlayerGestureOverlayState extends State<PlayerGestureOverlay>
    with TickerProviderStateMixin {
  _GestureType _activeGesture = _GestureType.none;
  double _currentValue = 0.0;
  double _startValue = 0.0;
  // Drag updates fire up to ~100x per full swipe — routed through this
  // notifier instead of setState so only the small indicator widget
  // rebuilds, not the whole gesture Stack (video content, overlays, etc).
  final ValueNotifier<double> _currentValueNotifier = ValueNotifier(0.0);

  Offset? _pointerStart;
  bool _isDragging = false;
  bool _isBottomEdgeSwipe = false;
  static const double _dragThreshold = 18.0;

  late final AnimationController _fadeController;
  Timer? _fadeTimer;

  // Press-and-hold (see PlayerGestureOverlay.onHoldStart): armed on pointer
  // down, cancelled by a drag or an early release; _holding once it fired.
  Timer? _holdTimer;
  bool _holding = false;

  // Double tap seeking state variables
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  // Seek streak: after a double tap, every further tap on the same side
  // within [_seekStreakWindow] seeks another 10s (YouTube-style), instead
  // of needing a fresh double tap each time.
  static const _seekStreakWindow = Duration(milliseconds: 700);
  static const _seekStepSeconds = 10;
  bool? _seekForward; // side of the active feedback; null when hidden
  int _seekTaps = 0;
  DateTime? _lastSeekTapTime;
  Offset _rippleOrigin = Offset.zero; // in the feedback region's coordinates
  Timer? _seekHideTimer;
  late final AnimationController _seekFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    reverseDuration: const Duration(milliseconds: 300),
  );
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  @override
  void initState() {
    super.initState();
    VolumeController.instance.showSystemUI = false;
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _fadeTimer?.cancel();
    _seekHideTimer?.cancel();
    _seekFade.dispose();
    _ripple.dispose();
    _fadeController.dispose();
    _currentValueNotifier.dispose();
    VolumeController.instance.showSystemUI = true;
    // Reset brightness back to system default when leaving the player
    ScreenBrightness.instance
        .resetApplicationScreenBrightness()
        .catchError((_) {});
    super.dispose();
  }

  /// Region of the screen the seek feedback covers on each side.
  double _seekRegionWidth(Size size) => size.width * 0.4;

  /// One seek step: tells the player, then shows/extends the feedback with
  /// a fresh ripple from the tap point. Without an [onDoubleTapSeek]
  /// (e.g. while the video loads) there's no seeking, so no feedback either.
  void _seek(bool isForward, Offset localTap) {
    final onSeek = widget.onDoubleTapSeek;
    if (onSeek == null) return;
    onSeek(isForward);

    final size = MediaQuery.of(context).size;
    final regionLeft = isForward ? size.width - _seekRegionWidth(size) : 0.0;
    setState(() {
      // Switching sides starts the count over
      if (_seekForward != isForward) _seekTaps = 0;
      _seekForward = isForward;
      _seekTaps++;
      _rippleOrigin = localTap - Offset(regionLeft, 0);
    });
    _lastSeekTapTime = DateTime.now();
    _ripple.forward(from: 0);
    _seekFade.forward();

    _seekHideTimer?.cancel();
    _seekHideTimer = Timer(_seekStreakWindow, () {
      _lastSeekTapTime = null;
      if (!mounted) return;
      _seekFade.reverse().then((_) {
        if (mounted && !_seekFade.isAnimating && _seekFade.value == 0) {
          setState(() {
            _seekForward = null;
            _seekTaps = 0;
          });
        }
      });
    });
  }

  bool _isInSeekStreak(DateTime now) =>
      _lastSeekTapTime != null &&
      now.difference(_lastSeekTapTime!) < _seekStreakWindow;

  // ───────────────── Pointer Handlers ─────────────────

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    final screenSize = MediaQuery.of(context).size;
    
    // Detect bottom edge swipe for drawer
    if (event.localPosition.dy > screenSize.height - 80) {
      _isBottomEdgeSwipe = true;
      _pointerStart = event.localPosition;
      _isDragging = false;
      return;
    }

    // Ignore other edge swipes (50px on all sides) so the user can pull system UI
    // or trigger native back gestures without accidentally triggering volume/brightness.
    if (event.localPosition.dy < 50 || 
        event.localPosition.dy > screenSize.height - 50 ||
        event.localPosition.dx < 50 || 
        event.localPosition.dx > screenSize.width - 50) {
      _pointerStart = null;
      _isDragging = false;
      return;
    }
    
    _pointerStart = event.localPosition;
    _isDragging = false;

    _holdTimer?.cancel();
    if (widget.onHoldStart != null) {
      _holdTimer = Timer(PlayerGestureOverlay.holdDelay, () {
        if (!mounted || _pointerStart == null || _isDragging) return;
        _holding = true;
        widget.onHoldStart!();
      });
    }
  }

  /// Releases a hold, if one is on — telling the player.
  void _endHold() {
    _holdTimer?.cancel();
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd?.call();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.enabled || _pointerStart == null) return;
    // A finger that's holding can wander a little without it turning into
    // a volume / brightness swipe.
    if (_holding) return;

    final delta = event.localPosition - _pointerStart!;

    if (!_isDragging && delta.distance < _dragThreshold) return;

    // First time crossing threshold: a swipe, not a hold.
    _holdTimer?.cancel();
    if (!_isDragging) {
      // Only activate on primarily-vertical movement
      if (delta.dy.abs() < delta.dx.abs()) {
        // Horizontal — ignore, let WebView handle
        _pointerStart = null;
        _isBottomEdgeSwipe = false;
        return;
      }

      // Check for swipe up if it started from bottom edge
      if (_isBottomEdgeSwipe && delta.dy < 0) {
        widget.onSwipeUp?.call();
        _pointerStart = null;
        _isBottomEdgeSwipe = false;
        return;
      }

      _isDragging = true;
      final screenWidth = MediaQuery.of(context).size.width;

      if (_pointerStart!.dx > screenWidth / 2) {
        _activeGesture = _GestureType.volume;
        VolumeController.instance.getVolume().then((v) {
          if (mounted) {
            _startValue = v.clamp(0.0, 1.0);
            _currentValue = _startValue;
            _currentValueNotifier.value = _startValue;
          }
        });
      } else {
        _activeGesture = _GestureType.brightness;
        ScreenBrightness.instance.application.then((b) {
          if (mounted) {
            _startValue = b.clamp(0.0, 1.0);
            _currentValue = _startValue;
            _currentValueNotifier.value = _startValue;
          }
        }).catchError((_) {
          _startValue = 0.5;
          _currentValue = 0.5;
          _currentValueNotifier.value = 0.5;
        });
      }

      // _activeGesture just changed, which decides whether the volume/
      // brightness Positioned indicator appears at all — that still needs
      // a real rebuild (it's a rare, once-per-drag change, unlike the
      // per-tick value updates below).
      setState(() {});
      _fadeTimer?.cancel();
      _fadeController.forward();
    }

    if (_activeGesture == _GestureType.none) return;

    final screenHeight = MediaQuery.of(context).size.height;
    final verticalDelta = _pointerStart!.dy - event.localPosition.dy;
    final valueDelta = verticalDelta / (screenHeight * 0.7);
    final newValue = (_startValue + valueDelta).clamp(0.0, 1.0);

    // Throttle to ~100 steps (iOS platform channels for volume/brightness
    // drop frames if called at 120Hz). Not routed through setState — only
    // the indicator widget (via _currentValueNotifier) needs to react here.
    if ((newValue - _currentValue).abs() >= 0.01) {
      _currentValue = newValue;
      _currentValueNotifier.value = newValue;

      if (_activeGesture == _GestureType.volume) {
        VolumeController.instance.setVolume(newValue);
      } else {
        ScreenBrightness.instance
            .setApplicationScreenBrightness(newValue)
            .catchError((_) {});
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!widget.enabled) return;

    // Letting go of a hold isn't a tap.
    if (_holding) {
      _endHold();
      _pointerStart = null;
      _isBottomEdgeSwipe = false;
      _isDragging = false;
      return;
    }
    _holdTimer?.cancel();

    if (!_isDragging && _pointerStart != null && !_isBottomEdgeSwipe) {
      final now = DateTime.now();
      final tapPos = event.localPosition;
      final screenWidth = MediaQuery.of(context).size.width;
      final isForward = tapPos.dx > screenWidth / 2;

      if (_isInSeekStreak(now) && isForward == _seekForward) {
        // Continuing a seek streak on the same side: another 10s, and no
        // single-tap action (it isn't a play/pause tap).
        _seek(isForward, event.localPosition);
        _lastTapTime = null;
      } else if (_lastTapTime != null &&
          now.difference(_lastTapTime!) < const Duration(milliseconds: 320) &&
          _lastTapPosition != null &&
          (tapPos - _lastTapPosition!).distance < 35.0) {
        // Registered a double tap — starts a seek streak.
        _seek(isForward, event.localPosition);
        _lastTapTime = null; // Avoid triple taps triggering immediately again
      } else {
        _lastTapTime = now;
        _lastTapPosition = tapPos;

        // Perform standard single-tap overlay toggle
        if (widget.onTapAt != null) {
          widget.onTapAt!(tapPos);
        } else {
          widget.onTap?.call();
        }
      }
    }

    _pointerStart = null;
    _isBottomEdgeSwipe = false;

    if (_isDragging) {
      _fadeTimer?.cancel();
      _fadeTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) {
          _fadeController.reverse();
          setState(() => _activeGesture = _GestureType.none);
        }
      });
    }

    _isDragging = false;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _endHold();
    _pointerStart = null;
    _isDragging = false;
    _isBottomEdgeSwipe = false;
    _activeGesture = _GestureType.none;
    _fadeTimer?.cancel();
    _fadeController.reverse();
  }

  // ───────────────── Build ─────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          // The actual content (Video + custom controls)
          Positioned.fill(child: widget.child),

          // Double-tap seek feedback: a tinted curved region on the tapped
          // side, a ripple from the finger, chasing arrows and the running
          // total. Fades in/out; each further tap in the streak re-ripples
          // and bumps the total.
          if (_seekForward != null)
            Positioned(
              left: _seekForward! ? null : 0,
              right: _seekForward! ? 0 : null,
              top: 0,
              bottom: 0,
              width: _seekRegionWidth(size),
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: _seekFade,
                  child: ClipPath(
                    clipper: _SeekRegionClipper(isForward: _seekForward!),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(
                            color: Colors.white.withValues(alpha: 0.1)),
                        AnimatedBuilder(
                          animation: _ripple,
                          builder: (context, _) => CustomPaint(
                            painter: _RipplePainter(
                              origin: _rippleOrigin,
                              progress: _ripple.value,
                            ),
                          ),
                        ),
                        Center(
                          child: Padding(
                            // Nudge the label away from the region's
                            // curved edge, towards the screen edge.
                            padding: EdgeInsets.only(
                              left: _seekForward! ? 24 : 0,
                              right: _seekForward! ? 0 : 24,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _DoubleTapArrows(isForward: _seekForward!),
                                const SizedBox(height: 6),
                                Text(
                                  '${_seekTaps * _seekStepSeconds} seconds',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    shadows: [
                                      Shadow(
                                          color: Colors.black54,
                                          blurRadius: 4),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Volume indicator — right side
          if (_activeGesture == _GestureType.volume)
            Positioned(
              right: 40,
              top: 0,
              bottom: 0,
              child: ValueListenableBuilder<double>(
                valueListenable: _currentValueNotifier,
                builder: (context, value, _) => _buildIndicator(
                  icon: value <= 0.01
                      ? Icons.volume_off_rounded
                      : value < 0.5
                          ? Icons.volume_down_rounded
                          : Icons.volume_up_rounded,
                  value: value,
                ),
              ),
            ),

          // Brightness indicator — left side
          if (_activeGesture == _GestureType.brightness)
            Positioned(
              left: 40,
              top: 0,
              bottom: 0,
              child: ValueListenableBuilder<double>(
                valueListenable: _currentValueNotifier,
                builder: (context, value, _) => _buildIndicator(
                  icon: value < 0.3
                      ? Icons.brightness_low_rounded
                      : value < 0.7
                          ? Icons.brightness_medium_rounded
                          : Icons.brightness_high_rounded,
                  value: value,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIndicator({required IconData icon, required double value}) {
    return FadeTransition(
      opacity: _fadeController,
      child: Center(
        child: Container(
          width: 40,
          height: 180,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 8),
              SizedBox(
                width: 4,
                height: 100,
                child: RotatedBox(
                  quarterTurns: -1,
                  child: LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.white),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(value * 100).round()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────── Custom Clippers ─────────────────

/// The seek feedback region: the screen-edge side of a tall ellipse, so its
/// inner edge is a gentle curve bulging towards the centre of the screen.
class _SeekRegionClipper extends CustomClipper<Path> {
  final bool isForward;

  _SeekRegionClipper({required this.isForward});

  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..addOval(Rect.fromLTRB(
        isForward ? 0 : -w,
        -h * 0.3,
        isForward ? w * 2 : w,
        h * 1.3,
      ));
  }

  @override
  bool shouldReclip(_SeekRegionClipper oldClipper) =>
      oldClipper.isForward != isForward;
}

/// A soft circle expanding and fading out from the tap point.
class _RipplePainter extends CustomPainter {
  final Offset origin;
  final double progress;

  _RipplePainter({required this.origin, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final eased = Curves.easeOutCubic.transform(progress);
    canvas.drawCircle(
      origin,
      size.width * 0.9 * eased,
      Paint()..color = Colors.white.withValues(alpha: 0.2 * (1 - progress)),
    );
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress || old.origin != origin;
}

// ───────────────── Chasing Double-Tap Arrows Animation ─────────────────

class _DoubleTapArrows extends StatefulWidget {
  final bool isForward;
  const _DoubleTapArrows({required this.isForward});

  @override
  State<_DoubleTapArrows> createState() => _DoubleTapArrowsState();
}

class _DoubleTapArrowsState extends State<_DoubleTapArrows>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        final double step = index / 3.0;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            double opacity = 0.3;
            // Create a chasing arrow light effect
            double val = (_controller.value - step) % 1.0;
            if (val < 0) val += 1.0;
            if (widget.isForward) {
              opacity = 0.3 + (1.0 - val) * 0.7;
            } else {
              // Backward chases from right to left (index 2 to 0)
              double valBack = (_controller.value - (2 - index) / 3.0) % 1.0;
              if (valBack < 0) valBack += 1.0;
              opacity = 0.3 + (1.0 - valBack) * 0.7;
            }
            
            Widget arrow = Icon(
              Icons.play_arrow_rounded,
              color: Colors.white.withValues(alpha: opacity),
              size: 22,
            );
            if (!widget.isForward) {
              arrow = RotatedBox(
                quarterTurns: 2,
                child: arrow,
              );
            }
            return arrow;
          },
        );
      }),
    );
  }
}
