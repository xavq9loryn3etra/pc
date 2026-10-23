import 'package:flutter/material.dart';

/// Startup intro shown while main.dart's config/first-launch checks run,
/// straight out of the (plain black) native launch screen: the popcorn icon
/// fades in while easing up from slightly smaller than full size.
///
/// The icon then stays put until the intro has played *and* [ready] is
/// true, when [onFinished] fires and main.dart cross-fades to the next
/// screen.
///
/// Not a Scaffold — main.dart wraps it so the shader warmup widget can sit
/// alongside it.
class SplashScreen extends StatefulWidget {
  /// Whether the app has decided which screen comes next.
  final bool ready;
  final VoidCallback onFinished;

  const SplashScreen({
    super.key,
    required this.ready,
    required this.onFinished,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _iconSize = 130.0;
  static const _fadeInSeconds = 0.9;
  // Short hold so the finished frame registers before moving on.
  static const _introSeconds = _fadeInSeconds + 0.4;

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_introSeconds * 1000).round()),
  );
  late final Animation<double> _reveal = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0, _fadeInSeconds / _introSeconds,
        curve: Curves.easeOutCubic),
  );

  bool _started = false;
  bool _finished = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    // Respect the OS "remove animations" setting: show the finished frame
    // and move on as soon as the app is ready.
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
      _maybeFinish();
      return;
    }

    _intro.addStatusListener((status) {
      if (status == AnimationStatus.completed) _maybeFinish();
    });
    _intro.forward();
  }

  @override
  void didUpdateWidget(SplashScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready) _maybeFinish();
  }

  void _maybeFinish() {
    if (!widget.ready || !_intro.isCompleted) return;
    // onFinished rebuilds the parent, which mustn't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_finished || !mounted) return;
      _finished = true;
      widget.onFinished();
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FadeTransition(
        opacity: _reveal,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(_reveal),
          child: Image.asset(
            'assets/icon-transparent.png',
            width: _iconSize,
            height: _iconSize,
          ),
        ),
      ),
    );
  }
}
