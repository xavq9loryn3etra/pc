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
class SeasonPicker extends StatelessWidget {
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

  static const _radius = BorderRadius.all(Radius.circular(16));

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (pillContext) => GlassPillButton(
        label: nameOf(current),
        trailingIcon: Icons.keyboard_arrow_down_rounded,
        onPressed: () => _showMenu(pillContext),
      ),
    );
  }

  Future<void> _showMenu(BuildContext pillContext) async {
    final pill = pillContext.findRenderObject() as RenderBox;
    final pillTopLeft = pill.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(pillContext);
    final top = pillTopLeft.dy + pill.size.height + 8;

    final picked = await showGeneralDialog<int>(
      context: pillContext,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 180),
      transitionBuilder: (_, __, ___, child) => child,
      pageBuilder: (menuContext, animation, _) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return Stack(
          children: [
            Positioned(
              top: top,
              right: screen.width - (pillTopLeft.dx + pill.size.width),
              width: 220,
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween(begin: 0.94, end: 1.0).animate(curved),
                  alignment: Alignment.topRight,
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(maxHeight: screen.height - top - 16),
                    child: _buildPanel(menuContext),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (picked != null && picked != current) onSelected(picked);
  }

  Widget _buildPanel(BuildContext menuContext) {
    return ClipRRect(
      borderRadius: _radius,
      child: GlassBlur(
        sigma: 16,
        reducedTint: const Color(0xF2161616),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: _radius,
            border: Border.all(color: kGlassEdge),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < seasons.length; i++) ...[
                    if (i > 0)
                      Container(
                        height: 0.5,
                        margin: const EdgeInsets.only(left: 16),
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                    _buildRow(menuContext, seasons[i]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext menuContext, Season season) {
    final isCurrent = season.seasonNumber == current;
    final count = season.episodeCount;
    return InkWell(
      onTap: () => Navigator.pop(menuContext, season.seasonNumber),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nameOf(season.seasonNumber),
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
