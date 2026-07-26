import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/movie.dart';

class MovieHeroBanner extends StatelessWidget {
  final Movie movie;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final ScrollController? scrollController;

  const MovieHeroBanner({
    super.key,
    required this.movie,
    required this.onPlay,
    required this.onInfo,
    this.scrollController,
  });

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
                    (movie.logoUrl!.toLowerCase().endsWith('.svg')
                            ? SvgPicture.network(
                                movie.logoUrl!,
                                height: 100,
                                fit: BoxFit.contain,
                                placeholderBuilder: (context) =>
                                    const SizedBox(height: 100),
                              )
                            : CachedNetworkImage(
                                imageUrl: movie.logoUrl!,
                                height: 100,
                                fit: BoxFit.contain,
                                placeholder: (context, url) => const SizedBox(
                                  height: 100,
                                ), // Wait, don't show text
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
                              ))
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
                        onPressed: onPlay,
                        icon: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 28,
                        ),
                        label: const Text('Play'),
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
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: onInfo,
                        icon: const Icon(
                          Icons.info_outline,
                          color: Colors.white,
                          size: 28,
                        ),
                        label: const Text('More Info'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white10,
                          foregroundColor: Colors.white,
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

  Widget _buildBackgroundImage(BuildContext context) {
    return (movie.backdrop ?? movie.posterUrl ?? '').toLowerCase().endsWith(
          '.svg',
        )
        ? SvgPicture.network(
            movie.backdrop ?? movie.posterUrl ?? '',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          )
        : CachedNetworkImage(
            imageUrl: movie.backdrop ?? movie.posterUrl ?? '',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            memCacheHeight: (600 * MediaQuery.of(context).devicePixelRatio)
                .toInt(), // slightly higher for hero
          );
  }
}
