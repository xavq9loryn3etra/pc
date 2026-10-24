import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Downloads and decodes [url] into Flutter's image cache, keyed exactly as
/// a CachedNetworkImage with the same memCacheWidth / memCacheHeight looks
/// it up, so that widget paints it on its first frame. SVGs render through
/// SvgPicture rather than the image cache, so they're skipped; a failed
/// image completes quietly and just loads (or fails) in place.
Future<void> precacheNetworkImage(
  BuildContext context,
  String? url, {
  int? cacheWidth,
  int? cacheHeight,
}) async {
  if (url == null || url.isEmpty || url.toLowerCase().endsWith('.svg')) {
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
