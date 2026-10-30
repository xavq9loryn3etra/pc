import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../models/movie.dart';
import 'person_sheet.dart';

/// Synopsis collapsed to [collapsedLines], Apple TV style: the last line
/// fades out sideways into a MORE at its end. Tapping expands it, also
/// revealing [extra] (e.g. a series' cast row) below the full text, with
/// a LESS to collapse again. The toggle shows whenever there's something
/// more to see: the synopsis runs past [collapsedLines], or [extra] is set.
class ExpandableSynopsis extends StatefulWidget {
  final String text;
  final int collapsedLines;

  /// Shown under the full synopsis while expanded.
  final Widget? extra;

  const ExpandableSynopsis({
    super.key,
    required this.text,
    this.collapsedLines = 4,
    this.extra,
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

  static const _toggleStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.bold,
    color: Colors.white,
  );

  /// How far the last line fades over before MORE, and the gap between.
  static const double _fadeWidth = 56;
  static const double _gap = 6;

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

    return LayoutBuilder(
      builder: (context, constraints) {
        // Measure with the inherited (theme) font, same as the Text below,
        // to know whether the synopsis overflows the collapsed height —
        // and where its last collapsed line starts.
        TextPainter measure(String text, TextStyle style, {int? maxLines}) =>
            TextPainter(
              text: TextSpan(
                text: text,
                style: DefaultTextStyle.of(context).style.merge(style),
              ),
              maxLines: maxLines,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: constraints.maxWidth);

        final painter = measure(widget.text, _style,
            maxLines: widget.collapsedLines);
        final overflows = painter.didExceedMaxLines;
        final collapsedHeight = painter.height;
        final lines = painter.computeLineMetrics();
        final lastLineTop = lines
            .take(lines.length - 1)
            .fold<double>(0, (top, line) => top + line.height);
        painter.dispose();

        if (!overflows && widget.extra == null) {
          return Text(widget.text, style: _style);
        }

        final clipped = overflows && !_expanded;
        final morePainter = measure('MORE', _toggleStyle);
        final moreWidth = morePainter.width;
        morePainter.dispose();

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
                      ? _collapsed(
                          width: constraints.maxWidth,
                          height: collapsedHeight,
                          lastLineTop: lastLineTop,
                          moreWidth: moreWidth,
                        )
                      : Text(widget.text, style: _style),
                ),
              // Outside the tap target, so scrolling or tapping the cast
              // row doesn't collapse the section.
              if (_expanded && widget.extra != null) ...[
                const SizedBox(height: 28),
                widget.extra!,
              ],
              // Below the text when it isn't collapsed with MORE on its
              // last line: once expanded (LESS), or when only [extra] is
              // hidden (the text fits).
              if (!clipped)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: Padding(
                    // Taller tap target than the label itself.
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_expanded ? 'LESS' : 'MORE',
                        style: _toggleStyle),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// The collapsed synopsis: all its lines but the last as they are, the
  /// last fading out sideways into MORE at its end, as on Apple TV.
  Widget _collapsed({
    required double width,
    required double height,
    required double lastLineTop,
    required double moreWidth,
  }) {
    final text = Text(
      widget.text,
      style: _style,
      maxLines: widget.collapsedLines,
      overflow: TextOverflow.clip,
    );
    final fadeEnd = ((width - moreWidth - _gap) / width).clamp(0.0, 1.0);
    final fadeStart = ((width - moreWidth - _gap - _fadeWidth) / width)
        .clamp(0.0, fadeEnd);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          ClipRect(
            clipper: _Band(0, lastLineTop),
            child: text,
          ),
          ClipRect(
            clipper: _Band(lastLineTop, height),
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => LinearGradient(
                colors: const [
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                  Colors.transparent,
                ],
                stops: [0, fadeStart, fadeEnd, 1],
              ).createShader(bounds),
              child: text,
            ),
          ),
          Positioned(
            right: 0,
            top: lastLineTop,
            bottom: 0,
            child: const Center(child: Text('MORE', style: _toggleStyle)),
          ),
        ],
      ),
    );
  }
}

/// Clips to the horizontal band from [top] to [bottom].
class _Band extends CustomClipper<Rect> {
  final double top;
  final double bottom;

  const _Band(this.top, this.bottom);

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, bottom);

  @override
  bool shouldReclip(_Band old) => old.top != top || old.bottom != bottom;
}

/// "Cast & Crew" (just "Cast" without crew) heading plus a horizontal row
/// of circular headshots, each with the person's name and their character
/// or job — directors and creators first. Tapping one opens their
/// PersonSheet. Bleeds past the screen's side padding ([bleed] on each
/// side) so it scrolls edge to edge.
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
        Text(
          cast.any((m) => m.isCrew) ? 'Cast & Crew' : 'Cast',
          style: const TextStyle(
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: member.id == null ? null : () => PersonSheet.show(context, member),
      child: SizedBox(
        width: CastRow._itemWidth,
        child: Column(
          children: [
            PersonPhoto(url: member.profileUrl, size: CastRow._avatar),
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
      ),
    );
  }
}

/// A person's round photo, [size] across: a soft shimmer while it loads,
/// and a silhouette when there's none (or it won't load).
class PersonPhoto extends StatelessWidget {
  final String? url;
  final double size;

  const PersonPhoto({super.key, required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final silhouette = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.14),
            Colors.white.withValues(alpha: 0.06),
          ],
        ),
      ),
      child: Align(
        alignment: const Alignment(0, 0.6),
        child: Icon(
          Icons.person_rounded,
          size: size * 0.7,
          color: Colors.white.withValues(alpha: 0.3),
        ),
      ),
    );
    final loading = Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: const ColoredBox(color: Colors.black),
    );
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? silhouette
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                // Faces are near the top of a portrait photo.
                alignment: const Alignment(0, -0.4),
                memCacheWidth: (size * dpr).toInt(),
                fadeInDuration: const Duration(milliseconds: 200),
                placeholder: (_, __) => loading,
                errorWidget: (_, __, ___) => silhouette,
              ),
      ),
    );
  }
}
