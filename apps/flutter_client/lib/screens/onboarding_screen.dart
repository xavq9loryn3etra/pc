import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_theme.dart';
import '../services/feature_flags_service.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Gradient colors matching each mode's home screen
  static const _pages = [
    _OnboardingPageData(
      title: 'Popcorn',
      subtitle: 'Stream the latest movies & TV shows',
      description:
          'Discover trending blockbusters, timeless classics, and hidden gems — all completely free. Your personal cinema, always in your pocket.',
      hidePlaybackSubtitle: 'Discover movies & TV shows',
      hidePlaybackDescription:
          'Explore trending blockbusters, timeless classics, and hidden gems. Save your favorites and find what to watch next.',
      assetPath: 'assets/logo.svg',
      isSvg: true,
      iconSize: 80,
      gradientColor: Color(0xFF2A1800), // Warm deep amber to match primary
      accentColor: AppTheme.primaryColor,
    ),
    _OnboardingPageData(
      title: 'Groovy',
      subtitle: 'Music that moves you',
      description:
          'Millions of tracks at your fingertips. Create playlists, discover new artists, and let the rhythm take over. No subscription needed.',
      assetPath: 'assets/music-app-logo.svg',
      isSvg: true,
      iconSize: 80,
      gradientColor: Color(0xFF420420), // Deep purple/red from music_home
      accentColor: Color(0xFFE91E63),
    ),
    _OnboardingPageData(
      title: 'Library',
      subtitle: 'Your next great read awaits',
      description:
          'Browse thousands of books across every genre. From trending bestsellers to timeless literature — read anytime, anywhere.',
      assetPath: 'assets/book-app-logo.svg',
      isSvg: true,
      iconSize: 80,
      gradientColor: Color(0xFF2D1B0E), // Deep warm brown from books_home
      accentColor: Color(0xFFD4A574),
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Color _getCurrentAccentColor() {
    if (!_pageController.hasClients ||
        !_pageController.position.hasContentDimensions) {
      return _pages[_currentPage].accentColor;
    }
    final page = _pageController.page ?? _currentPage.toDouble();
    final fromIndex = page.floor().clamp(0, _pages.length - 1);
    final toIndex = page.ceil().clamp(0, _pages.length - 1);
    if (fromIndex == toIndex) {
      return _pages[fromIndex].accentColor;
    }
    final fraction = page - fromIndex;
    return Color.lerp(
          _pages[fromIndex].accentColor,
          _pages[toIndex].accentColor,
          fraction,
        ) ??
        _pages[fromIndex].accentColor;
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Pages
          PageView.builder(
            controller: _pageController,
            itemCount: _pages.length,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (context, index) {
              final page = _pages[index];
              return _OnboardingPageItem(
                key: ValueKey(index),
                page: page,
                isCurrent: index == _currentPage,
              );
            },
          ),

          // Bottom controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: AnimatedBuilder(
                  animation: _pageController,
                  builder: (context, child) {
                    final currentColor = _getCurrentAccentColor();

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Page indicators
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(_pages.length, (index) {
                            final isActive = index == _currentPage;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              width: isActive ? 28 : 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: isActive ? currentColor : Colors.white24,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 32),

                        // Next / Get Started button
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            onPressed: _nextPage,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: currentColor,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 0,
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Text(
                                _currentPage == _pages.length - 1
                                    ? 'Continue'
                                    : 'Next',
                                key: ValueKey<bool>(
                                    _currentPage == _pages.length - 1),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Skip button (disabled on last page)
                        TextButton(
                          onPressed: _currentPage < _pages.length - 1
                              ? widget.onComplete
                              : null,
                          child: Text(
                            'Skip',
                            style: TextStyle(
                              color: _currentPage < _pages.length - 1
                                  ? Colors.white.withValues(alpha: 0.5)
                                  : Colors.white.withValues(alpha: 0.2),
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPageItem extends StatefulWidget {
  final _OnboardingPageData page;
  final bool isCurrent;

  const _OnboardingPageItem({
    super.key,
    required this.page,
    required this.isCurrent,
  });

  @override
  State<_OnboardingPageItem> createState() => _OnboardingPageItemState();
}

class _OnboardingPageItemState extends State<_OnboardingPageItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _gradientAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _gradientAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    if (widget.isCurrent) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _OnboardingPageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCurrent && !oldWidget.isCurrent) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final hidePlayback = FeatureFlagsService().hidePlayback.value;

    return AnimatedBuilder(
      animation: _gradientAnimation,
      builder: (context, child) {
        final progress = _gradientAnimation.value;
        // Gradient grows from top edge (0.0) downwards to 0.55
        final double endStop = (0.55 * progress).clamp(0.01, 0.55);

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(
                      Colors.black,
                      page.gradientColor,
                      progress,
                    ) ??
                    page.gradientColor,
                Colors.black,
              ],
              stops: [0.0, endStop],
            ),
          ),
          child: child,
        );
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),

              // Icon
              if (page.isSvg)
                SvgPicture.asset(
                  page.assetPath,
                  width: page.iconSize,
                  height: page.iconSize,
                  colorFilter: ColorFilter.mode(
                    page.accentColor,
                    BlendMode.srcIn,
                  ),
                )
              else
                Image.asset(
                  page.assetPath,
                  width: page.iconSize,
                  height: page.iconSize,
                ),

              const SizedBox(height: 32),

              // Subtitle
              Text(
                hidePlayback
                    ? page.hidePlaybackSubtitle ?? page.subtitle
                    : page.subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 16),

              // Description
              Text(
                hidePlayback
                    ? page.hidePlaybackDescription ?? page.description
                    : page.description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.white.withValues(alpha: 0.6),
                  height: 1.6,
                ),
              ),

              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingPageData {
  final String title;
  final String subtitle;
  final String description;
  final String assetPath;
  final bool isSvg;
  final double iconSize;
  final Color gradientColor;
  final Color accentColor;
  // Alternate copy shown while FeatureFlagsService.hidePlayback is on.
  final String? hidePlaybackSubtitle;
  final String? hidePlaybackDescription;

  const _OnboardingPageData({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.assetPath,
    required this.isSvg,
    required this.iconSize,
    required this.gradientColor,
    required this.accentColor,
    this.hidePlaybackSubtitle,
    this.hidePlaybackDescription,
  });
}
