import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'artwork_glow.dart';
import 'glass_blur.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../theme/app_theme.dart';
import 'image_precache.dart';

class MovieHeroBanner extends StatelessWidget {
  final Movie movie;
  final VoidCallback onInfo;
  /// Null hides the Trailer button (no trailer for this title).
  final VoidCallback? onTrailer;
  final ScrollController? scrollController;

  /// Where [movie] stands in TMDB's weekly trending list (1 = top), for the
  /// "#3 Trending This Week" line; 0 or less hides it.
  final int trendingRank;

  const MovieHeroBanner({
    super.key,
    required this.movie,
    required this.onInfo,
    this.onTrailer,
    this.scrollController,
    this.trendingRank = 0,
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

  /// Downloads and decodes [movie]'s backdrop and logo as the banner will
  /// request them, so they paint on its first frame.
  static Future<void> precache(BuildContext context, Movie movie) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final screen = MediaQuery.sizeOf(context);
    final decode = _decodeSize(movie, screen, dpr);
    return Future.wait([
      precacheNetworkImage(context, _imageFor(movie, screen),
          cacheWidth: decode.width, cacheHeight: decode.height),
      precacheNetworkImage(context, _logoUrlFor(movie),
          cacheHeight: (_logoHeight * dpr).toInt()),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: Stack(
        fit: StackFit.expand,
        // The background runs on below the banner (see _glowBelow).
        clipBehavior: Clip.none,
        children: [
          // Background image, glow and shading, with parallax: the subtree
          // is built once (`child`), so scrolling just moves it.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _height + _glowBelow,
            child: scrollController != null
                ? ListenableBuilder(
                    listenable: scrollController!,
                    builder: (context, child) {
                      double offset = 0;
                      if (scrollController!.hasClients) {
                        offset = scrollController!.offset;
                      }
                      return Transform.translate(
                        offset: Offset(0, offset * 0.5),
                        child: child,
                      );
                    },
                    child: _buildBackground(context),
                  )
                : _buildBackground(context),
          ),

          // Content, Apple TV style: low on the picture, close together —
          // logo, a line of what it is, its trending rank, then the buttons.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Title or Logo
                  if (movie.logoUrl != null)
                    _buildLogo(context)
                        .animate()
                        .fadeIn(duration: 600.ms)
                        .slideY(begin: 0.2, end: 0)
                  else
                    Text(
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
                        )
                        .animate()
                        .fadeIn(duration: 600.ms)
                        .slideY(begin: 0.2, end: 0),

                  const SizedBox(height: 12),
                  _buildMetaLine().animate().fadeIn(delay: 200.ms),
                  if (trendingRank > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '#$trendingRank Trending This Week',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ).animate().fadeIn(delay: 250.ms),
                  ],
                  const SizedBox(height: 16),

                  // Buttons: More Info, then round Trailer and Like.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: onInfo,
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
                      // The same frosted circles as the details page's
                      // Trailer and Like (not grouped: they scroll up under
                      // the app bar's glass).
                      if (onTrailer != null) ...[
                        const SizedBox(width: 12),
                        GlassActionButton(
                          width: 50,
                          onTap: onTrailer!,
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
                          final liked =
                              SavedMoviesService().isFavorite(movie.id);
                          return GlassActionButton(
                            width: 50,
                            onTap: () =>
                                SavedMoviesService().toggleFavorite(movie),
                            child: Icon(
                              liked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: liked
                                  ? AppTheme.primaryColor
                                  : Colors.white,
                              semanticLabel: liked ? 'Unlike' : 'Like',
                            ),
                          );
                        },
                      ),
                    ],
                  ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.2, end: 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the title is, Apple TV style: "TV Show · Drama · Comedy · TV-14"
  /// — the rating only when known.
  Widget _buildMetaLine() {
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

  Widget _buildLogo(BuildContext context) {
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
      errorWidget: (context, url, error) => Text(
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
      ).animate().fadeIn(delay: 1000.ms),
    );
  }

  /// How far below the banner its glow (see ArtworkGlow) runs before it has
  /// faded to black: behind its buttons and the row heading after it, as
  /// the details page's runs on behind its synopsis.
  static const double _glowBelow = 140;

  /// The banner's background, [_height] + [_glowBelow] tall: the picture
  /// melting into a wash of its own colours (as on the details page), and
  /// the shading that keeps the logo and buttons readable over it and then
  /// fades it all to black.
  Widget _buildBackground(BuildContext context) {
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
              : ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.transparent],
                    stops: [0, 0.55, 1],
                  ).createShader(rect),
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    // A tall poster loses its bottom rather than its top:
                    // that's under the logo and buttons.
                    alignment: poster
                        ? const Alignment(0, -0.4)
                        : Alignment.topCenter,
                    memCacheWidth: decode.width,
                    memCacheHeight: decode.height,
                  ),
                ),
        ),
        // Darker where the logo and buttons sit over the glow, then black
        // by the end of the row heading below the banner.
        const DecoratedBox(
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
        ),
      ],
    );
  }
}
