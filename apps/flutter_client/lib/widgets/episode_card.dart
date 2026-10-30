import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../models/movie.dart';
import '../theme/app_theme.dart';
import 'glass_blur.dart';

/// An episode as a card (Apple TV style): the still across the top,
/// melting into a blurred, darkened copy of itself behind the text —
/// "EPISODE n", the title, a short description and the runtime.
///
/// Fixed height (see [heightFor]) so a grid of them lines up.
class EpisodeCard extends StatelessWidget {
  final Episode episode;

  /// Shown when the episode has no still of its own (the show's backdrop).
  final String? fallbackImage;

  /// Watch progress (0–1), shown as a bar beside the runtime.
  final double? progress;

  /// Playback hidden (FeatureFlagsService.hidePlayback): no play glyph.
  final bool hidePlayback;

  /// The episode the player is on (its episode browser): says so beside
  /// "EPISODE n" and brightens the card's edge.
  final bool playing;

  /// Opens the episode (on the details screen, its popup). Null makes the
  /// card inert — as is an episode that hasn't aired yet, whatever this is.
  final VoidCallback? onTap;

  const EpisodeCard({
    super.key,
    required this.episode,
    this.fallbackImage,
    this.progress,
    this.hidePlayback = false,
    this.playing = false,
    this.onTap,
  });

  static const _radius = 16.0;
  static const _padding = 10.0;
  // How far the text block reaches up over the bottom of the still.
  static const _overlap = 16.0;

  static const _labelStyle = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: Colors.white54,
  );
  static const _titleStyle = TextStyle(
    fontSize: 14,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: Colors.white,
  );
  static const _descriptionStyle = TextStyle(
    fontSize: 12,
    height: 1.35,
    color: Colors.white60,
  );
  static const _metaStyle = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: Colors.white60,
  );

  static double _imageHeight(double width) => width * 9 / 16;

  /// The card's height at [width]: the still, then the text block (one
  /// label line, up to two title and two description lines, the runtime
  /// row), scaled with the user's text size.
  static double heightFor(double width, TextScaler textScaler) {
    double line(TextStyle s) => textScaler.scale(s.fontSize!) * s.height!;
    return _imageHeight(width) -
        _overlap +
        line(_labelStyle) +
        2 +
        line(_titleStyle) * 2 +
        4 +
        line(_descriptionStyle) * 2 +
        10 +
        line(_metaStyle).clamp(14.0, double.infinity) +
        _padding;
  }

  static String _formatRuntime(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60, m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  // From here an episode counts as watched — the rest is usually credits.
  static const _watchedAt = 0.95;

  /// The time beside the play glyph, as on Apple TV: the runtime ("46m"),
  /// what's left part-way through ("23m left"), or "Watched" at the end.
  /// Null when there's nothing to say.
  static String? _timeLabel(int? runtime, double? progress) {
    final p = progress ?? 0;
    if (p >= _watchedAt) return 'Watched';
    final r = runtime ?? 0;
    if (r <= 0) return null;
    if (p > 0) {
      final left = math.max(1, (r * (1 - p)).round());
      return '${_formatRuntime(left)} left';
    }
    return _formatRuntime(r);
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final image = episode.stillPath ?? fallbackImage;
    final unreleased = episode.isUnreleased;
    final airDate =
        episode.airDate == null ? null : DateTime.tryParse(episode.airDate!);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final imageHeight = _imageHeight(width);

      final card = ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            EpisodeBackdrop(image: image),
            if (image != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: imageHeight,
                child: EpisodeStill(
                  image: image,
                  decodeWidth: (width * dpr).toInt(),
                  dimmed: unreleased,
                ),
              ),

            Padding(
              padding: EdgeInsets.fromLTRB(
                _padding,
                imageHeight - _overlap,
                _padding,
                _padding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playing
                        ? 'EPISODE ${episode.episodeNumber}  ·  PLAYING'
                        : 'EPISODE ${episode.episodeNumber}',
                    style: _labelStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    episode.name,
                    style: unreleased
                        ? _titleStyle.copyWith(color: Colors.white70)
                        : _titleStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    episode.overview.isNotEmpty
                        ? episode.overview
                        : 'No description available.',
                    style: _descriptionStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  if (unreleased)
                    Row(
                      children: [
                        const Icon(Icons.lock_clock_rounded,
                            size: 14, color: Colors.white60),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            airDate == null
                                ? 'Coming soon'
                                : 'Available ${_formatDate(airDate)}',
                            style: _metaStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        if (!hidePlayback) ...[
                          const Icon(Icons.play_arrow_rounded,
                              size: 16, color: Colors.white70),
                          const SizedBox(width: 4),
                        ],
                        // Watch history: how far in, as a bar, and the
                        // time left (see _timeLabel).
                        if (!hidePlayback &&
                            progress != null &&
                            progress! > 0) ...[
                          _ProgressBar(progress: progress!, width: 44),
                          const SizedBox(width: 6),
                        ],
                        if (_timeLabel(
                                episode.runtime, hidePlayback ? null : progress)
                            case final label?)
                          Flexible(
                            child: Text(
                              label,
                              style: _metaStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),

            // Faint edge, as on the reference cards — brighter on the
            // episode that's playing.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_radius),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: playing ? 0.5 : 0.12),
                  ),
                ),
              ),
            ),

            // Ink on top, so the ripple shows over the image.
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: unreleased ? null : onTap),
            ),
          ],
        ),
      );

      // Not out yet: greyed out, and inert (see onTap).
      return unreleased
          ? ColorFiltered(colorFilter: greyscale, child: card)
          : card;
    });
  }

  /// Drains the colour out of an episode that hasn't aired yet. Shared
  /// with the player's episode browser.
  static const greyscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);
}

/// An [EpisodeCard] while its season loads: the same size and layout, with
/// shimmering blocks for the still and each line of text.
class EpisodeCardSkeleton extends StatelessWidget {
  const EpisodeCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);

    // A bar the size of one line of [style]'s text, [widthFactor] of the
    // card wide.
    Widget line(TextStyle style, double widthFactor) {
      final fontSize = textScaler.scale(style.fontSize!);
      return SizedBox(
        height: fontSize * style.height!,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: widthFactor,
            child: Container(
              height: fontSize * 0.75,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final imageHeight = EpisodeCard._imageHeight(constraints.maxWidth);
      return ClipRRect(
        borderRadius: BorderRadius.circular(EpisodeCard._radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(EpisodeCard._radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Shimmer.fromColors(
            baseColor: Colors.grey[900]!,
            highlightColor: Colors.grey[800]!,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The still, ending a little above where the text starts
                // (the real one fades out under it).
                Container(
                  height: imageHeight - EpisodeCard._overlap - 6,
                  color: Colors.black,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      EpisodeCard._padding,
                      6,
                      EpisodeCard._padding,
                      EpisodeCard._padding,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        line(EpisodeCard._labelStyle, 0.4),
                        const SizedBox(height: 2),
                        line(EpisodeCard._titleStyle, 0.85),
                        const SizedBox(height: 4),
                        line(EpisodeCard._descriptionStyle, 1),
                        line(EpisodeCard._descriptionStyle, 0.6),
                        const Spacer(),
                        line(EpisodeCard._metaStyle, 0.25),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// The episode cards' (and episode popup's) background: the still decoded
/// at a tiny size and stretched — a soft blur of its colours for free,
/// instead of a live blur filter — then darkened for the text on it.
class EpisodeBackdrop extends StatelessWidget {
  final String? image;

  /// How much the image is darkened (0–1) for the text on it.
  final double dim;

  const EpisodeBackdrop({super.key, required this.image, this.dim = 0.45});

  /// The width [image] is decoded at — for preloading it (see
  /// precacheNetworkImage), so it paints on the first frame.
  static const int cacheWidth = 12;

  @override
  Widget build(BuildContext context) {
    const fallback = ColoredBox(color: AppTheme.surfaceColor);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Plain, not colour-boosted like the glass: behind a popup's text
        // the boost was too loud.
        if (image != null)
          CachedNetworkImage(
            imageUrl: image!,
            memCacheWidth: cacheWidth,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            placeholder: (_, __) => fallback,
            errorWidget: (_, __, ___) => fallback,
          )
        else
          fallback,
        ColoredBox(color: Colors.black.withValues(alpha: dim)),
      ],
    );
  }
}

/// An episode's still, fading out at the bottom into an [EpisodeBackdrop]
/// behind it. [dimmed] for episodes that haven't aired yet.
class EpisodeStill extends StatelessWidget {
  final String image;

  /// A lower-resolution copy of [image] that's likely already cached (the
  /// card's), shown until [image] loads instead of nothing.
  final String? preview;

  /// Decode width in physical pixels — the box's width × device pixel
  /// ratio.
  final int decodeWidth;
  final bool dimmed;

  /// Also fade out the right-hand side — for when it ends mid-screen
  /// (the player's sideways episode view) rather than at a card's edge.
  final bool fadeRight;

  const EpisodeStill({
    super.key,
    required this.image,
    this.preview,
    required this.decodeWidth,
    this.dimmed = false,
    this.fadeRight = false,
  });

  static ShaderMask _fade(Alignment end, List<double> stops, Widget child) =>
      ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: -end,
          end: end,
          colors: const [Colors.white, Colors.white, Colors.transparent],
          stops: stops,
        ).createShader(rect),
        child: child,
      );

  Widget _previewOrNothing() => preview == null
      ? const SizedBox.shrink()
      : CachedNetworkImage(
          imageUrl: preview!,
          memCacheWidth: decodeWidth,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          placeholder: (_, __) => const SizedBox.shrink(),
          errorWidget: (_, __, ___) => const SizedBox.shrink(),
        );

  @override
  Widget build(BuildContext context) {
    final faded = _fade(
      Alignment.bottomCenter,
      const [0, 0.6, 1],
      CachedNetworkImage(
        imageUrl: image,
        memCacheWidth: decodeWidth,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 200),
        placeholder: (_, __) => _previewOrNothing(),
        errorWidget: (_, __, ___) => _previewOrNothing(),
      ),
    );
    return Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: fadeRight
          ? _fade(Alignment.centerRight, const [0, 0.65, 1], faded)
          : faded,
    );
  }
}

/// The top of the episode / movie popup: the card's look at full width —
/// the [image] fading into the backdrop, then a small [label] line, the
/// [title], a [meta] line (with a watch-progress bar) and the full
/// [description]. Sits on an [EpisodeSheetFrame], which paints the
/// backdrop. See [EpisodeDetailHeader].
class DetailHeader extends StatelessWidget {
  final String? image;

  /// Dims the image (for episodes that haven't aired yet).
  final bool dimmed;
  final String label;
  final String title;
  final String meta;

  /// Watch progress (0–1), shown as a bar beside [meta].
  final double? progress;
  final String description;

  /// For the player's sideways episode view: the image also fades out on
  /// the right ([EpisodeStill.fadeRight]), and the text keeps an extra
  /// [textInset] clear of a camera cutout the image runs under.
  final bool sideways;
  final EdgeInsets textInset;

  const DetailHeader({
    super.key,
    required this.image,
    this.dimmed = false,
    required this.label,
    required this.title,
    required this.meta,
    this.progress,
    required this.description,
    this.sideways = false,
    this.textInset = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final watched = progress != null && progress! > 0;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final imageHeight = EpisodeCard._imageHeight(width);
      return Stack(
        children: [
          if (image != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: imageHeight,
              // Full-width, so TMDB's full-size still rather than the
              // cards' w500 one, which looks soft stretched this wide.
              child: EpisodeStill(
                image: image!.replaceFirst('/w500/', '/original/'),
                preview: image,
                decodeWidth: (width * dpr).toInt(),
                dimmed: dimmed,
                fadeRight: sideways,
              ),
            ),
          Padding(
            // Over the bottom of the image, as on the cards; below the drag
            // handle when there's no image.
            padding: EdgeInsets.fromLTRB(
              20 + textInset.left,
              image != null ? imageHeight - 28 : 40,
              20 + textInset.right,
              8 + textInset.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label.isNotEmpty) ...[
                  Text(
                    label,
                    style: EpisodeCard._labelStyle.copyWith(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (meta.isNotEmpty || watched) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (watched) ...[
                        _ProgressBar(progress: progress!, width: 48),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          meta,
                          style: EpisodeCard._metaStyle.copyWith(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  description.isNotEmpty
                      ? description
                      : 'No description available.',
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

/// [DetailHeader] for an episode: "EPISODE n", its name, runtime and air
/// date, and its description.
class EpisodeDetailHeader extends StatelessWidget {
  final Episode episode;
  final String? fallbackImage;
  final double? progress;

  /// See [DetailHeader.sideways] and [DetailHeader.textInset].
  final bool sideways;
  final EdgeInsets textInset;

  const EpisodeDetailHeader({
    super.key,
    required this.episode,
    this.fallbackImage,
    this.progress,
    this.sideways = false,
    this.textInset = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final unreleased = episode.isUnreleased;
    final airDate =
        episode.airDate == null ? null : DateTime.tryParse(episode.airDate!);
    final time = EpisodeCard._timeLabel(episode.runtime, progress);
    return DetailHeader(
      image: episode.stillPath ?? fallbackImage,
      dimmed: unreleased,
      label: 'EPISODE ${episode.episodeNumber}',
      title: episode.name,
      meta: [
        if (time != null) time,
        if (airDate != null)
          '${unreleased ? 'Available' : 'Aired'} '
              '${EpisodeCard._formatDate(airDate)}',
      ].join('  ·  '),
      progress: progress,
      description: episode.overview,
      sideways: sideways,
      textInset: textInset,
    );
  }
}

/// The episode / movie popup's frame: a bottom sheet in the cards' style —
/// rounded top, faint edge, the blurred still ([EpisodeBackdrop]) behind
/// everything, and a drag handle over the top of the image. [child] is
/// laid out over it and sets its height.
///
/// Dragged down — by the handle, or by pulling down on [child]'s content
/// once it's scrolled to the top — it follows the finger and closes when
/// let go far or fast enough, springing back otherwise. (The modal sheet's
/// own drag-to-close only works while nothing inside can scroll; give
/// [child]'s scrollable ClampingScrollPhysics, so pulling past its top
/// reaches this on iOS too instead of bouncing.)
class EpisodeSheetFrame extends StatefulWidget {
  final String? image;
  final Widget child;

  /// Frosted glass behind [child] — the page underneath, blurred under the
  /// app's thick dark glass (as its dialogs) — instead of the blurred
  /// [image]: the quality selector and the person sheet, where the image's
  /// colours competed with the content.
  final bool frosted;

  const EpisodeSheetFrame({
    super.key,
    required this.image,
    required this.child,
    this.frosted = false,
  });

  static const _radius = BorderRadius.vertical(top: Radius.circular(24));
  static final _edge = BorderSide(color: kGlassEdge);

  @override
  State<EpisodeSheetFrame> createState() => _EpisodeSheetFrameState();
}

class _EpisodeSheetFrameState extends State<EpisodeSheetFrame> {
  // How far the sheet has been pulled down, in pixels.
  double _drag = 0;
  bool _dragging = false;

  // Let go past this share of the sheet's height, or flicked down faster
  // than this (px/s), and it closes.
  static const _closeFraction = 0.25;
  static const _closeVelocity = 700.0;

  void _dragBy(double dy) {
    setState(() {
      _dragging = true;
      _drag = math.max(0, _drag + dy);
    });
  }

  void _dragEnd(double velocity) {
    if (!_dragging) return;
    // The sheet's last laid-out height, read off its render box: context.size
    // asserts here, since the drag's setState has just marked it dirty (a
    // scroll's end notification arrives in that same frame).
    final box = context.findRenderObject() as RenderBox?;
    final height =
        box != null && box.hasSize ? box.size.height : double.infinity;
    if (_drag > height * _closeFraction || velocity > _closeVelocity) {
      Navigator.of(context).maybePop();
    } else {
      setState(() {
        _dragging = false;
        _drag = 0;
      });
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n is OverscrollNotification && n.dragDetails != null) {
      // Pulling down past the top of the content pulls the sheet down.
      if (n.overscroll < 0 || _drag > 0) _dragBy(-n.overscroll);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        _drag > 0) {
      // Pushing back up lifts the sheet before scrolling the content.
      _dragBy(n.dragDetails!.delta.dy);
    } else if (n is ScrollEndNotification) {
      _dragEnd(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(0, _drag, 0),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ClipRRect(
          borderRadius: EpisodeSheetFrame._radius,
          child: Stack(
            children: [
              // A bit darker than the cards': the sheet is much bigger, so
              // the colours read stronger.
              Positioned.fill(
                child: widget.frosted
                    ? const GlassBlur(
                        // Strong: a big surface, the page's detail would
                        // show through a lighter blur.
                        sigma: 30,
                        reducedTint: Color(0xF2161616),
                        child: ColoredBox(color: kGlassSheetTint),
                      )
                    : EpisodeBackdrop(image: widget.image, dim: 0.6),
              ),
              widget.child,
              // The handle, with a generous strip around it to grab.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 28,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
                  onVerticalDragEnd: (d) => _dragEnd(d.primaryVelocity ?? 0),
                  child: Align(
                    alignment: const Alignment(0, -0.15),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white54,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    // No bottom edge: the sheet runs off the bottom of the
                    // screen.
                    decoration: BoxDecoration(
                      borderRadius: EpisodeSheetFrame._radius,
                      border: Border(
                        top: EpisodeSheetFrame._edge,
                        left: EpisodeSheetFrame._edge,
                        right: EpisodeSheetFrame._edge,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The episode popup without sources — when playback is hidden, or the
/// episode hasn't aired yet: the [header], then [action] (the streaming
/// service's button) if there is one.
class EpisodeInfoSheet extends StatelessWidget {
  final String? image;
  final Widget header;
  final Widget? action;

  const EpisodeInfoSheet({
    super.key,
    required this.image,
    required this.header,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return EpisodeSheetFrame(
      image: image,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          // Pulling past the top drags the sheet (EpisodeSheetFrame).
          physics: const ClampingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (action != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: action,
                ),
              SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final double progress;
  final double width;

  const _ProgressBar({required this.progress, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: progress.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.primaryColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
