import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/movie.dart';

/// Synopsis collapsed to [collapsedLines] with a soft fade, plus a
/// More / Less toggle that also reveals [extra] (e.g. the cast row) below
/// the full text. The toggle shows whenever there's something more to see:
/// the synopsis runs past [collapsedLines], or [extra] is set.
class ExpandableSynopsis extends StatefulWidget {
  final String text;
  final int collapsedLines;

  /// Shown under the full synopsis while expanded.
  final Widget? extra;

  /// False shows the full synopsis and [extra] up front, with no
  /// More / Less toggle (used for movies; series collapse).
  final bool collapsible;

  const ExpandableSynopsis({
    super.key,
    required this.text,
    this.collapsedLines = 4,
    this.extra,
    this.collapsible = true,
  });

  @override
  State<ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<ExpandableSynopsis> {
  bool _expanded = false;

  static const _style = TextStyle(
    fontSize: 15,
    height: 1.5,
    color: Colors.white70,
  );

  void _toggle() {
    if (!_expanded) {
      setState(() => _expanded = true);
      return;
    }
    // Collapsing from partway down (e.g. while browsing the cast) shrinks
    // the content above the scroll position, leaving the view parked past
    // what's now there. If the synopsis's top has scrolled out of view,
    // bring it back to just under the app bar.
    _scrollTopIntoView();
    setState(() => _expanded = false);
  }

  void _scrollTopIntoView() {
    final box = context.findRenderObject() as RenderBox?;
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject() as RenderBox?;
    if (box == null || scrollable == null || viewport == null) return;

    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    // The details app bar floats over the content; keep clear of it.
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 16;
    if (top >= topInset) return; // Already in view — don't move.

    final position = scrollable.position;
    position.animateTo(
      (position.pixels + top - topInset)
          .clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.isEmpty && widget.extra == null) {
      return const SizedBox.shrink();
    }

    if (!widget.collapsible) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.text.isNotEmpty) Text(widget.text, style: _style),
          if (widget.extra != null) ...[
            if (widget.text.isNotEmpty) const SizedBox(height: 28),
            widget.extra!,
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Measure with the inherited (theme) font, same as the Text below,
        // to know whether the synopsis overflows the collapsed height.
        final painter = TextPainter(
          text: TextSpan(
            text: widget.text,
            style: DefaultTextStyle.of(context).style.merge(_style),
          ),
          maxLines: widget.collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        if (!overflows && widget.extra == null) {
          return Text(widget.text, style: _style);
        }

        final clipped = overflows && !_expanded;
        final text = Text(
          widget.text,
          style: _style,
          maxLines: clipped ? widget.collapsedLines : null,
          overflow: clipped ? TextOverflow.clip : null,
        );

        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.text.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: clipped
                      // Fades the last collapsed line out rather than
                      // cutting it mid-sentence.
                      ? ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.6, 1.0],
                          ).createShader(bounds),
                          child: text,
                        )
                      : text,
                ),
              // Outside the tap target, so scrolling or tapping the cast
              // row doesn't collapse the section.
              if (_expanded && widget.extra != null) ...[
                const SizedBox(height: 28),
                widget.extra!,
              ],
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                child: Padding(
                  // Taller tap target than the label itself.
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _expanded ? 'Less' : 'More',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "Cast" heading plus a horizontal row of circular headshots with each
/// actor's name and character. Bleeds past the screen's side padding
/// ([bleed] on each side) so it scrolls edge to edge.
class CastRow extends StatelessWidget {
  final List<CastMember> cast;
  final double bleed;

  const CastRow({super.key, required this.cast, this.bleed = 24});

  static const double _avatar = 68;
  static const double _itemWidth = 84;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Cast',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final fullWidth = constraints.maxWidth + bleed * 2;
            return SizedBox(
              height: 148,
              child: OverflowBox(
                minWidth: fullWidth,
                maxWidth: fullWidth,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  // Less the tile's side inset around its photo, so the
                  // first photo lines up with the text above it.
                  padding: EdgeInsets.symmetric(
                    horizontal: bleed - (_itemWidth - _avatar) / 2,
                  ),
                  itemCount: cast.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => _CastTile(member: cast[i]),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CastTile extends StatelessWidget {
  final CastMember member;

  const _CastTile({required this.member});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final initials = member.name
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p.characters.first)
        .join()
        .toUpperCase();
    final placeholder = Container(
      color: Colors.white.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white.withValues(alpha: 0.5),
        ),
      ),
    );

    return SizedBox(
      width: CastRow._itemWidth,
      child: Column(
        children: [
          ClipOval(
            child: SizedBox.square(
              dimension: CastRow._avatar,
              child: member.profileUrl == null
                  ? placeholder
                  : CachedNetworkImage(
                      imageUrl: member.profileUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: (CastRow._avatar * dpr).toInt(),
                      placeholder: (_, __) => placeholder,
                      errorWidget: (_, __, ___) => placeholder,
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            member.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          if (member.character != null) ...[
            const SizedBox(height: 2),
            Text(
              member.character!,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
