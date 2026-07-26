import 'package:flutter/material.dart';
import 'dart:io';

import 'web_player_platform_interface.dart';
import 'web_player_mobile.dart';
import 'web_player_windows.dart';
import 'web_player_stub.dart';

import '../../models/movie.dart';

Widget createWebPlayer(
  String url,
  VoidCallback onClose,
  Movie movie,
  int? season,
  int? episode,
  List<Episode> episodes,
  List<Season>? seasons,
  Movie details,
) {
  if (Platform.isAndroid || Platform.isIOS) {
    return WebPlayerMobile(
      initialUrl: url,
      onClose: onClose,
      movie: movie,
      season: season,
      episode: episode,
      episodes: episodes,
      seasons: seasons,
      details: details,
    );
  } else if (Platform.isWindows) {
    return WebPlayerWindows(
      initialUrl: url,
      onClose: onClose,
      movie: movie,
      season: season,
      episode: episode,
      episodes: episodes,
      seasons: seasons,
      details: details,
    );
  }
  return WebPlayerStub(
    initialUrl: url,
    onClose: onClose,
    movie: movie,
    season: season,
    episode: episode,
    episodes: episodes,
    seasons: seasons,
    details: details,
  );
}
