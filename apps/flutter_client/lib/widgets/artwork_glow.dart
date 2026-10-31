import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'image_precache.dart';

/// A title's artwork as a soft wash of its colours, Apple TV style: what
/// the details page's header and the home hero melt their picture into,
/// under their title and buttons. Blurred by decoding the image tiny and
/// stretching it — the same stand-in for a live blur as EpisodeBackdrop —
/// so scrolling costs nothing. Not colour-boosted like the glass: it's
/// background to buttons, and vivid colours competed with them.
class ArtworkGlow extends StatelessWidget {
  final String url;

  const ArtworkGlow({super.key, required this.url});

  // So few pixels that no shapes survive the stretch, only the colours:
  // at 24, figures and spots still showed through.
  static const _decodeWidth = 6;

  /// Decodes [url]'s glow into the image cache, keyed as the widget looks
  /// it up, so it paints on its first frame. Worth doing ahead: the tiny
  /// result still means decoding the whole full-size picture, ~100ms on a
  /// Galaxy S10, which otherwise landed as the page appeared.
  static Future<void> precache(BuildContext context, String url) =>
      precacheNetworkImage(context, url, cacheWidth: _decodeWidth);

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty || url.toLowerCase().endsWith('.svg')) {
      return const SizedBox.shrink();
    }
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: _decodeWidth,
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

/// [url]'s picture covering its box (as BoxFit.cover at [alignment]) and
/// fading out from [fadeFrom] of the way down to nothing at the bottom —
/// how the hero headers melt their picture into an [ArtworkGlow] under
/// it. Decoded at [cacheWidth] / [cacheHeight], keyed as a CachedNetworkImage
/// of that size (see precacheNetworkImage).
///
/// Drawn in one pass, the fade carried by the corners of the shape the
/// picture is drawn on. A ShaderMask did the same by drawing the picture
/// to an offscreen layer and masking that, on every frame it showed —
/// the bulk of the stutter as a details page appeared, and a cost on every
/// frame of scrolling.
class FadingCoverImage extends StatefulWidget {
  final String url;
  final int? cacheWidth;
  final int? cacheHeight;
  final Alignment alignment;
  final double fadeFrom;

  const FadingCoverImage({
    super.key,
    required this.url,
    this.cacheWidth,
    this.cacheHeight,
    this.alignment = Alignment.center,
    this.fadeFrom = 0.55,
  });

  @override
  State<FadingCoverImage> createState() => _FadingCoverImageState();
}

class _FadingCoverImageState extends State<FadingCoverImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  late final _listener = ImageStreamListener(
    (info, _) {
      if (!mounted) {
        info.dispose();
        return;
      }
      setState(() {
        _info?.dispose();
        _info = info;
      });
    },
    // Fails quietly: the glow under it shows on its own.
    onError: (_, __) {},
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(FadingCoverImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.cacheWidth != widget.cacheWidth ||
        old.cacheHeight != widget.cacheHeight) {
      _resolve();
    }
  }

  void _resolve() {
    final stream = ResizeImage.resizeIfNeeded(
      widget.cacheWidth,
      widget.cacheHeight,
      CachedNetworkImageProvider(widget.url),
    ).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _info?.image;
    if (image == null) return const SizedBox.expand();
    return CustomPaint(
      size: Size.infinite,
      painter: _FadingCoverPainter(image, widget.alignment, widget.fadeFrom),
    );
  }
}

class _FadingCoverPainter extends CustomPainter {
  final ui.Image image;
  final Alignment alignment;
  final double fadeFrom;

  _FadingCoverPainter(this.image, this.alignment, this.fadeFrom);

  // The fade, top to bottom: (fraction of the height, opacity).
  List<(double, double)> get _stops => [(0, 1), (fadeFrom, 1), (1, 0)];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, imageSize, size);
    // The part of the picture that covers the box.
    final source = alignment.inscribe(fitted.source, Offset.zero & imageSize);

    // Two vertices (left, right) per stop; a quad between each pair of
    // stops. Each vertex's colour carries the fade's opacity there, which
    // the GPU blends smoothly between them.
    final positions = <Offset>[];
    final textureCoordinates = <Offset>[];
    final colors = <Color>[];
    for (final (at, opacity) in _stops) {
      final y = size.height * at;
      final sourceY = source.top + source.height * at;
      final color = Colors.white.withValues(alpha: opacity);
      positions.addAll([Offset(0, y), Offset(size.width, y)]);
      textureCoordinates
          .addAll([Offset(source.left, sourceY), Offset(source.right, sourceY)]);
      colors.addAll([color, color]);
    }
    final indices = <int>[
      for (var i = 0; i < _stops.length - 1; i++) ...[
        2 * i, 2 * i + 1, 2 * i + 2, //
        2 * i + 1, 2 * i + 3, 2 * i + 2,
      ],
    ];
    final vertices = ui.Vertices(
      VertexMode.triangles,
      positions,
      textureCoordinates: textureCoordinates,
      colors: colors,
      indices: indices,
    );
    final paint = Paint()
      ..shader = ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
        // Not medium: it's decoded at the size it's shown, and medium has
        // the GPU build scaled-down copies of the whole picture on upload.
        filterQuality: FilterQuality.low,
      );
    // Modulate: the picture's colour times the vertex colour — white at
    // the fade's opacity.
    canvas.drawVertices(vertices, BlendMode.modulate, paint);
    vertices.dispose();
  }

  @override
  bool shouldRepaint(_FadingCoverPainter old) =>
      old.image != image ||
      old.alignment != alignment ||
      old.fadeFrom != fadeFrom;
}
