import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/movie.dart';
import 'glass_blur.dart';

/// A frosted "Season n ⌄" pill that opens the season menu below it — on
/// the details screen and in the player's episode browser.
///
/// The menu is in the quality list's style (see QualityOptionList): a
/// frosted, rounded panel just below the pill with a row per season — its
/// name over its episode count — the [current] one ticked. It fades and
/// grows in from the pill's corner. Season 0 reads "Specials".
///
/// The menu floats over the page rather than covering it: a touch anywhere
/// else closes it and still reaches the page, so starting to scroll closes
/// the menu and scrolls in one go.
class SeasonPicker extends StatefulWidget {
  /// The seasons to offer, in order.
  final List<Season> seasons;
  final int current;
  final ValueChanged<int> onSelected;

  const SeasonPicker({
    super.key,
    required this.seasons,
    required this.current,
    required this.onSelected,
  });

  static String nameOf(int seasonNumber) =>
      seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber';

  @override
  State<SeasonPicker> createState() => _SeasonPickerState();
}

class _SeasonPickerState extends State<SeasonPicker>
    with SingleTickerProviderStateMixin {
  static const _radius = BorderRadius.all(Radius.circular(16));
  static const _width = 220.0;

  /// The menu's tallest: about five and a half rows (a row is ~56px), so
  /// with more seasons than that, the half-shown row says it scrolls.
  static const _maxMenuHeight = 308.0;

  final _menu = OverlayPortalController();
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final _curved =
      CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic);

  // The pill and its menu, as one region for TapRegion: a touch on the pill
  // isn't "outside" the menu (the pill's own tap closes it instead).
  final _region = Object();

  // Where the menu goes, in the overlay's coordinates: its top, its right
  // edge (lined up with the pill's), and its tallest before it scrolls
  // Worked out on opening.
  double _top = 0, _right = 0, _maxHeight = 0;

  // The page the pill scrolls with, while the menu is open: scrolling it
  // closes the menu, which would otherwise be left behind. (A touch does
  // already, but a mouse wheel or trackpad scrolls without one.)
  ScrollPosition? _page;

  @override
  void dispose() {
    _page?.removeListener(_close);
    _curved.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _open() {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final pill = context.findRenderObject() as RenderBox;
    final topLeft = pill.localToGlobal(Offset.zero, ancestor: overlay);
    setState(() {
      _top = topLeft.dy + pill.size.height + 8;
      _right = overlay.size.width - (topLeft.dx + pill.size.width);
      _maxHeight =
          math.min(_maxMenuHeight, overlay.size.height - _top - 16);
    });
    _page = Scrollable.maybeOf(context)?.position?..addListener(_close);
    _menu.show();
    _animation.forward(from: 0);
  }

  Future<void> _close() async {
    _page?.removeListener(_close);
    _page = null;
    if (!_menu.isShowing) return;
    await _animation.reverse();
    if (mounted) _menu.hide();
  }

  void _pick(int seasonNumber) {
    _close();
    if (seasonNumber != widget.current) widget.onSelected(seasonNumber);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _menu,
      overlayChildBuilder: _buildMenu,
      child: TapRegion(
        groupId: _region,
        child: GlassPillButton(
          label: SeasonPicker.nameOf(widget.current),
          trailingIcon: Icons.keyboard_arrow_down_rounded,
          onPressed: () => _menu.isShowing ? _close() : _open(),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: _top,
          right: _right,
          width: _width,
          child: TapRegion(
            groupId: _region,
            // Fires on a touch going down anywhere else, without taking it
            // from what's there — a scroll carries on after closing this.
            onTapOutside: (_) => _close(),
            child: FadeTransition(
              opacity: _curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.94, end: 1.0).animate(_curved),
                alignment: Alignment.topRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: _maxHeight),
                  child: _buildPanel(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPanel() {
    return ClipRRect(
      borderRadius: _radius,
      child: GlassBlur(
        sigma: 16,
        reducedTint: const Color(0xF2161616),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kGlassSheetTint,
            borderRadius: _radius,
            border: Border.all(color: kGlassEdge),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.seasons.length; i++) ...[
                    if (i > 0)
                      Container(
                        height: 0.5,
                        margin: const EdgeInsets.only(left: 16),
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                    _buildRow(widget.seasons[i]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(Season season) {
    final isCurrent = season.seasonNumber == widget.current;
    final count = season.episodeCount;
    return InkWell(
      onTap: () => _pick(season.seasonNumber),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    SeasonPicker.nameOf(season.seasonNumber),
                    style: TextStyle(
                      color: isCurrent ? Colors.white : Colors.white70,
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (count != null && count > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      count == 1 ? '1 episode' : '$count episodes',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isCurrent) ...[
              const SizedBox(width: 12),
              const Icon(Icons.check_rounded, color: Colors.white, size: 20),
            ],
          ],
        ),
      ),
    );
  }
}
