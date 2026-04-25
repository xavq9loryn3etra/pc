import 'dart:async';
import 'package:flutter/material.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';

// Netflix-style gestures

/// Netflix-style vertical swipe overlay for volume (right) and brightness (left).
///
/// Wraps its [child] in a raw [Listener] so pointer events are captured as a
/// PARENT of the WebView — not as a sibling overlay. This guarantees we receive
/// onPointerMove even when a PlatformView (WebView) handles touches natively.
class PlayerGestureOverlay extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onSwipeUp;
  /// When false, all gesture processing is disabled (e.g. when the episode
  /// drawer is open and should receive all touches).
  final bool enabled;

  const PlayerGestureOverlay({
    super.key,
    required this.child,
    this.onTap,
    this.onSwipeUp,
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

  Offset? _pointerStart;
  bool _isDragging = false;
  bool _isBottomEdgeSwipe = false;
  static const double _dragThreshold = 18.0;

  late final AnimationController _fadeController;
  Timer? _fadeTimer;

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
    VolumeController.instance.showSystemUI = true;
    // Reset brightness back to system default when leaving the player
    ScreenBrightness.instance
        .resetApplicationScreenBrightness()
        .catchError((_) {});
    super.dispose();
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
          }
        });
      } else {
        _activeGesture = _GestureType.brightness;
        ScreenBrightness.instance.application.then((b) {
          if (mounted) {
            _startValue = b.clamp(0.0, 1.0);
            _currentValue = _startValue;
          }
        }).catchError((_) {
          _startValue = 0.5;
          _currentValue = 0.5;
        });
      }

      _fadeTimer?.cancel();
      _fadeController.forward();
    }

    if (_activeGesture == _GestureType.none) return;

    final screenHeight = MediaQuery.of(context).size.height;
    final verticalDelta = _pointerStart!.dy - event.position.dy;
    final valueDelta = verticalDelta / (screenHeight * 0.7);
    final newValue = (_startValue + valueDelta).clamp(0.0, 1.0);

    // Throttle UI rebuilds and platform channel calls to ~100 steps
    // iOS platform channels for volume/brightness drop frames if called 120Hz
    if ((newValue - _currentValue).abs() >= 0.01) {
      setState(() => _currentValue = newValue);

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
      widget.onTap?.call();
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
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          // The actual content (WebView + other overlays)
          Positioned.fill(child: widget.child),

          // Volume indicator — right side
          if (_activeGesture == _GestureType.volume)
            Positioned(
              right: 40,
              top: 0,
              bottom: 0,
              child: _buildIndicator(
                icon: _currentValue <= 0.01
                    ? Icons.volume_off_rounded
                    : _currentValue < 0.5
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                value: _currentValue,
              ),
            ),

          // Brightness indicator — left side
          if (_activeGesture == _GestureType.brightness)
            Positioned(
              left: 40,
              top: 0,
              bottom: 0,
              child: _buildIndicator(
                icon: _currentValue < 0.3
                    ? Icons.brightness_low_rounded
                    : _currentValue < 0.7
                        ? Icons.brightness_medium_rounded
                        : Icons.brightness_high_rounded,
                value: _currentValue,
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
