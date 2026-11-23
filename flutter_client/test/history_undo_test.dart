import 'dart:convert';

import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:flutter_client/services/sync/sync_bridge.dart';
import 'package:flutter_client/services/sync/sync_data.dart';
import 'package:flutter_client/services/sync/sync_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Movie _show() => Movie(
      id: '1399',
      title: 'A Show',
      year: 2011,
      rating: '8',
      voteCount: 1,
      description: '',
      type: 'tv',
      inCinemas: false,
      imdbId: 'tt0944947',
    );

Movie _film() => Movie(
      id: '1399',
      title: 'A Film With The Same Id',
      year: 2020,
      rating: '7',
      voteCount: 1,
      description: '',
      type: 'movie',
      inCinemas: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // The copies it last played (see LastPlayedTorrents).
      'last_played_torrent_1399_1_2': 'abc',
      'last_played_language_1399_1_2': 'original',
      'last_played_torrent_tt0944947_1_2': 'def',
      // Another title's: not its to take or bring back.
      'last_played_torrent_13990': 'zzz',
    });
    SyncLedger().reset();
    await SavedMoviesService().init();
  });

  Future<Map<String, dynamic>> stored(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>;
  }

  test('Undo brings a removed show back exactly, episodes and all', () async {
    final service = SavedMoviesService();
    await service.addToHistory(_show(), season: 1, episode: 1, progress: 0.9);
    await service.addToHistory(_show(), season: 1, episode: 2, progress: 0.4);
    await service.addToHistory(_film(), progress: 0.3);
    await service.saveEpisodeLength('1399', 1, 2, const Duration(minutes: 55));
    await service.flush();

    final beforeHistory = await stored('watch_history_v1');
    final beforeEpisodes = await stored('episode_history_v1');
    final beforeLengths = await stored('episode_lengths_v1');

    final snapshot = await service.snapshotHistory('1399', type: 'tv');
    expect(snapshot, isNotNull);
    await service.removeFromHistory('1399', type: 'tv');

    expect(service.getMovieFromHistory('1399', type: 'tv'), isNull);
    expect(service.getEpisodeProgress('1399', 1, 1), isNull);
    expect(SyncLedger().removedIn('history'), contains('tv_1399'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('last_played_torrent_1399_1_2'), isNull);
    expect(prefs.getString('last_played_torrent_tt0944947_1_2'), isNull);

    await service.restoreHistory(snapshot!);

    final back = service.getMovieFromHistory('1399', type: 'tv')!;
    expect(back.currentSeason, 1);
    expect(back.currentEpisode, 2);
    expect(back.progress, 0.4);
    expect(service.getEpisodeProgress('1399', 1, 1), 0.9);
    expect(service.getEpisodeProgress('1399', 1, 2), 0.4);
    expect(service.getEpisodeMinutes('1399', 1, 2), 55);
    // The film with the same id was never touched.
    expect(service.getMovieFromHistory('1399', type: 'movie')?.progress, 0.3);

    // Stored exactly as before, its place in the row (last watched) too.
    expect(await stored('watch_history_v1'), beforeHistory);
    expect(await stored('episode_history_v1'), beforeEpisodes);
    expect(await stored('episode_lengths_v1'), beforeLengths);
    expect(prefs.getString('last_played_torrent_1399_1_2'), 'abc');
    expect(prefs.getString('last_played_language_1399_1_2'), 'original');
    expect(prefs.getString('last_played_torrent_tt0944947_1_2'), 'def');
    expect(prefs.getString('last_played_torrent_13990'), 'zzz');
  });

  test('Undo is recorded as a fresh change, so sync spreads it', () async {
    final service = SavedMoviesService();
    await service.addToHistory(_show(), season: 1, episode: 1, progress: 0.5);
    final snapshot = await service.snapshotHistory('1399', type: 'tv');
    await service.removeFromHistory('1399', type: 'tv');
    final removedAt = SyncLedger().removedIn('history')['tv_1399']!;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await service.restoreHistory(snapshot!);

    final ledger = SyncLedger();
    expect(ledger.removedIn('history'), isNot(contains('tv_1399')));
    expect(ledger.changedAt('history', 'tv_1399'), greaterThan(removedAt));
    expect(ledger.changedAt('episodes', 'tv_1399_1_1'), greaterThan(removedAt));
    expect(ledger.removedIn('settings'),
        isNot(contains('last_played_torrent_1399_1_2')));

    // This device's page now beats the removal another device took in:
    // merged, the show and its episode are back.
    final saved = service.exportForSync();
    final page = SyncBridge.fromLocal(
      favorites: saved.favorites,
      history: saved.history,
      episodes: saved.episodes,
      lengths: saved.lengths,
      settings: const {},
      ledger: ledger,
    );
    final otherDevice = SyncData(items: {
      'history': {
        'tv_1399': {'t': removedAt, 'removed': true},
      },
    });
    final merged =
        SyncData.merge([otherDevice, page], now: ledger.now() + 1000);
    expect(SyncData.isRemoved(merged['history']['tv_1399']!), isFalse);
    expect(merged['episodes']['tv_1399_1_1']?['v'], 0.5);
  });

  test('no snapshot for a title not in history', () async {
    expect(await SavedMoviesService().snapshotHistory('42', type: 'movie'),
        isNull);
  });
}
