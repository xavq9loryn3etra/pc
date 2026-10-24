import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';
import 'image_precache.dart';

class MovieHeroBanner extends StatelessWidget {
  final Movie movie;
  final VoidCallback onInfo;
  /// Null hides the Trailer button (no trailer for this title).
  final VoidCallback? onTrailer;
  final ScrollController? scrollController;

  const MovieHeroBanner({
    super.key,
    required this.movie,
    required this.onInfo,
    this.onTrailer,
    this.scrollController,
  });

  // The banner's images and decode heights, shared by build() and
  // precache() so the preload warms exactly what the banner requests.
  static String _backdropUrlFor(Movie m) =>
      m.backdropHighRes ?? m.backdrop ?? m.posterUrl ?? '';
  static String? _logoUrlFor(Movie m) =>
      m.logoUrl == null ? null : (m.logoHighRes ?? m.logoUrl!);
  static const double _backdropCacheHeight = 600; // slightly higher for hero
  static const double _logoHeight = 100;

  /// Downloads and decodes [movie]'s backdrop and logo as the banner will
  /// request them, so they paint on its first frame.
  static Future<void> precache(BuildContext context, Movie movie) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Future.wait([
      precacheNetworkImage(context, _backdropUrlFor(movie),
          cacheHeight: (_backdropCacheHeight * dpr).toInt()),
      precacheNetworkImage(context, _logoUrlFor(movie),
          cacheHeight: (_logoHeight * dpr).toInt()),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 500,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background Image with Parallax and Gradient
          if (scrollController != null)
            ListenableBuilder(
              listenable: scrollController!,
              builder: (context, child) {
                double offset = 0;
                if (scrollController!.hasClients) {
                  offset = scrollController!.offset;
                }
                return Transform.translate(
                  offset: Offset(0, offset * 0.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildBackgroundImage(context),
                      // Gradient Overlay (Fade to Black) - Moves with image
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black,
                            ],
                            stops: [0.0, 0.5, 1.0],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            )
          else
            Stack(
              fit: StackFit.expand,
              children: [
                _buildBackgroundImage(context),
                // Gradient Overlay
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black,
                      ],
                      stops: [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ],
            ),

          // Content
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Title
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

                  const SizedBox(height: 8),

                  // Genres / Metadata
                  Text(
                    '${movie.year} • ${movie.certification ?? "PG-13"}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ).animate().fadeIn(delay: 200.ms),

                  const SizedBox(height: 24),

                  // Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: onInfo,
                        icon: const Icon(
                          Icons.info_outline,
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
                      if (onTrailer != null) ...[
                        const SizedBox(width: 16),
                        // Frosted glass, same recipe as CustomAppBar/the
                        // floating nav bar: clip to the button's own rounded
                        // shape and blur what's behind it.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(30),
                          child: BackdropFilter(
                            // See mode_switcher_dialog.dart's comment — lower
                            // sigma to cut GPU cost on weaker/high-refresh-rate
                            // devices.
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: ElevatedButton.icon(
                              onPressed: onTrailer,
                              icon: const Icon(
                                Icons.movie_creation_outlined,
                                color: Colors.white,
                                size: 24,
                              ),
                              label: const Text('Trailer'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white10,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 32),
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
                          ),
                        ),
                      ],
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

  Widget _buildBackgroundImage(BuildContext context) {
    final imageUrl = _backdropUrlFor(movie);
    return imageUrl.toLowerCase().endsWith(
          '.svg',
        )
        ? SvgPicture.network(
            imageUrl,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          )
        : CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            memCacheHeight:
                (_backdropCacheHeight * MediaQuery.of(context).devicePixelRatio)
                    .toInt(),
          );
  }
}
