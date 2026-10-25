import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../services/torrent/stream_resolver.dart';

/// The quality picker, in the episode cards' style (see EpisodeCard): one
/// rounded panel with a faint edge and a row per [QualityOption] — the
/// quality's name over its resolution and download size, an optional small
/// tag ("RECOMMENDED", "LAST WATCHED", "PLAYING") and a play glyph. The
/// [isPrimary] row's glyph sits on a white disc, like the white Play
/// button; the [isCurrent] one shows a check instead.
///
/// The only thing the user picks is a quality — which torrent plays is
/// decided for them (see [StreamResolver.qualityOptions]). Used by the
/// Play popup, the player's Quality menu and its episode browser.
///
/// While a picked quality starts ([starting]), the list stays put: that
/// row swaps its details for [startingMessage] and its glyph for a
/// spinner, and the other rows fade back and ignore taps.
class QualityOptionList extends StatelessWidget {
  final List<QualityOption> options;
  final ValueChanged<QualityOption> onSelected;
  final String? Function(QualityOption option)? tagFor;
  final bool Function(QualityOption option)? isPrimary;
  final bool Function(QualityOption option)? isCurrent;
  final QualityOption? starting;
  final String? startingMessage;

  /// Tighter rows for the player's narrow side panels.
  final bool compact;

  const QualityOptionList({
    super.key,
    required this.options,
    required this.onSelected,
    this.tagFor,
    this.isPrimary,
    this.isCurrent,
    this.starting,
    this.startingMessage,
    this.compact = false,
  });

  static const _fade = Duration(milliseconds: 200);

  static const _radius = BorderRadius.all(Radius.circular(16));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: _radius,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0)
                  Container(
                    height: 0.5,
                    margin: const EdgeInsets.only(left: 16),
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                _buildRow(options[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(QualityOption option) {
    final tag = tagFor?.call(option);
    final current = isCurrent?.call(option) ?? false;
    final primary = isPrimary?.call(option) ?? false;
    final isStarting = identical(option, starting);
    final busy = starting != null;
    final details = isStarting && startingMessage != null
        ? startingMessage!
        : [
            option.resolution,
            if (option.size case final size?) size,
          ].join('  ·  ');

    return AnimatedOpacity(
      duration: _fade,
      opacity: busy && !isStarting ? 0.35 : 1,
      child: InkWell(
        onTap: busy ? null : () => onSelected(option),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: compact ? 11 : 13,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 14 : 15,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: _fade,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, if (current != null) current],
                      ),
                      child: Text(
                        details,
                        key: ValueKey(details),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.w500,
                          color: Colors.white60,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // The tag gives way to the progress message.
              if (tag != null && !isStarting) ...[
                const SizedBox(width: 12),
                Text(
                  tag.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: Colors.white54,
                  ),
                ),
              ],
              const SizedBox(width: 12),
              SizedBox(
                width: 30,
                height: 30,
                child: AnimatedSwitcher(
                  duration: _fade,
                  child: isStarting
                      ? const Padding(
                          key: ValueKey('spinner'),
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : current
                          ? const Icon(Icons.check_rounded,
                              color: Colors.white, size: 20)
                          : primary
                              ? const DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Icon(Icons.play_arrow_rounded,
                                        color: Colors.black, size: 20),
                                  ),
                                )
                              : const Icon(Icons.play_arrow_rounded,
                                  color: Colors.white70, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [QualityOptionList] while the qualities load: the same panel and row
/// sizes, with shimmering bars for each row's text and play glyph (as
/// EpisodeCardSkeleton does for the episode cards).
class QualityOptionListSkeleton extends StatelessWidget {
  final int rows;
  final bool compact;

  const QualityOptionListSkeleton({
    super.key,
    this.rows = 3,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);

    // A bar the height of one line of text at [fontSize] / [height],
    // [width] wide.
    Widget line(double fontSize, double height, double width) {
      final size = textScaler.scale(fontSize);
      return SizedBox(
        height: size * height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: width,
            height: size * 0.75,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: QualityOptionList._radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: QualityOptionList._radius,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Shimmer.fromColors(
          baseColor: Colors.white.withValues(alpha: 0.08),
          highlightColor: Colors.white.withValues(alpha: 0.2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows; i++) ...[
                if (i > 0)
                  Container(
                    height: 0.5,
                    margin: const EdgeInsets.only(left: 16),
                    color: Colors.black,
                  ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: compact ? 11 : 13,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Vary the widths a little, like real names.
                            line(compact ? 14 : 15, 1.25, 70.0 + 18 * (i % 2)),
                            const SizedBox(height: 2),
                            line(12, 1.2, 110),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      const SizedBox(
                        width: 30,
                        height: 30,
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black,
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox(width: 22, height: 22),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small spaced-capitals heading above a [QualityOptionList], styled like
/// the cards' "EPISODE n" label.
class QualitySectionLabel extends StatelessWidget {
  final String text;

  const QualitySectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: Colors.white54,
      ),
    );
  }
}
