import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../services/saved_movies_service.dart';
import '../services/feature_flags_service.dart';
import 'artwork_glow.dart';
import 'episode_card.dart';
import 'tv_focus.dart';
import '../screens/details_screen.dart';

class MoviePoster extends StatefulWidget {
  final Movie movie;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double width;
  final double height;
  final String? heroTag;
  final bool showTitle;

  const MoviePoster({
    super.key,
    required this.movie,
    this.onTap,
    this.onLongPress,
    this.width = 120,
    this.height = 180,
    this.showTitle = false,
    this.heroTag,
  });

  @override
  State<MoviePoster> createState() => _MoviePosterState();
}

class _MoviePosterState extends State<MoviePoster> {
  // Under the mouse: only the poster's zoom listens (see _zoomed), not the
  // whole card rebuilt on every hover.
  final ValueNotifier<bool> _hovered = ValueNotifier(false);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  /// The poster, a touch larger under the mouse: just the picture (the
  /// title stays still — text redrawn at every in-between size shimmered),
  /// drawn once and that zoomed (filterQuality) rather than redrawn each
  /// frame, easing out softly.
  Widget _zoomed(Widget poster) => ValueListenableBuilder<bool>(
        valueListenable: _hovered,
        builder: (context, hovered, child) => AnimatedScale(
          scale: hovered ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          filterQuality: FilterQuality.medium,
          child: child,
        ),
        child: RepaintBoundary(child: poster),
      );

  // A finger touching the poster usually means it's about to be opened:
  // its page starts loading now, the moment before the tap lands.
  void _prefetchDetails(TapDownDetails _) {
    if (widget.onTap != null) DetailsScreen.prefetch(context, widget.movie);
  }

  @override
  Widget build(BuildContext context) {
    Widget imageContent = Hero(
      tag: widget.heroTag ?? 'movie_${widget.movie.id}_${hashCode}',
      child: Container(
        width: widget.width == double.infinity ? double.infinity : widget.width,
        height:
            widget.height == double.infinity ? double.infinity : widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            SavedMoviesService(),
            FeatureFlagsService().hidePlayback,
          ]),
          builder: (context, _) {
            final hidePlayback = FeatureFlagsService().hidePlayback.value;
            final historyMovie = hidePlayback
                ? null
                : SavedMoviesService().getMovieFromHistory(widget.movie.id,
                    type: widget.movie.type);
            final progress = hidePlayback
                ? null
                : historyMovie?.progress ?? widget.movie.progress;
            final currentSeason = hidePlayback
                ? null
                : historyMovie?.currentSeason ?? widget.movie.currentSeason;
            final currentEpisode = hidePlayback
                ? null
                : historyMovie?.currentEpisode ?? widget.movie.currentEpisode;
            final hasProgress = progress != null && progress > 0;
            final showBadge = widget.movie.type == 'tv' &&
                currentSeason != null &&
                currentEpisode != null;

            final posterUrl = widget.movie.posterUrl;
            final hasPoster = posterUrl != null && posterUrl.isNotEmpty;
            final isSvg = hasPoster && posterUrl.toLowerCase().endsWith('.svg');
            // Multiply by 1.5 to ensure sharpness (supersample slightly)
            final decodeHeight =
                ((widget.height == double.infinity ? 400 : widget.height) *
                        MediaQuery.of(context).devicePixelRatio *
                        1.5)
                    .toInt();
            final Widget image = !hasPoster
                ? Container(
                    color: Colors.grey[900],
                    child: const Center(
                      child: Icon(Icons.movie_rounded, color: Colors.white24),
                    ),
                  )
                : isSvg
                    ? SvgPicture.network(
                        posterUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        placeholderBuilder: (context) => Shimmer.fromColors(
                          baseColor: Colors.grey[900]!,
                          highlightColor: Colors.grey[800]!,
                          child: Container(color: Colors.black),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: posterUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        memCacheHeight: decodeHeight,
                        placeholder: (context, url) => Shimmer.fromColors(
                          baseColor: Colors.grey[900]!,
                          highlightColor: Colors.grey[800]!,
                          child: Container(color: Colors.black),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: Colors.grey[900],
                          child: const Center(
                            child: Icon(
                              Icons.broken_image_rounded,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                      );

            if (!showBadge && !hasProgress) return image;

            // Watch history, in the episode cards' style (see EpisodeCard):
            // the poster melts at the bottom into a blurred, darkened copy
            // of itself, with the progress bar and "S1 · E3" on it.
            return Stack(
              fit: StackFit.expand,
              children: [
                EpisodeBackdrop(image: hasPoster && !isSvg ? posterUrl : null),
                if (hasPoster && !isSvg)
                  // Faded as it's drawn, not with a ShaderMask: that drew
                  // each card to a layer of its own on every frame — some
                  // four at once in Continue Watching, still drawn under a
                  // details page as it slides in, where they cost a Galaxy
                  // S25 Ultra frames.
                  FadingCoverImage(
                    url: posterUrl,
                    cacheHeight: decodeHeight,
                    alignment: Alignment.topCenter,
                    fadeFrom: 0.68,
                    fadeTo: 0.88,
                  )
                else
                  ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0, 0.68, 0.88],
                    ).createShader(rect),
                    child: image,
                  ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  // One text line high whether or not there's an "S1 · E3"
                  // in it, so the bar sits at the same height on movie and
                  // show cards side by side.
                  height: MediaQuery.textScalerOf(context).scale(11) * 1.2,
                  child: Row(
                    children: [
                      if (hasProgress)
                        Expanded(
                          child: Container(
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
                          ),
                        ),
                      if (showBadge) ...[
                        if (hasProgress) const SizedBox(width: 6),
                        Text(
                          'S$currentSeason · E$currentEpisode',
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            fontWeight: FontWeight.w500,
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );

    // If height is infinite (e.g. in GridView), we want the image to take available space
    // minus the text height.
    // Only with the title: it's what puts the image in a Column. Without one
    // the grid cell's own size bounds it, and Expanded outside a Column
    // broke the layout (the person sheet's grid of their films).
    imageContent = _zoomed(imageContent);
    // On a TV: the remote selects the picture (it grows, as under a mouse)
    // and OK opens it.
    imageContent = TvFocusable(
      onPressed: widget.onTap,
      borderRadius: 8,
      onFocusChange: (focused) => _hovered.value = focused,
      child: imageContent,
    );
    if (widget.height == double.infinity && widget.showTitle) {
      imageContent = Expanded(child: imageContent);
    }

    if (!widget.showTitle) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _hovered.value = true,
        onExit: (_) => _hovered.value = false,
        child: GestureDetector(
          onTapDown: _prefetchDetails,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: imageContent,
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hovered.value = true,
      onExit: (_) => _hovered.value = false,
      child: GestureDetector(
        onTapDown: _prefetchDetails,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            imageContent,
            if (widget.showTitle) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: widget.width == double.infinity ? null : widget.width,
                child: Text(
                  widget.movie.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white70,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
