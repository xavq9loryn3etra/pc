import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'artwork_glow.dart';
import 'glass_blur.dart';
import 'hero_carousel.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../theme/app_theme.dart';
import 'image_precache.dart';

/// The phone home's hero: a slideshow of [movies] (see HeroCarousel), each
/// slide its picture with its logo, a line of what it is and its buttons
/// low on it, Apple TV style, and the dots under them. (No "#3 Trending
/// This Week" line: the owner took it out on every device, 24 Nov 2026.)
class MovieHeroBanner extends StatelessWidget {
  /// The slideshow's titles, in order; the first's details already loaded.
  final List<Movie> movies;
  final void Function(Movie movie) onInfo;

  /// A title's Trailer button (only titles with a trailer have one).
  final void Function(Movie movie) onTrailer;
  final ScrollController? scrollController;

  const MovieHeroBanner({
    super.key,
    required this.movies,
    required this.onInfo,
    required this.onTrailer,
    this.scrollController,
  });

  // The banner's images and decode sizes, shared by build() and
  // precache() so the preload warms exactly what the banner requests.
  static String _backdropUrlFor(Movie m) =>
      m.backdropHighRes ?? m.backdrop ?? m.posterUrl ?? '';
  static String? _logoUrlFor(Movie m) =>
      m.logoUrl == null ? null : (m.logoHighRes ?? m.logoUrl!);
  // Tall, as Apple TV's, with the content low on the picture.
  static const double _height = 620;
  static const double _backdropCacheHeight = 600; // slightly higher for hero
  static const double _logoHeight = 100;

  /// The dots' strip along the banner's bottom, the buttons above it.
  static const double _dotsHeight = 36;

  /// Whether the banner shows [m]'s textless poster rather than its
  /// backdrop: on a phone's tall banner, as the details page does (see
  /// DetailsScreen.usesPosterHeader) — a wide backdrop there shows only
  /// its middle, softly.
  static bool _usesPoster(Movie m, Size screen) =>
      m.textlessPoster != null && screen.width / _height < 1.2;

  static String _imageFor(Movie m, Size screen) => _usesPoster(m, screen)
      ? m.textlessPosterHighRes!
      : _backdropUrlFor(m);

  /// One side only: the poster by the screen's width, which it fills, a
  /// backdrop by height.
  static ({int? width, int? height}) _decodeSize(
          Movie m, Size screen, double dpr) =>
      _usesPoster(m, screen)
          ? (width: (screen.width * dpr).toInt(), height: null)
          : (width: null, height: (_backdropCacheHeight * dpr).toInt());

  /// Downloads and decodes [movie]'s backdrop, its glow and its logo as
  /// the banner will request them, so they paint on its first frame.
  static Future<void> precache(BuildContext context, Movie movie) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final screen = MediaQuery.sizeOf(context);
    final decode = _decodeSize(movie, screen, dpr);
    return Future.wait([
      precacheNetworkImage(context, _imageFor(movie, screen),
          cacheWidth: decode.width, cacheHeight: decode.height),
      ArtworkGlow.precache(context, _imageFor(movie, screen)),
      precacheNetworkImage(context, _logoUrlFor(movie),
          cacheHeight: (_logoHeight * dpr).toInt()),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final withDots = movies.length > 1;
    return HeroCarousel(
      movies: movies,
      scrollController: scrollController,
      // Holds still once it's mostly scrolled away.
      pauseAfterScroll: _height * 0.6,
      precache: precache,
      background: _buildBackground,
      content: (context, movie, slide) => _buildContent(
        context,
        movie,
        slide,
        // Clear of the dots; as before without them.
        bottom: withDots ? _dotsHeight / 2 + 30 : 8,
      ),
      layout: (context, strip, slides, dots) => SizedBox(
        height: _height,
        child: Stack(
          fit: StackFit.expand,
          // The background runs on below the banner (see _glowBelow).
          clipBehavior: Clip.none,
          children: [
            // The pictures, glow and shading, with parallax as the page
            // scrolls: built once (`child`), so scrolling just moves it.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _height + _glowBelow,
              child: _parallax(
                RepaintBoundary(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [strip, const _Shade()],
                  ),
                ),
              ),
            ),
            // The slides' logos and buttons, over the whole banner so it
            // can be swiped anywhere.
            slides,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _dotsHeight,
              child: Center(child: dots),
            ),
          ],
        ),
      ),
    );
  }

  Widget _parallax(Widget child) {
    final controller = scrollController;
    if (controller == null) return child;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, controller.hasClients ? controller.offset * 0.5 : 0),
        child: child,
      ),
      child: child,
    );
  }

  /// A slide's content, Apple TV style: low on the picture, close together
  /// — logo, a line of what it is, then the buttons.
  /// The first slide's make an entrance; the rest arrive with their slide.
  Widget _buildContent(
    BuildContext context,
    Movie movie,
    HeroSlide slide, {
    required double bottom,
  }) {
    final from = slide.entrance ? 0.0 : 1.0;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Title or Logo
            (movie.logoUrl != null
                    ? _buildLogo(context, movie)
                    : _buildTitle(movie))
                .animate(value: from)
                .fadeIn(duration: 600.ms)
                .slideY(begin: 0.2, end: 0),

            const SizedBox(height: 12),
            _buildMetaLine(movie).animate(value: from).fadeIn(delay: 200.ms),
            const SizedBox(height: 16),

            // Buttons: More Info, then round Trailer and Like.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  focusNode: slide.primaryFocus,
                  onPressed: () => onInfo(movie),
                  icon: const Icon(
                    Icons.info_outline_rounded,
                    color: Colors.black,
                    size: 26,
                  ),
                  label: const Text('More Info'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    fixedSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // The same frosted circles as the details page's Trailer
                // and Like (not grouped: they scroll up under the app bar's
                // glass).
                if (movie.trailerUrl != null) ...[
                  const SizedBox(width: 12),
                  GlassActionButton(
                    width: 50,
                    onTap: () => onTrailer(movie),
                    child: const Icon(
                      Icons.movie_creation_rounded,
                      color: Colors.white,
                      semanticLabel: 'Trailer',
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                ListenableBuilder(
                  listenable: SavedMoviesService(),
                  builder: (context, _) {
                    final liked = SavedMoviesService()
                        .isFavorite(movie.id, type: movie.type);
                    return GlassActionButton(
                      width: 50,
                      onTap: () => SavedMoviesService().toggleFavorite(movie),
                      child: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: liked ? AppTheme.accent : Colors.white,
                        semanticLabel: liked ? 'Unlike' : 'Like',
                      ),
                    );
                  },
                ),
              ],
            )
                .animate(value: from)
                .fadeIn(delay: 400.ms)
                .slideY(begin: 0.2, end: 0),
          ],
        ),
      ),
    );
  }

  /// What the title is, Apple TV style: "TV Show · Drama · Comedy · TV-14"
  /// — the rating only when known.
  Widget _buildMetaLine(Movie movie) {
    final parts = [
      movie.type == 'tv' ? 'TV Show' : 'Movie',
      ...?movie.genres?.take(2),
      if (movie.certification?.isNotEmpty ?? false) movie.certification!,
    ];
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildTitle(Movie movie) => Text(
        movie.title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 40,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
          shadows: [
            Shadow(
              color: Colors.black,
              blurRadius: 20,
              offset: Offset(0, 4),
            ),
          ],
        ),
      );

  Widget _buildLogo(BuildContext context, Movie movie) {
    final url = _logoUrlFor(movie)!;
    if (url.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        url,
        height: _logoHeight,
        fit: BoxFit.contain,
        placeholderBuilder: (context) => const SizedBox(height: _logoHeight),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      height: _logoHeight,
      memCacheHeight:
          (_logoHeight * MediaQuery.of(context).devicePixelRatio).toInt(),
      fit: BoxFit.contain,
      placeholder: (context, url) => const SizedBox(height: _logoHeight),
      // Wait 1 second before showing text if image fails/is missing
      errorWidget: (context, url, error) =>
          _buildTitle(movie).animate().fadeIn(delay: 1000.ms),
    );
  }

  /// How far below the banner its glow (see ArtworkGlow) runs before it has
  /// faded to black: behind its buttons and the row heading after it, as
  /// the details page's runs on behind its synopsis.
  static const double _glowBelow = 140;

  /// A slide's picture, [_height] + [_glowBelow] tall: the picture melting
  /// into a wash of its own colours (as on the details page). The shading
  /// over it is the banner's, over all the slides' (see _Shade).
  Widget _buildBackground(BuildContext context, Movie movie) {
    final screen = MediaQuery.sizeOf(context);
    final imageUrl = _imageFor(movie, screen);
    final poster = _usesPoster(movie, screen);
    final decode =
        _decodeSize(movie, screen, MediaQuery.devicePixelRatioOf(context));
    return Stack(
      fit: StackFit.expand,
      children: [
        ArtworkGlow(url: imageUrl),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _height,
          child: imageUrl.toLowerCase().endsWith('.svg')
              ? SvgPicture.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                )
              : FadingCoverImage(
                  url: imageUrl,
                  cacheWidth: decode.width,
                  cacheHeight: decode.height,
                  // A tall poster loses its bottom rather than its top:
                  // that's under the logo and buttons.
                  alignment:
                      poster ? const Alignment(0, -0.4) : Alignment.topCenter,
                ),
        ),
      ],
    );
  }
}

/// The shading over the banner's pictures: darker where the logo and
/// buttons sit over the glow, then black by the end of the row heading
/// below the banner.
class _Shade extends StatelessWidget {
  const _Shade();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.transparent,
            Color(0x73000000), // 45%
            Color(0xA6000000), // 65%
            Colors.black,
          ],
          stops: [0, 0.35, 0.62, 0.82, 1],
        ),
      ),
    );
  }
}
