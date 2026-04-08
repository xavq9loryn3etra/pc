import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_theme.dart';

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
      assetPath: 'assets/music-app-logo.png',
      isSvg: false,
      iconSize: 80,
      gradientColor: Color(0xFF420420), // Deep purple/red from music_home
      accentColor: Color(0xFFE91E63),
    ),
    _OnboardingPageData(
      title: 'Library',
      subtitle: 'Your next great read awaits',
      description:
          'Browse thousands of books across every genre. From trending bestsellers to timeless literature — read anytime, anywhere.',
      assetPath: 'assets/book-app-logo.png',
      isSvg: false,
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
              return _buildPage(page);
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
                child: Column(
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
                            color: isActive
                                ? _pages[_currentPage].accentColor
                                : Colors.white24,
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
                          backgroundColor: _pages[_currentPage].accentColor,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          _currentPage == _pages.length - 1
                              ? 'Continue'
                              : 'Next',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Skip button (not on last page)
                    if (_currentPage < _pages.length - 1)
                      TextButton(
                        onPressed: widget.onComplete,
                        child: Text(
                          'Skip',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 16,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(_OnboardingPageData page) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            page.gradientColor,
            Colors.black,
          ],
          stops: const [0.0, 0.5],
        ),
      ),
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

              const SizedBox(height: 40),

              // Title
              Text(
                page.title,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: page.accentColor,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),

              // Subtitle
              Text(
                page.subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20),

              // Description
              Text(
                page.description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.white.withOpacity(0.6),
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

  const _OnboardingPageData({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.assetPath,
    required this.isSvg,
    required this.iconSize,
    required this.gradientColor,
    required this.accentColor,
  });
}
