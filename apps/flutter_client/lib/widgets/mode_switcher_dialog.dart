import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_client/theme/app_theme.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';

class ModeSwitcherDialog extends StatelessWidget {
  const ModeSwitcherDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        // Swipe up to dismiss (negative velocity)
        if (details.primaryVelocity != null &&
            details.primaryVelocity! < -200) {
          Navigator.of(context).pop();
        }
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 40,
                spreadRadius: 4,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(24)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(24),
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08), // subtle border
                    width: 1,
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Switch Mode",
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                ),
                      ),
                      const SizedBox(height: 24),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildModeOption(
                                context,
                                mode: AppMode.movies,
                                assetPath: 'assets/logo.svg',
                                isSvg: true,
                                size: 32.0,
                                label: "Popcorn",
                                color: AppTheme.primaryColor,
                              ),
                              _buildModeOption(
                                context,
                                mode: AppMode.music,
                                assetPath: 'assets/music-app-logo.png',
                                isSvg: false,
                                label: "Groovy",
                                color: AppTheme.primaryColor,
                              ),
                              _buildModeOption(
                                context,
                                mode: AppMode.books,
                                assetPath: 'assets/book-app-logo.png',
                                isSvg: false,
                                label: "Library",
                                color: AppTheme.primaryColor,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeOption(
    BuildContext context, {
    required AppMode mode,
    required String label,
    required Color color,
    required String assetPath,
    bool isSvg = false,
    double size = 48.0,
  }) {
    return ValueListenableBuilder<AppMode>(
      valueListenable: AppModeService().currentMode,
      builder: (context, currentMode, child) {
        final isSelected = currentMode == mode;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              AppModeService().setMode(mode);
              Navigator.of(context).pop();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 90,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withOpacity(0.1)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? Colors.white24 : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 48,
                    child: Center(
                      child: isSvg
                          ? SvgPicture.asset(
                              assetPath,
                              height: size,
                              width: size,
                              colorFilter: ColorFilter.mode(
                                isSelected ? color : Colors.white70,
                                BlendMode.srcIn,
                              ),
                            )
                          : Image.asset(
                              assetPath,
                              height: size,
                              width: size,
                              cacheWidth:
                                  (size * 3).toInt(), // Optimize decode size
                              cacheHeight: (size * 3).toInt(),
                              gaplessPlayback: true,
                              opacity: isSelected
                                  ? const AlwaysStoppedAnimation(1.0)
                                  : const AlwaysStoppedAnimation(0.7),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white60,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
