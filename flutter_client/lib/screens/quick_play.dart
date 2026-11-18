import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../services/tmdb_service.dart';
import '../services/torrent/last_played_torrents.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/torrent/torrent_download_registry.dart';
import '../services/torrent/free_space.dart';
import '../widgets/app_message.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/player_route.dart';
import 'player_screen.dart';

/// Continue Watching's play button: straight into the player with what
/// Resume would play — the film, or the series' episode being watched —
/// from the copy it was last watched in (else the one Play would pick),
/// with no title page or quality popup on the way: a small "Starting…"
/// card over the home, which Cancel (or a tap outside) gives up.
Future<void> quickPlay(BuildContext context, Movie movie) async {
  var cancelled = false;
  final navigator = Navigator.of(context, rootNavigator: true);
  final status = ValueNotifier<String>('Getting it ready…');
  var cardOpen = true;
  final card = showGlassDialog<void>(
    context,
    builder: (dialogContext) => _StartingCard(
      title: movie.title,
      status: status,
      onCancel: () => Navigator.pop(dialogContext),
    ),
  ).whenComplete(() {
    cardOpen = false;
    cancelled = true;
  });
  void closeCard() {
    if (cardOpen) {
      cardOpen = false;
      navigator.pop();
    }
  }

  void fail(String message) {
    closeCard();
    if (context.mounted) showAppMessage(context, message, error: true);
  }

  try {
    final isTv = movie.type == 'tv';
    final details = await TMDBService().getDetails(movie.id, type: movie.type);
    if (cancelled) return;
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
    if (cancelled) return;
    final target = isTv
        ? episodes.where((e) => e.episodeNumber == episode).firstOrNull
        : null;
    if (isTv ? (target?.isUnreleased ?? false) : details.isUnreleased) {
      return fail("${movie.title} isn't out yet.");
    }

    status.value = isTv ? 'Starting S$season E$episode…' : 'Starting…';
    final imdbId = details.imdbId ?? details.id;
    final resolver = StreamResolver();
    final streams = await resolver.getAvailableStreams(
      imdbId: imdbId,
      type: details.type,
      season: season,
      episode: episode,
      title: details,
    );
    if (cancelled) return;
    if (streams.isEmpty) {
      return fail("Couldn't find a copy of ${movie.title} to play right now.");
    }

    final prefs = await SharedPreferences.getInstance();
    final key = isTv
        ? 'last_played_torrent_${imdbId}_${season}_$episode'
        : 'last_played_torrent_$imdbId';
    final lastPlayed = await LastPlayedTorrents.lastPlayed(prefs, key, details);
    final pick = StreamResolver.likelyPick(streams, lastPlayedHash: lastPlayed)!;

    status.value = 'Connecting…';
    final StreamResolveResult resolved;
    try {
      // The copy, then the others of its quality, as the popup's pick.
      resolved = await resolver.resolveWithFallback(
        pick,
        StreamResolver.sameQuality(pick, streams),
        isCancelled: () => cancelled,
        title: details,
      );
    } on ResolveCancelledException {
      return;
    } on TimeoutException {
      return fail('Too few people are sharing ${movie.title} right now. '
          'Try again in a little while, or pick a quality on its page.');
    }
    if (cancelled) {
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
    if (cancelled) {
      resolver.pause(resolved.result.torrentId);
      return;
    }

    closeCard();
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
    if (!cancelled) {
      fail("Couldn't start ${movie.title}. Try again, or pick a quality on "
          'its page.');
    }
  } finally {
    // Shown until the player's up (or it's given up).
    unawaited(card.then((_) => status.dispose()));
  }
}

/// The "Starting…" card: the title, what's happening, a spinner, Cancel.
class _StartingCard extends StatelessWidget {
  final String title;
  final ValueListenable<String> status;
  final VoidCallback onCancel;

  const _StartingCard({
    required this.title,
    required this.status,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: Colors.white),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (context, text, _) => Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: GlassDialogButton(label: 'Cancel', onTap: onCancel),
          ),
        ],
      ),
    );
  }
}
