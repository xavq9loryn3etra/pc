import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'main_screen.dart';
import '../theme/app_theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fillAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    _fillAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    // Start loading sequence
    _startSplashSequence();
  }

  Future<void> _startSplashSequence() async {
    // 0. Precache images for smoother mode switching
    if (mounted) {
      precacheImage(const AssetImage('assets/music-app-logo.png'), context);
      precacheImage(const AssetImage('assets/book-app-logo.png'), context);
    }

    // 1. Wait a bit, then animate fill
    await Future.delayed(const Duration(milliseconds: 500));
    await _controller.forward();

    // 2. Small pause after fill
    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Navigate
    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainScreen(),
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 800),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Deep dark background
      body: Center(
        child: SizedBox(
          width: 200,
          height: 200, // Explicit size for stack
          child: Stack(
            children: [
              // 1. "Outline" / Empty State
              // Since we don't have a stroke SVG, we use a low-opacity white version
              // to represent the "container" or "glass" look.
              Center(
                child: SvgPicture.asset(
                  'assets/logo.svg',
                  width: 180,
                  colorFilter: ColorFilter.mode(
                    Colors.white.withOpacity(0.1),
                    BlendMode.srcIn,
                  ),
                ),
              ),

              // 2. "Filling" State
              // We use an AnimatedBuilder to clip the colored logo from bottom up
              Center(
                child: AnimatedBuilder(
                  animation: _fillAnimation,
                  builder: (context, child) {
                    return ClipRect(
                      clipper: _FillClipper(_fillAnimation.value),
                      child: child,
                    );
                  },
                  child: SvgPicture.asset(
                    'assets/logo.svg',
                    width: 180,
                    colorFilter: const ColorFilter.mode(
                      AppTheme.primaryColor,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Custom Clipper to reveal from bottom to top
class _FillClipper extends CustomClipper<Rect> {
  final double progress;

  _FillClipper(this.progress);

  @override
  Rect getClip(Size size) {
    // Top is calculated:
    // progress 0.0 -> top = size.height (Hidden)
    // progress 1.0 -> top = 0.0 (Fully Visible)
    final top = size.height * (1 - progress);
    return Rect.fromLTWH(0, top, size.width, size.height * progress);
  }

  @override
  bool shouldReclip(_FillClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}
