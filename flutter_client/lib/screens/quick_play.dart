import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../services/tmdb_service.dart';
import '../services/torrent/last_played_torrents.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/torrent/torrent_download_registry.dart';
import '../services/torrent/free_space.dart';
import '../services/quick_play_state.dart';
import '../widgets/app_message.dart';
import '../widgets/player_route.dart';
import 'player_screen.dart';

/// The start under way (see quickPlay): pressing play again, or on
/// another card, gives it up.
Object? _starting;

/// Continue Watching's play button: straight into the player with what
/// Resume would play — the film, or the series' episode being watched —
/// from the copy it was last watched in (else the one Play would pick),
/// with no title page or quality popup on the way. Meanwhile the card's
/// play button turns into a loading ring (quickPlayStarting), no popup:
/// pressing it again gives up. Only a failure is said.
Future<void> quickPlay(BuildContext context, Movie movie) async {
  final key = movie.storageKey;
  if (quickPlayStarting.value == key) {
    // Pressed again while starting: given up.
    _starting = null;
    quickPlayStarting.value = null;
    return;
  }
  final token = Object();
  _starting = token;
  quickPlayStarting.value = key;
  bool cancelledNow() => _starting != token;
  final navigator = Navigator.of(context, rootNavigator: true);
  void done() {
    if (_starting == token) {
      _starting = null;
      quickPlayStarting.value = null;
    }
  }

  void fail(String message) {
    final shown = !cancelledNow();
    done();
    if (shown && context.mounted) showAppMessage(context, message, error: true);
  }

  try {
    final isTv = movie.type == 'tv';
    final details = await TMDBService().getDetails(movie.id, type: movie.type);
    if (cancelledNow()) return;
    if (details == null) {
      return fail("Couldn't load ${movie.title}. Check your connection.");
    }
    final saved =
        SavedMoviesService().getMovieFromHistory(movie.id, type: movie.type);
    final season = isTv ? saved?.currentSeason ?? 1 : null;
    final episode = isTv ? saved?.currentEpisode ?? 1 : null;
    final episodes = isTv
        ? await TMDBService().getSeasonDetails(details.id, season!)
        : const <Episode>[];
    if (cancelledNow()) return;
    final target = isTv
        ? episodes.where((e) => e.episodeNumber == episode).firstOrNull
        : null;
    if (isTv ? (target?.isUnreleased ?? false) : details.isUnreleased) {
      return fail("${movie.title} isn't out yet.");
    }

    final imdbId = details.imdbId ?? details.id;
    final resolver = StreamResolver();
    final streams = await resolver.getAvailableStreams(
      imdbId: imdbId,
      type: details.type,
      season: season,
      episode: episode,
      title: details,
    );
    if (cancelledNow()) return;
    if (streams.isEmpty) {
      return fail("Couldn't find a copy of ${movie.title} to play right now.");
    }

    final prefs = await SharedPreferences.getInstance();
    final key = isTv
        ? 'last_played_torrent_${imdbId}_${season}_$episode'
        : 'last_played_torrent_$imdbId';
    final lastPlayed = await LastPlayedTorrents.lastPlayed(prefs, key, details);
    final pick = StreamResolver.likelyPick(streams, lastPlayedHash: lastPlayed)!;

    final StreamResolveResult resolved;
    try {
      // The copy, then the others of its quality, as the popup's pick.
      resolved = await resolver.resolveWithFallback(
        pick,
        StreamResolver.sameQuality(pick, streams),
        isCancelled: cancelledNow,
        title: details,
      );
    } on ResolveCancelledException {
      return;
    } on TimeoutException {
      return fail('Too few people are sharing ${movie.title} right now. '
          'Try again in a little while, or pick a quality on its page.');
    }
    if (cancelledNow()) {
      resolver.pause(resolved.result.torrentId);
      return;
    }

    // As the popup does: the copy that played, for next time and for
    // Settings > Storage, and the title at the top of the history.
    await prefs.setString(key, resolved.stream.infoHash);
    await LastPlayedTorrents.rememberLanguage(prefs, key, details);
    await TorrentDownloadRegistry.save(
      resolved.stream.infoHash,
      TorrentDownloadInfo(
        movieId: movie.id,
        imdbId: imdbId,
        title: movie.title,
        image: movie.image,
        season: season,
        episode: episode,
        totalBytes: TorrentDownloadRegistry.parseSizeBytes(resolved.stream.size),
      ),
    );
    await SavedMoviesService()
        .addToHistory(movie, season: season, episode: episode);
    if (cancelledNow()) {
      resolver.pause(resolved.result.torrentId);
      return;
    }

    done();
    final result = resolved.result;
    await navigator.push(
      PlayerRoute(
        builder: (_) => PlayerScreen(
          url: result.streamUrl,
          torrentId: result.torrentId,
          streamId: result.streamId,
          selectedStream: resolved.stream,
          availableStreams: streams,
          movie: movie,
          details: details,
          season: season,
          episode: episode,
          episodes: episodes,
          rememberedCopy: lastPlayed != null &&
              resolved.stream.infoHash.toLowerCase() == lastPlayed.toLowerCase(),
        ),
      ),
    );
  } on NotEnoughSpaceException catch (e) {
    fail(e.toString());
  } catch (e) {
    debugPrint('Quick play failed: $e');
    fail("Couldn't start ${movie.title}. Try again, or pick a quality on "
        'its page.');
  } finally {
    done();
  }
}
