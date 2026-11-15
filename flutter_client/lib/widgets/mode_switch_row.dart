import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';

/// Row of the mode cards (Popcorn / Ramen; Groovy / Library when they're
/// on, see AppModeService.modes). The modes not chosen are small cards,
/// their logos faded; the chosen one widens to take the rest of the row,
/// in its colour, with a short line on what it has beside its logo — and
/// they resize smoothly as the mode changes. Shared by the Settings screen
/// and the mode selector so both always look the same.
///
/// [onSelected] defaults to switching the mode in place (Settings): the
/// cards finish resizing first, then the mode changes with Settings still
/// open. The mode selector passes its own to also navigate into the app.
class ModeSwitchRow extends StatefulWidget {
  final ValueChanged<AppMode>? onSelected;

  const ModeSwitchRow({super.key, this.onSelected});

  @override
  State<ModeSwitchRow> createState() => _ModeSwitchRowState();
}

class _ModeSwitchRowState extends State<ModeSwitchRow> {
  static const double _gap = 12;

  // The mode tapped in Settings, shown chosen while the cards resize to
  // it, before the mode itself changes (see _pick).
  AppMode? _picked;

  void _pick(AppMode mode) {
    final onSelected = widget.onSelected;
    if (onSelected != null) return onSelected(mode);
    if (mode == AppModeService().currentMode.value || _picked != null) return;
    setState(() => _picked = mode);
    // Once the cards have resized: the mode, staying on Settings.
    Future.delayed(ModeOption.resize + const Duration(milliseconds: 60), () {
      AppModeService().setMode(mode, keepTab: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ValueListenableBuilder<AppMode>(
        valueListenable: AppModeService().currentMode,
        builder: (context, current, _) => LayoutBuilder(
          builder: (context, constraints) {
            final modes = AppModeService.modes;
            final others = modes.length - 1;
            // What's left for the chosen one, after the others' small
            // cards and the gaps.
            final chosenWidth = (constraints.maxWidth -
                    others * (ModeOption.compactWidth + _gap))
                .clamp(ModeOption.compactWidth, double.infinity);
            final chosen = _picked ?? current;
            return Row(
              children: [
                for (final (i, mode) in modes.indexed) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  ModeOption(
                    mode: mode,
                    size: 34,
                    selected: mode == chosen,
                    width: mode == chosen
                        ? chosenWidth
                        : ModeOption.compactWidth,
                    onTap: () => _pick(mode),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// How faded a mode's logo is while another mode's chosen.
const _kUnchosenOpacity = 0.35;

class ModeOption extends StatefulWidget {
  final AppMode mode;
  final double size;
  final VoidCallback onTap;

  /// Its width: [compactWidth] when not chosen, wider when it is (see
  /// ModeSwitchRow) — animated as it changes.
  final double width;

  /// A mode card's width when it isn't the chosen one.
  static const double compactWidth = 90;

  /// How long the cards take to resize.
  static const Duration resize = Duration(milliseconds: 320);

  /// Whether it's the chosen mode: the wide card, in its colour.
  final bool selected;

  const ModeOption({
    super.key,
    required this.mode,
    required this.onTap,
    required this.selected,
    this.size = 48.0,
    this.width = compactWidth,
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

    return Builder(
      builder: (context) {
        final isSelected = widget.selected;
        final modeColor = mode.accentColor;

        // The logo alone: it's the mode's name already. In its own
        // colours (Ramen's bowl as drawn, Popcorn's cream), faded when not
        // chosen rather than greyed.
        final badge = Center(
          child: Semantics(
            label: mode.label,
            child: AnimatedOpacity(
              opacity: isSelected ? 1 : _kUnchosenOpacity,
              duration: const Duration(milliseconds: 200),
              child: SvgPicture.asset(
                mode.logoAsset,
                height: widget.size,
                width: ModeOption.compactWidth - 24,
                colorFilter: mode.logoHasOwnColors
                    ? null
                    : ColorFilter.mode(modeColor, BlendMode.srcIn),
              ),
            ),
          ),
        );

        // Press feedback: shrinks slightly and brightens while held.
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: AnimatedScale(
              scale: _pressed ? 0.96 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: ModeOption.resize,
                curve: Curves.easeOutCubic,
                width: widget.width,
                height: 88,
                decoration: BoxDecoration(
                  // The chosen one in a wash of its colour.
                  color: isSelected
                      ? modeColor.withValues(alpha: _pressed ? 0.16 : 0.1)
                      : Colors.white.withValues(alpha: _pressed ? 0.08 : 0),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected
                        ? modeColor.withValues(alpha: 0.5)
                        : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                clipBehavior: Clip.hardEdge,
                // The line beside the logo only once there's room for it,
                // fading in as the card widens (and out as it narrows).
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final roomy = isSelected &&
                        constraints.maxWidth >= ModeOption.compactWidth + 110;
                    // The logo centred; on the chosen card, the line
                    // centred under it.
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        badge,
                        if (roomy) ...[
                          const SizedBox(height: 6),
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 250),
                            builder: (context, t, line) =>
                                Opacity(opacity: t, child: line),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                mode.tagline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
