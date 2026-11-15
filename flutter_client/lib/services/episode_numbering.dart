import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../models/movie.dart';
import 'tmdb_service.dart';

/// One of a show's episodes as IMDb numbers it (and so Torrentio, which
/// goes by IMDb), with the day it first aired.
@visibleForTesting
typedef ImdbEpisode = ({int season, int episode, DateTime? aired});

/// Turns TMDB's season and episode numbers — what the app's episode lists
/// show — into IMDb's, which the stream finders go by.
///
/// They're the same for most shows, but not all: long anime are split into
/// seasons differently. One Piece's Amazon Lily arc is TMDB's season 12,
/// its first episode numbered 408 (TMDB counts One Piece's episodes from
/// the very first); IMDb has that episode as season 13, episode 27. Asked
/// for season 12 episode 408, Torrentio had nothing: it couldn't be played.
///
/// IMDb's numbering comes from Cinemeta (Stremio's own catalogue, free and
/// keyless), which lists every episode with its season, number and air
/// date. An episode is matched by where it falls in the whole run, checked
/// against its air date.
class EpisodeNumbering {
  static final EpisodeNumbering _instance = EpisodeNumbering._();
  factory EpisodeNumbering() => _instance;
  EpisodeNumbering._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
  ));

  // Each show's IMDb episodes, in order, looked up once a session.
  final Map<String, Future<List<ImdbEpisode>?>> _shows = {};

  /// IMDb's season and episode for TMDB's [season] and [episode] of the
  /// show [tmdbId] ([imdbId] on IMDb). The numbers as given when they're
  /// IMDb's already, specials (season 0), or nothing better is known.
  Future<(int, int)> toImdb({
    required String imdbId,
    required String tmdbId,
    required int season,
    required int episode,
  }) async {
    if (season < 1) return (season, episode);
    try {
      final imdb = await _episodesOf(imdbId);
      if (imdb == null || imdb.isEmpty) return (season, episode);
      final tmdb = TMDBService();
      final details = await tmdb.getDetails(tmdbId, type: 'tv');
      final inSeason = await tmdb.getSeasonDetails(tmdbId, season);
      final index = inSeason.indexWhere((e) => e.episodeNumber == episode);
      if (details == null || index < 0) return (season, episode);
      final before = <int>[
        for (final s in details.seasons ?? const <Season>[])
          if (s.seasonNumber > 0 && s.seasonNumber < season)
            s.episodeCount ?? 0,
      ].fold<int>(0, (a, b) => a + b);
      final match = matchEpisode(
        imdb,
        season: season,
        episode: episode,
        position: before + index,
        aired: DateTime.tryParse(inSeason[index].airDate ?? ''),
      );
      return match ?? (season, episode);
    } catch (e) {
      debugPrint('[episodes] numbering lookup failed: $e');
      return (season, episode);
    }
  }

  /// [season] and [episode], TMDB's, in IMDb's numbering [imdb] (the
  /// show's regular episodes in order): the same numbers when IMDb has
  /// them airing then (or no date to go by); otherwise the episode at
  /// [position] (0-based, counted over the whole run) in IMDb's list, or
  /// failing that the one aired the same day nearest it. Within two days
  /// counts as the same day: Japan's evening is still the day before in
  /// some listings. Null when nothing matches.
  @visibleForTesting
  static (int, int)? matchEpisode(
    List<ImdbEpisode> imdb, {
    required int season,
    required int episode,
    required int position,
    DateTime? aired,
  }) {
    bool sameDay(DateTime? a) =>
        aired == null || a == null || a.difference(aired).inDays.abs() <= 2;

    final same = imdb
        .where((e) => e.season == season && e.episode == episode)
        .firstOrNull;
    if (same != null && sameDay(same.aired)) return (season, episode);

    if (position >= 0 && position < imdb.length) {
      final at = imdb[position];
      if (sameDay(at.aired)) return (at.season, at.episode);
    }
    if (aired == null) return null;
    ImdbEpisode? best;
    for (var i = 0; i < imdb.length; i++) {
      final e = imdb[i];
      if (e.aired == null || !sameDay(e.aired)) continue;
      if (best == null ||
          (i - position).abs() < (imdb.indexOf(best) - position).abs()) {
        best = e;
      }
    }
    return best == null ? null : (best.season, best.episode);
  }

  Future<List<ImdbEpisode>?> _episodesOf(String imdbId) =>
      _shows[imdbId] ??= _load(imdbId).catchError((Object e) {
        // Asked again next time rather than remembered.
        _shows.remove(imdbId);
        return null;
      });

  Future<List<ImdbEpisode>?> _load(String imdbId) async {
    final response = await _dio
        .get('https://v3-cinemeta.strem.io/meta/series/$imdbId.json');
    final videos = (response.data['meta'] as Map?)?['videos'] as List?;
    if (videos == null) return null;
    final episodes = <ImdbEpisode>[
      for (final v in videos)
        if (v is Map &&
            v['season'] is num &&
            v['episode'] is num &&
            (v['season'] as num) > 0)
          (
            season: (v['season'] as num).toInt(),
            episode: (v['episode'] as num).toInt(),
            aired: DateTime.tryParse('${v['released'] ?? v['firstAired']}'),
          ),
    ]..sort((a, b) => a.season != b.season
        ? a.season.compareTo(b.season)
        : a.episode.compareTo(b.episode));
    return episodes;
  }
}
