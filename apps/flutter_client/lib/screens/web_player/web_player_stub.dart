import 'package:flutter/material.dart';
import 'web_player_platform_interface.dart';
import '../../models/movie.dart';

class WebPlayerStub extends WebPlayerPlatform {
  const WebPlayerStub({
    super.key,
    required super.initialUrl,
    required super.onClose,
    required super.movie,
    super.season,
    super.episode,
    super.episodes,
    super.seasons,
    required super.details,
  });

  @override
  State<WebPlayerStub> createState() => _WebPlayerStubState();
}

class _WebPlayerStubState extends State<WebPlayerStub> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Not Supported')),
      body: const Center(
        child: Text(
          'WebView not supported on this platform',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

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

