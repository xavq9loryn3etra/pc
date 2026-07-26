import 'package:flutter/material.dart';
import '../../models/movie.dart';

// Platform interface for WebPlayer

abstract class WebPlayerPlatform extends StatefulWidget {
  final String initialUrl;
  final VoidCallback onClose;
  final Movie movie;
  final int? season;
  final int? episode;
  final List<Episode> episodes;
  final List<Season>? seasons;
  final Movie details;

  const WebPlayerPlatform({
    super.key,
    required this.initialUrl,
    required this.onClose,
    required this.movie,
    this.season,
    this.episode,
    this.episodes = const [],
    this.seasons,
    required this.details,
  });
}
