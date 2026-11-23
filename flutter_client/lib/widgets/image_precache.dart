import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Downloads and decodes [url] into Flutter's image cache, keyed exactly as
/// a CachedNetworkImage with the same memCacheWidth / memCacheHeight looks
/// it up, so that widget paints it on its first frame. SVGs render through
/// SvgPicture rather than the image cache: they're fetched into its own
/// cache instead. A failed image completes quietly and just loads (or
/// fails) in place.
Future<void> precacheNetworkImage(
  BuildContext context,
  String? url, {
  int? cacheWidth,
  int? cacheHeight,
}) async {
  if (url == null || url.isEmpty) return;
  // A title's logo is often an SVG: fetched into flutter_svg's cache, which
  // SvgPicture.network(url) reads — skipped, the hero's logo came in late,
  // after its slide.
  if (url.toLowerCase().endsWith('.svg')) {
    try {
      await SvgNetworkLoader(url).loadBytes(context);
    } catch (_) {}
    return;
  }
  await precacheImage(
    ResizeImage.resizeIfNeeded(
      cacheWidth,
      cacheHeight,
      CachedNetworkImageProvider(url),
    ),
    context,
    onError: (_, __) {},
  );
}
