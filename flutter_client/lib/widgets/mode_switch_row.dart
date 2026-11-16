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
    // Once the cards have resized: the mode, staying on Settings. Then
    // the tap's done with, should this switch still be here (it's usually
    // rebuilt with the new mode's screens): one left set ignored every
    // tap after it.
    Future.delayed(ModeOption.resize + const Duration(milliseconds: 60), () {
      AppModeService().setMode(mode, keepTab: true);
      if (mounted) setState(() => _picked = null);
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

  /// How long the cards take to resize — and everything on them to
  /// change with it, on one curve ([curve]), so it moves as one.
  static const Duration resize = Duration(milliseconds: 380);
  static const Curve curve = Curves.easeInOutCubic;

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
              duration: ModeOption.resize,
              curve: ModeOption.curve,
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
                curve: ModeOption.curve,
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
                // The logo centred, gliding up as the line under it fades
                // in (and back as it fades out) — with the card's resize,
                // on its curve. The line's laid out at its full width all
                // along and just clipped by the card, so nothing jumps or
                // reflows as it widens or narrows.
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedPadding(
                        duration: ModeOption.resize,
                        curve: ModeOption.curve,
                        padding: EdgeInsets.only(bottom: isSelected ? 22 : 0),
                        child: badge,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 13,
                      height: 18,
                      child: AnimatedOpacity(
                        opacity: isSelected ? 1 : 0,
                        duration: ModeOption.resize,
                        curve: ModeOption.curve,
                        child: OverflowBox(
                          maxWidth: double.infinity,
                          child: Text(
                            mode.tagline,
                            maxLines: 1,
                            softWrap: false,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
