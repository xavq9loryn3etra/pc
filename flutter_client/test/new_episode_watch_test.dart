import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/new_episode_watch.dart';
import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:flutter_client/services/sync/sync_bridge.dart';
import 'package:flutter_client/services/sync/sync_data.dart';
import 'package:flutter_client/services/sync/sync_ledger.dart';
import 'package:flutter_client/services/tmdb_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const past = '2020-01-01';
const future = '2999-01-01';

Episode ep(int n, {String? aired}) => Episode(
      id: n,
      episodeNumber: n,
      name: 'Episode $n',
      overview: '',
      airDate: aired,
      voteAverage: 0,
    );

Movie show(String id, {bool anime = false}) => Movie(
      id: id,
      title: 'Show $id',
      year: 2020,
      rating: '8',
      voteCount: 1,
      description: '',
      type: 'tv',
      inCinemas: false,
      isAnime: anime,
    );

/// TMDB, answering from [seasons] (number → episodes).
class _FakeTmdb implements TMDBService {
  final Map<int, List<Episode>> seasons;
  _FakeTmdb(this.seasons);

  @override
  Future<({List<int> seasons, bool ended})?> showSeasons(String tvId) async =>
      (seasons: seasons.keys.toList()..sort(), ended: false);

  @override
  Future<List<Episode>> getSeasonDetails(String tvId, int seasonNumber) async =>
      seasons[seasonNumber] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('what comes next', () {
    test('the following season skips the specials and gaps', () {
      expect(NewEpisodeWatch.followingSeason(1, [0, 1, 2, 3]), 2);
      expect(NewEpisodeWatch.followingSeason(2, [3, 1, 5]), 3);
      expect(NewEpisodeWatch.followingSeason(3, [0, 1, 2, 3]), isNull);
    });

    test('the next episode in the season, once it has aired', () {
      final season = [ep(1, aired: past), ep(2, aired: past), ep(3, aired: future)];
      final aired = NewEpisodeWatch.nextAfter(
          season: 2, episode: 1, seasonEpisodes: season);
      expect(aired.state, NextEpisodeState.out);
      expect((aired.season, aired.episode), (2, 2));

      expect(
          NewEpisodeWatch.nextAfter(season: 2, episode: 2, seasonEpisodes: season)
              .state,
          NextEpisodeState.notYet);
    });

    test('an episode with no air date yet is not out', () {
      final season = [ep(1, aired: past), ep(2)];
      expect(
          NewEpisodeWatch.nextAfter(season: 1, episode: 1, seasonEpisodes: season)
              .state,
          NextEpisodeState.notYet);
    });

    test('a gap in the numbering goes to the next one there is', () {
      final season = [ep(1, aired: past), ep(4, aired: past)];
      final next = NewEpisodeWatch.nextAfter(
          season: 1, episode: 1, seasonEpisodes: season);
      expect((next.season, next.episode), (1, 4));
    });

    test("after a season's last: the next season's first, once it has aired",
        () {
      final season = [ep(1, aired: past), ep(2, aired: past)];
      NextEpisodeCheck after(List<Episode>? following) => NewEpisodeWatch.nextAfter(
            season: 1,
            episode: 2,
            seasonEpisodes: season,
            followingSeason: 2,
            followingEpisodes: following,
          );
      expect(after(null).state, NextEpisodeState.notYet);
      expect(after([]).state, NextEpisodeState.notYet);
      expect(after([ep(1, aired: future)]).state, NextEpisodeState.notYet);
      final out = after([ep(2, aired: past), ep(1, aired: past)]);
      expect(out.state, NextEpisodeState.out);
      expect((out.season, out.episode), (2, 1));
    });

    test('no later season: nothing yet', () {
      expect(
          NewEpisodeWatch.nextAfter(
                  season: 3, episode: 2, seasonEpisodes: [ep(1), ep(2)])
              .state,
          NextEpisodeState.notYet);
    });

    test("a season that couldn't be read: unknown", () {
      expect(
          NewEpisodeWatch.nextAfter(season: 1, episode: 1, seasonEpisodes: [])
              .state,
          NextEpisodeState.unknown);
    });
  });

  group('trimming', () {
    const now = 1800000000000;
    const day = 24 * 60 * 60 * 1000;

    test('shows waiting over two years go', () {
      final waiting = <String, dynamic>{
        'tv_1': {'since': now - 800 * day},
        'tv_2': {'since': now - 10 * day},
      };
      expect(NewEpisodeWatch.trim(waiting, now: now), {'tv_1'});
      expect(waiting.keys, ['tv_2']);
    });

    test('past the cap, the longest waiting go', () {
      final waiting = <String, dynamic>{
        for (var i = 0; i < NewEpisodeWatch.maxShows + 3; i++)
          'tv_$i': {'since': now - i * day},
      };
      final dropped = NewEpisodeWatch.trim(waiting, now: now);
      expect(waiting.length, NewEpisodeWatch.maxShows);
      expect(dropped, {
        for (var i = NewEpisodeWatch.maxShows; i < NewEpisodeWatch.maxShows + 3; i++)
          'tv_$i',
      });
    });
  });

  group('with the app', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SyncLedger().reset();
      NewEpisodeWatch().reset();
      await SavedMoviesService().init();
      await NewEpisodeWatch().init();
    });

    test('only a series waits, and not for a special', () async {
      final watch = NewEpisodeWatch();
      await watch.remember(
          Movie.fromStorageJson({...show('1').toStorageJson(), 'type': 'movie'}),
          season: 1,
          episode: 1);
      await watch.remember(show('2'), season: 0, episode: 3);
      expect(watch.waiting, isEmpty);
      await watch.remember(show('3'), season: 2, episode: 8);
      expect(watch.isWaiting('3'), isTrue);
    });

    test('kept across a restart', () async {
      await NewEpisodeWatch().remember(show('5'), season: 1, episode: 4);
      NewEpisodeWatch().reset();
      await NewEpisodeWatch().init();
      expect(NewEpisodeWatch().isWaiting('5'), isTrue);
    });

    test('watching the series again stops the wait', () async {
      final watch = NewEpisodeWatch();
      await watch.remember(show('4'), season: 1, episode: 6);
      await SavedMoviesService().addToHistory(show('4'), season: 1, episode: 1);
      expect(watch.isWaiting('4'), isFalse);
      expect(
          SyncData.isRemoved(
              (await SyncBridge.gather())[NewEpisodeWatch.section]['tv_4']!),
          isTrue);
    });

    test('a new episode out brings the series back, with no progress',
        () async {
      final history = SavedMoviesService();
      final watch = NewEpisodeWatch();
      await history.addToHistory(show('9', anime: true),
          season: 1, episode: 2, progress: 1.0);
      final kept = history.getMovieFromHistory('9', type: 'tv')!;
      await history.removeFromHistory('9', type: 'tv');
      await watch.remember(kept, season: 1, episode: 2);

      // Not out yet: still waiting.
      await watch.checkNow(
          tmdb: _FakeTmdb({
            1: [ep(1, aired: past), ep(2, aired: past)],
            2: [ep(1, aired: future)],
          }),
          ignoreSchedule: true);
      expect(watch.isWaiting('9'), isTrue);
      expect(history.getMovieFromHistory('9', type: 'tv'), isNull);

      // Out: back on Continue Watching at season 2 episode 1.
      await watch.checkNow(
          tmdb: _FakeTmdb({
            1: [ep(1, aired: past), ep(2, aired: past)],
            2: [ep(1, aired: past), ep(2, aired: future)],
          }),
          ignoreSchedule: true);
      expect(watch.isWaiting('9'), isFalse);
      final back = history.getMovieFromHistory('9', type: 'tv')!;
      expect((back.currentSeason, back.currentEpisode), (2, 1));
      expect(back.progress, isNull);
      expect(back.isAnime, isTrue);
      expect(history.history.first.storageKey, 'tv_9');
    });

    test('a series already back on Continue Watching stops waiting', () async {
      final watch = NewEpisodeWatch();
      await watch.remember(show('6'), season: 1, episode: 3);
      // Back from another device's sync, say (no addToHistory here).
      await SyncBridge.apply(SyncData.merge([
        await SyncBridge.gather(),
        SyncData(items: {
          'history': {
            'tv_6': {
              't': SyncLedger().now() + 10,
              'v': {
                'movie': show('6').toStorageJson(),
                'last_watched': SyncLedger().now(),
              },
            },
          },
        }),
      ], now: SyncLedger().now() + 20));
      expect(watch.isWaiting('6'), isTrue);
      await watch.checkNow(tmdb: _FakeTmdb({}), ignoreSchedule: true);
      expect(watch.isWaiting('6'), isFalse);
    });
  });

  group('sync', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SyncLedger().reset();
      NewEpisodeWatch().reset();
      await SavedMoviesService().init();
      await NewEpisodeWatch().init();
    });

    Map<String, dynamic> entry(String id) => {
          'movie': show(id).toStorageJson(),
          'season': 1,
          'episode': 5,
          'since': SyncLedger().now(),
        };

    test("another device's waiting series arrive, and its removals", () async {
      final watch = NewEpisodeWatch();
      await watch.remember(show('1'), season: 2, episode: 3);
      final t = SyncLedger().now();
      await SyncBridge.apply(SyncData.merge([
        await SyncBridge.gather(),
        SyncData(items: {
          NewEpisodeWatch.section: {
            'tv_2': {'t': t + 1, 'v': entry('2')},
          },
        }),
      ], now: t + 10));
      expect(watch.waiting.keys.toSet(), {'tv_1', 'tv_2'});

      await SyncBridge.apply(SyncData.merge([
        await SyncBridge.gather(),
        SyncData(items: {
          NewEpisodeWatch.section: {
            'tv_1': {'t': t + 20, 'removed': true},
          },
        }),
      ], now: t + 30));
      expect(watch.waiting.keys.toSet(), {'tv_2'});
    });

    test('a page without the section (an older app) changes nothing', () async {
      final watch = NewEpisodeWatch();
      await watch.remember(show('1'), season: 2, episode: 3);
      final older = SyncData.fromJson({
        'format': 1,
        'list': {},
        'history': {},
        'episodes': {},
        'settings': {},
      });
      await SyncBridge.apply(
          SyncData.merge([await SyncBridge.gather(), older],
              now: SyncLedger().now()));
      expect(watch.isWaiting('1'), isTrue);
    });

    test('signing out clears it', () async {
      await NewEpisodeWatch().remember(show('1'), season: 2, episode: 3);
      await SyncBridge.clearLocal();
      expect(NewEpisodeWatch().waiting, isEmpty);
    });
  });
}
