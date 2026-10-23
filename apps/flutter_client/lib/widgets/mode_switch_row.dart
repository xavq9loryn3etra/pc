import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';

/// Row of the three mode buttons (Popcorn / Groovy / Library), highlighting
/// the current mode with its outline and colour (no filled background or
/// glow). Shared by the Settings screen and the mode selector so both
/// always look the same.
///
/// [onSelected] defaults to just switching the mode in place (Settings);
/// the mode selector passes its own to also navigate into the app.
class ModeSwitchRow extends StatelessWidget {
  final ValueChanged<AppMode>? onSelected;

  const ModeSwitchRow({super.key, this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final mode in const [AppMode.movies, AppMode.music, AppMode.books])
            ModeOption(
              mode: mode,
              size: 32,
              onTap: () => onSelected != null
                  ? onSelected!(mode)
                  : AppModeService().setMode(mode),
            ),
        ],
      ),
    );
  }
}

class ModeOption extends StatefulWidget {
  final AppMode mode;
  final double size;
  final VoidCallback onTap;

  const ModeOption({
    super.key,
    required this.mode,
    required this.onTap,
    this.size = 48.0,
  });

  @override
  State<ModeOption> createState() => _ModeOptionState();
}

class _ModeOptionState extends State<ModeOption> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;

    return ValueListenableBuilder<AppMode>(
      valueListenable: AppModeService().currentMode,
      builder: (context, currentMode, child) {
        final isSelected = currentMode == mode;
        final modeColor = mode.accentColor;

        // Press feedback: shrinks slightly and brightens while held.
        return GestureDetector(
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onTap();
          },
          child: AnimatedScale(
            scale: _pressed ? 0.92 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 90,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: _pressed ? 0.08 : 0),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected
                      ? modeColor.withValues(alpha: 0.5)
                      : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 48,
                    child: Center(
                      child: SvgPicture.asset(
                        mode.logoAsset,
                        height: widget.size,
                        width: widget.size,
                        colorFilter: ColorFilter.mode(
                          isSelected ? modeColor : Colors.white70,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mode.label,
                    style: TextStyle(
                      color: isSelected ? modeColor : Colors.white60,
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
