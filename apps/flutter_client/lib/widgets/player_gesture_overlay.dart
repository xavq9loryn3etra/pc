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
  final VoidCallback? onSwipeUp;
  final ValueChanged<bool>? onDoubleTapSeek;
  
  /// When false, all gesture processing is disabled (e.g. when the episode
  /// drawer is open and should receive all touches).
  final bool enabled;

  const PlayerGestureOverlay({
    super.key,
    required this.child,
    this.onTap,
    this.onSwipeUp,
    this.onDoubleTapSeek,
    this.enabled = true,
  });

  @override
  State<PlayerGestureOverlay> createState() => _PlayerGestureOverlayState();
}

enum _GestureType { none, volume, brightness }

class _PlayerGestureOverlayState extends State<PlayerGestureOverlay>
    with SingleTickerProviderStateMixin {
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

  // Double tap seeking state variables
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;
  bool _showLeftSeekIndicator = false;
  bool _showRightSeekIndicator = false;
  int _seekOverlayPulseCount = 0;

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
    _fadeTimer?.cancel();
    _fadeController.dispose();
    _currentValueNotifier.dispose();
    VolumeController.instance.showSystemUI = true;
    // Reset brightness back to system default when leaving the player
    ScreenBrightness.instance
        .resetApplicationScreenBrightness()
        .catchError((_) {});
    super.dispose();
  }

  void _triggerDoubleTapAnimation(bool isForward) {
    setState(() {
      if (isForward) {
        _showRightSeekIndicator = true;
        _showLeftSeekIndicator = false;
      } else {
        _showLeftSeekIndicator = true;
        _showRightSeekIndicator = false;
      }
      _seekOverlayPulseCount++;
    });
    
    final currentPulse = _seekOverlayPulseCount;
    // Pulse animation/fade-out after 650ms
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted && _seekOverlayPulseCount == currentPulse) {
        setState(() {
          _showLeftSeekIndicator = false;
          _showRightSeekIndicator = false;
        });
      }
    });
  }

  // ───────────────── Pointer Handlers ─────────────────

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    final screenSize = MediaQuery.of(context).size;
    
    // Detect bottom edge swipe for drawer
    if (event.position.dy > screenSize.height - 80) {
      _isBottomEdgeSwipe = true;
      _pointerStart = event.position;
      _isDragging = false;
      return;
    }

    // Ignore other edge swipes (50px on all sides) so the user can pull system UI
    // or trigger native back gestures without accidentally triggering volume/brightness.
    if (event.position.dy < 50 || 
        event.position.dy > screenSize.height - 50 ||
        event.position.dx < 50 || 
        event.position.dx > screenSize.width - 50) {
      _pointerStart = null;
      _isDragging = false;
      return;
    }
    
    _pointerStart = event.position;
    _isDragging = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.enabled || _pointerStart == null) return;

    final delta = event.position - _pointerStart!;

    if (!_isDragging && delta.distance < _dragThreshold) return;

    // First time crossing threshold
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
    final verticalDelta = _pointerStart!.dy - event.position.dy;
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
    
    if (!_isDragging && _pointerStart != null && !_isBottomEdgeSwipe) {
      final now = DateTime.now();
      final tapPos = event.position;

      if (_lastTapTime != null && 
          now.difference(_lastTapTime!) < const Duration(milliseconds: 320) &&
          _lastTapPosition != null &&
          (tapPos - _lastTapPosition!).distance < 35.0) {
        // Registered a beautiful double tap!
        final screenWidth = MediaQuery.of(context).size.width;
        final isForward = tapPos.dx > screenWidth / 2;

        widget.onDoubleTapSeek?.call(isForward);
        _triggerDoubleTapAnimation(isForward);

        _lastTapTime = null; // Avoid triple taps triggering immediately again
      } else {
        _lastTapTime = now;
        _lastTapPosition = tapPos;

        // Perform standard single-tap overlay toggle
        widget.onTap?.call();
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

          // Left Double Tap Seek Overlay
          if (_showLeftSeekIndicator)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: size.width * 0.35,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipPath(
                      clipper: LeftArcClipper(),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment.centerLeft,
                            radius: 1.0,
                            colors: [
                              Colors.white.withValues(alpha: 0.12),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16.0), // push slightly away from center line
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _DoubleTapArrows(isForward: false),
                          const SizedBox(height: 8),
                          const Text(
                            '10 seconds',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 4),
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

          // Right Double Tap Seek Overlay
          if (_showRightSeekIndicator)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: size.width * 0.35,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipPath(
                      clipper: RightArcClipper(),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment.centerRight,
                            radius: 1.0,
                            colors: [
                              Colors.white.withValues(alpha: 0.12),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16.0), // push slightly away from center line
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _DoubleTapArrows(isForward: true),
                          const SizedBox(height: 8),
                          const Text(
                            '10 seconds',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 4),
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

class LeftArcClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(0, size.height);
    path.quadraticBezierTo(
      size.width,
      size.height * 0.5,
      0,
      0,
    );
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

class RightArcClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(size.width, 0);
    path.lineTo(size.width, size.height);
    path.quadraticBezierTo(
      0,
      size.height * 0.5,
      size.width,
      0,
    );
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
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
