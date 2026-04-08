import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/tmdb_service.dart';
import '../services/books_service.dart';
import '../theme/app_theme.dart';

class WelcomeScreen extends StatefulWidget {
  final VoidCallback onGetStarted;

  const WelcomeScreen({super.key, required this.onGetStarted});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  // Hardcoded fallbacks — shown instantly, replaced silently if API responds
  // Using w185 and -M.jpg sizes to dramatically speed up network load
  static const _fallbackMoviePosters = [
    'https://image.tmdb.org/t/p/w185/8cdWjvZQUExUUTzyp4t6EDMubfO.jpg',
    'https://image.tmdb.org/t/p/w185/hZkgoQYus5dXo3H8T7CYV502Nmc.jpg',
    'https://image.tmdb.org/t/p/w185/wWba3TaojhK7NdB0PiSfiy0JGUq.jpg',
    'https://image.tmdb.org/t/p/w185/rktDFPbfHfUbArZ6OOOKsXcv0Bm.jpg',
    'https://image.tmdb.org/t/p/w185/4m1Au3YkjqsxF8iwQy0fPYSxDSf.jpg',
    'https://image.tmdb.org/t/p/w185/vpnVM9B6NMmQpWeZvzLvDESb2QY.jpg',
    'https://image.tmdb.org/t/p/w185/ym1dxyOk4jFcSl4Q2zmRrA5BEEN.jpg',
    'https://image.tmdb.org/t/p/w185/gKkl37BQuKTanygYQG1pyYgLVgf.jpg',
    'https://image.tmdb.org/t/p/w185/xRWht48C2V8XNfzvPehyClOvDnI.jpg',
    'https://image.tmdb.org/t/p/w185/6FfCtHgWpGLI7BzYQscykoHGOQn.jpg',
  ];

  static const _fallbackMusicCovers = [
    'https://coverartarchive.org/release/b84ee12a-09ef-421b-82de-b9cc1e0e9d17/front-250', // Thriller - Michael Jackson
    'https://coverartarchive.org/release/a4864e94-6d75-4ade-bc93-0b389f85a2a8/front-250', // Abbey Road - Beatles
    'https://coverartarchive.org/release/17e5e955-1c39-4b48-be6b-decf6d695cd0/front-250', // Dark Side of the Moon - Pink Floyd
    'https://coverartarchive.org/release/0b2835d5-75ef-4c25-8b4a-a7b0e1153974/front-250', // Back in Black - AC/DC
    'https://coverartarchive.org/release/e8c8bbf8-15c1-477f-af5b-2c1479af037e/front-250', // Rumours - Fleetwood Mac
    'https://coverartarchive.org/release/4e7e09c6-5e82-4cfc-8e00-7e8a3b3e8602/front-250', // 21 - Adele
    'https://coverartarchive.org/release/375d75a4-744d-3d59-95ea-f712d8e2db87/front-250', // Nevermind - Nirvana
    'https://coverartarchive.org/release/b3b7e934-445b-4c68-a097-730c6a6d47e5/front-250', // Random Access Memories - Daft Punk
    'https://coverartarchive.org/release/cadd3eb7-86a6-3ff0-9e72-9d5273ada4a5/front-250', // Born to Run - Springsteen
    'https://coverartarchive.org/release/1b022e01-4da6-387b-8658-8678046e4cef/front-250', // OK Computer - Radiohead
  ];

  static const _fallbackBookCovers = [
    'https://covers.openlibrary.org/b/id/14845137-M.jpg',
    'https://covers.openlibrary.org/b/id/14829188-M.jpg',
    'https://covers.openlibrary.org/b/id/14807828-M.jpg',
    'https://covers.openlibrary.org/b/id/14313084-M.jpg',
    'https://covers.openlibrary.org/b/id/14350216-M.jpg',
    'https://covers.openlibrary.org/b/id/13269612-M.jpg',
    'https://covers.openlibrary.org/b/id/12818673-M.jpg',
    'https://covers.openlibrary.org/b/id/14573bindery-M.jpg',
    'https://covers.openlibrary.org/b/id/12547191-M.jpg',
    'https://covers.openlibrary.org/b/id/10521270-M.jpg',
  ];

  late List<String> _moviePosters;
  late List<String> _musicCovers;
  late List<String> _bookCovers;

  // Fade-in animation
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _moviePosters = List.from(_fallbackMoviePosters);
    _musicCovers = List.from(_fallbackMusicCovers);
    _bookCovers = List.from(_fallbackBookCovers);

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

    _loadTrendingData();
  }

  Future<void> _loadTrendingData() async {
    try {
      final tmdb = TMDBService();
      final trendingMovies = await tmdb.getTrending();
      final movieUrls = trendingMovies
          .where((m) => m.image != null)
          .take(10)
          .map((m) => m.image!.replaceAll('w500', 'w185'))
          .toList();

      final booksService = BooksService();
      final trendingBooks = await booksService.getTrendingBooks();
      final bookUrls = trendingBooks
          .where((b) => b.coverUrl != null)
          .take(10)
          .map((b) => b.coverUrl!.replaceAll('-L.jpg', '-M.jpg'))
          .toList();

      if (mounted) {
        setState(() {
          if (movieUrls.isNotEmpty) _moviePosters = movieUrls;
          if (bookUrls.isNotEmpty) _bookCovers = bookUrls;
        });
      }
    } catch (e) {
      print('Welcome screen data load error: $e');
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  List<String> _getUrlsForRow(int rowIndex) {
    switch (rowIndex % 3) {
      case 0:
        return _moviePosters;
      case 1:
        return _musicCovers;
      case 2:
        return _bookCovers;
      default:
        return _moviePosters;
    }
  }

  Widget _buildRow(int rowIndex) {
    final urls = _getUrlsForRow(rowIndex);
    if (urls.isEmpty) return const SizedBox.shrink();

    final scrollRight = rowIndex.isEven;
    final speed = 1.0 + (rowIndex * 0.15); 

    return _ScrollingRow(
      imageUrls: urls,
      scrollRight: scrollRight,
      speed: speed,
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
                    Colors.black.withOpacity(0.3),
                    Colors.black.withOpacity(0.1),
                    Colors.black.withOpacity(0.6),
                    Colors.black.withOpacity(0.95),
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
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
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
                      'Stream the latest movies, discover trending music,\nand dive into your next great read — all for free.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.6),
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
  final List<String> imageUrls;
  final bool scrollRight;
  final double speed;

  const _ScrollingRow({
    required this.imageUrls,
    required this.scrollRight,
    required this.speed,
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
    final durationMs = (30000 / widget.speed).round();
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
    if (widget.imageUrls.isEmpty) return const SizedBox.shrink();

    // 110 width + 8 total horizontal margin
    const double itemWidth = 118.0; 
    final double setWidth = itemWidth * widget.imageUrls.length;

    return SizedBox(
      height: 160,
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
              ..._buildItems(), // 3 sets ensures we always cover screen and exits smoothly
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildItems() {
    return widget.imageUrls.map((url) {
      return Container(
        width: 110,
        height: 160,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            memCacheWidth: 220, // Greatly reduces decoding overhead/memory usage
            placeholder: (_, __) => Container(
              color: Colors.grey[900],
            ),
            errorWidget: (_, __, ___) => Container(
              color: Colors.grey[850],
              child: const Icon(Icons.broken_image, color: Colors.grey),
            ),
          ),
        ),
      );
    }).toList();
  }
}
