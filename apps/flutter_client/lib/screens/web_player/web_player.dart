import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'web_player_platform_interface.dart';

// Conditional imports would be cleaner for web support, but for Android/Windows local logic,
// manual platform checks with separate files are robust enough if we ensure compilation.
// However, Dart doesn't support conditional exports based on OS at runtime in single file easily without conditional imports.
// We will use a simple factory that imports everything but only instantiates what's safe.
// Note: importing 'webview_windows' on Android might cause compile error if it has native deps?
// Actually, it usually just warns. But to be safe, we should use conditional imports.

import 'web_player_stub.dart' if (dart.library.io) 'web_player_io.dart';

import '../../models/movie.dart'; // Import Movie model

class WebPlayer extends StatelessWidget {
  final String url;
  final VoidCallback onClose;
  final Movie movie;
  final int? season;
  final int? episode;
  final List<Episode> episodes;
  final List<Season>? seasons;
  final Movie details;

  const WebPlayer({
    super.key,
    required this.url,
    required this.onClose,
    required this.movie,
    this.season,
    this.episode,
    this.episodes = const [],
    this.seasons,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return createWebPlayer(
      url,
      onClose,
      movie,
      season,
      episode,
      episodes,
      seasons,
      details,
    );
  }
}
