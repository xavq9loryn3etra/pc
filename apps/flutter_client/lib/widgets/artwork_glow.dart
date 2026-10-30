import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// A title's artwork as a soft wash of its colours, Apple TV style: what
/// the details page's header and the home hero melt their picture into,
/// under their title and buttons. Blurred by decoding the image tiny and
/// stretching it — the same stand-in for a live blur as EpisodeBackdrop —
/// so scrolling costs nothing. Not colour-boosted like the glass: it's
/// background to buttons, and vivid colours competed with them.
class ArtworkGlow extends StatelessWidget {
  final String url;

  const ArtworkGlow({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty || url.toLowerCase().endsWith('.svg')) {
      return const SizedBox.shrink();
    }
    return CachedNetworkImage(
      imageUrl: url,
      // So few pixels that no shapes survive the stretch, only the
      // colours: at 24, figures and spots still showed through.
      memCacheWidth: 6,
      fit: BoxFit.cover,
      // Smooth (bicubic) upscaling turns the tiny decode into a soft blur
      // rather than visible blocks.
      filterQuality: FilterQuality.high,
      fadeInDuration: Duration.zero,
      placeholder: (_, __) => const SizedBox.shrink(),
      errorWidget: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}
