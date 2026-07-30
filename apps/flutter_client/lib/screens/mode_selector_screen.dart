
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../theme/app_theme.dart';
import 'main_screen.dart';

class ModeSelectorScreen extends StatefulWidget {
  const ModeSelectorScreen({super.key});

  @override
  State<ModeSelectorScreen> createState() => _ModeSelectorScreenState();
}

class _ModeSelectorScreenState extends State<ModeSelectorScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    // Precache mode logos for smooth display
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Future.wait([
        precacheImage(const AssetImage('assets/music-app-logo.png'), context),
        precacheImage(const AssetImage('assets/book-app-logo.png'), context),
      ]);
      if (mounted) _fadeController.forward();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _selectMode(AppMode mode) {
    AppModeService().setMode(mode);
    // Get to the destination as fast as possible rather than making the
    // user sit through a long fade — the destination screen's own skeleton
    // loaders (TMDB fetch, etc.) already communicate "still loading" once
    // we're there, so there's nothing to gain from a slow transition on
    // top of that. Kept brief instead of instant (Duration.zero) purely so
    // it doesn't read as a rendering glitch.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MainScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 150),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: [
                const SizedBox(height: 40),

                // App brand
                Image.asset(
                  'assets/icon-transparent.png',
                  width: 44,
                ),
                const SizedBox(height: 20),
                const Text(
                  'What are you in the mood for?',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Pick your vibe. You can switch anytime.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.5),
                  ),
                ),

                const SizedBox(height: 40),

                // Mode cards
                Expanded(
                  child: ValueListenableBuilder<AppMode>(
                    valueListenable: AppModeService().currentMode,
                    builder: (context, currentMode, _) {
                      return ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          _buildModeCard(
                            mode: AppMode.movies,
                            currentMode: currentMode,
                            title: 'Popcorn',
                            subtitle: 'Movies & TV Shows',
                            assetPath: 'assets/logo.svg',
                            isSvg: true,
                            gradientColor: const Color(0xFF2A1800),
                            accentColor: AppTheme.primaryColor,
                          ),
                          _buildModeCard(
                            mode: AppMode.music,
                            currentMode: currentMode,
                            title: 'Groovy',
                            subtitle: 'Music & Playlists',
                            assetPath: 'assets/music-app-logo.png',
                            isSvg: false,
                            gradientColor: const Color(0xFF420420),
                            accentColor: const Color(0xFFE91E63),
                          ),
                          _buildModeCard(
                            mode: AppMode.books,
                            currentMode: currentMode,
                            title: 'Library',
                            subtitle: 'Books & Literature',
                            assetPath: 'assets/book-app-logo.png',
                            isSvg: false,
                            gradientColor: const Color(0xFF2D1B0E),
                            accentColor: const Color(0xFFD4A574),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeCard({
    required AppMode mode,
    required AppMode currentMode,
    required String title,
    required String subtitle,
    required String assetPath,
    required bool isSvg,
    required Color gradientColor,
    required Color accentColor,
  }) {
    final isSelected = currentMode == mode;

    return Container(
      height: 120,
      margin: const EdgeInsets.only(bottom: 16),
      child: GestureDetector(
        onTap: () => _selectMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                gradientColor.withOpacity(isSelected ? 1.0 : 0.6),
                Colors.black.withOpacity(0.85),
              ],
            ),
            border: Border.all(
              color: isSelected
                  ? accentColor.withOpacity(0.5)
                  : Colors.white.withOpacity(0.08),
              width: isSelected ? 1.5 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: accentColor.withOpacity(0.15),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              child: Row(
                children: [
                    // Logo
                    SizedBox(
                      width: 52,
                      height: 52,
                      child: isSvg
                          ? SvgPicture.asset(
                              assetPath,
                              colorFilter: ColorFilter.mode(
                                isSelected ? accentColor : Colors.white70,
                                BlendMode.srcIn,
                              ),
                            )
                          : Image.asset(
                              assetPath,
                              opacity: isSelected
                                  ? const AlwaysStoppedAnimation(1.0)
                                  : const AlwaysStoppedAnimation(0.7),
                            ),
                    ),
                    const SizedBox(width: 20),

                    // Text
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color:
                                  isSelected ? accentColor : Colors.white,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 14,
                              color: isSelected
                                  ? Colors.white.withOpacity(0.7)
                                  : Colors.white.withOpacity(0.4),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Arrow indicator
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: isSelected
                          ? accentColor.withOpacity(0.7)
                          : Colors.white24,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
}
