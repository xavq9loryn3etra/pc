import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';
import '../services/feature_flags_service.dart';

class WelcomeScreen extends StatefulWidget {
  final VoidCallback onGetStarted;

  const WelcomeScreen({super.key, required this.onGetStarted});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  // Bundled curated local assets for instant, zero-latency offline loading
  static const _movieAssets = [
    'assets/welcome/movies/movie_1.jpg',
    'assets/welcome/movies/movie_2.jpg',
    'assets/welcome/movies/movie_3.jpg',
    'assets/welcome/movies/movie_4.jpg',
    'assets/welcome/movies/movie_5.jpg',
    'assets/welcome/movies/movie_6.jpg',
    'assets/welcome/movies/movie_7.jpg',
    'assets/welcome/movies/movie_8.jpg',
  ];

  static const _musicAssets = [
    'assets/welcome/music/music_1.jpg',
    'assets/welcome/music/music_2.jpg',
    'assets/welcome/music/music_3.jpg',
    'assets/welcome/music/music_4.jpg',
    'assets/welcome/music/music_5.jpg',
    'assets/welcome/music/music_6.jpg',
    'assets/welcome/music/music_7.jpg',
    'assets/welcome/music/music_8.jpg',
  ];

  static const _bookAssets = [
    'assets/welcome/books/book_1.jpg',
    'assets/welcome/books/book_2.jpg',
    'assets/welcome/books/book_3.jpg',
    'assets/welcome/books/book_4.jpg',
    'assets/welcome/books/book_5.jpg',
    'assets/welcome/books/book_6.jpg',
    'assets/welcome/books/book_7.jpg',
    'assets/welcome/books/book_8.jpg',
  ];

  // Fade-in animation
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fadeController.forward();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  List<String> _getAssetsForRow(int rowIndex) {
    switch (rowIndex % 3) {
      case 0:
        return _bookAssets;
      case 1:
        return _musicAssets;
      case 2:
        return _movieAssets;
      default:
        return _bookAssets;
    }
  }

  Widget _buildRow(int rowIndex) {
    final assets = _getAssetsForRow(rowIndex);
    if (assets.isEmpty) return const SizedBox.shrink();

    final isMusic = (rowIndex % 3 == 1);
    final scrollRight = rowIndex.isEven;
    final speed = 1.0 + (rowIndex * 0.15);

    // Music uses 1:1 square aspect ratio; movies and books use ~2:3 portrait
    final double itemWidth = isMusic ? 135.0 : 105.0;
    final double itemHeight = isMusic ? 135.0 : 155.0;

    return _ScrollingRow(
      imageAssets: assets,
      scrollRight: scrollRight,
      speed: speed,
      itemWidth: itemWidth,
      itemHeight: itemHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    const rowCount = 6;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: ClipRect(
              child: OverflowBox(
                maxHeight: double.infinity,
                alignment: Alignment.center,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.001)
                    ..rotateX(0.15)
                    ..rotateZ(-0.05),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(rowCount, (i) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _buildRow(i),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),

          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.1),
                    Colors.black.withValues(alpha: 0.6),
                    Colors.black.withValues(alpha: 0.95),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.2, 0.55, 0.75, 0.9],
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      'assets/logo.svg',
                      width: 80,
                      colorFilter: const ColorFilter.mode(
                        AppTheme.primaryColor,
                        BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Movies. Music. Books.',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'All in One Place.',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primaryColor,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      FeatureFlagsService().hidePlayback.value
                          ? 'Discover the latest movies, trending music,\nand your next great read.'
                          : 'Stream the latest movies, discover trending music,\nand dive into your next great read — all for free.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.6),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: widget.onGetStarted,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Get Started',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScrollingRow extends StatefulWidget {
  final List<String> imageAssets;
  final bool scrollRight;
  final double speed;
  final double itemWidth;
  final double itemHeight;

  const _ScrollingRow({
    required this.imageAssets,
    required this.scrollRight,
    required this.speed,
    required this.itemWidth,
    required this.itemHeight,
  });

  @override
  State<_ScrollingRow> createState() => _ScrollingRowState();
}

class _ScrollingRowState extends State<_ScrollingRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final durationMs = (85000 / widget.speed).round();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: durationMs),
    )..repeat(reverse: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageAssets.isEmpty) return const SizedBox.shrink();

    // itemWidth + 8 total horizontal margin
    final double totalItemWidth = widget.itemWidth + 8.0;
    final double setWidth = totalItemWidth * widget.imageAssets.length;

    return SizedBox(
      height: widget.itemHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          double offset = _controller.value * setWidth;

          if (widget.scrollRight) {
            offset = offset - setWidth;
          } else {
            offset = -offset;
          }

          return Transform.translate(
            offset: Offset(offset, 0),
            child: child,
          );
        },
        child: OverflowBox(
          maxWidth: double.infinity,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._buildItems(),
              ..._buildItems(),
              ..._buildItems(), // 3 sets ensures continuous screen coverage and smooth loop
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildItems() {
    return widget.imageAssets.map((assetPath) {
      return Container(
        width: widget.itemWidth,
        height: widget.itemHeight,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            assetPath,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey[850],
              child: const Icon(Icons.broken_image, color: Colors.grey),
            ),
          ),
        ),
      );
    }).toList();
  }
}
