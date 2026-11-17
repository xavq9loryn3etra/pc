import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/audio_language_service.dart';
import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:flutter_client/services/sync/sync_bridge.dart';
import 'package:flutter_client/services/sync/sync_data.dart';
import 'package:flutter_client/services/sync/sync_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const day = 24 * 60 * 60 * 1000;
const now = 1800000000000; // Jan 2027

Movie movie(String id, {String type = 'movie'}) => Movie(
      id: id,
      title: 'Title $id',
      year: 2020,
      rating: '8',
      voteCount: 1,
      description: '',
      type: type,
      inCinemas: false,
    );

Map<String, dynamic> movieJson(String id, {String type = 'movie'}) =>
    movie(id, type: type).toStorageJson();

SyncData page({
  Map<String, Map<String, dynamic>> list = const {},
  Map<String, Map<String, dynamic>> history = const {},
  Map<String, Map<String, dynamic>> episodes = const {},
  Map<String, Map<String, dynamic>> settings = const {},
  Map<String, num> lengths = const {},
}) =>
    SyncData(items: {
      'list': list,
      'history': history,
      'episodes': episodes,
      'settings': settings,
    }, lengths: lengths);

Map<String, dynamic> on(int t, Object v) => {'t': t, 'v': v};
Map<String, dynamic> gone(int t) => {'t': t, 'removed': true};

Set<String> liveKeys(SyncData d, String section) =>
    d.live(section).map((e) => e.key).toSet();

void main() {
  group('merging pages', () {
    test('combines what each device has', () {
      final phone = page(list: {'movie_1': on(now - 10, movieJson('1'))});
      final tv = page(list: {'tv_2': on(now - 5, movieJson('2', type: 'tv'))});
      final merged = SyncData.merge([phone, tv], now: now);
      expect(liveKeys(merged, 'list'), {'movie_1', 'tv_2'});
    });

    test('a later removal wins over an earlier copy, a later re-add over it',
        () {
      final phone = page(list: {'movie_1': gone(now - 10)});
      final tv = page(list: {'movie_1': on(now - 20, movieJson('1'))});
      expect(liveKeys(SyncData.merge([phone, tv], now: now), 'list'), isEmpty);

      final laptop = page(list: {'movie_1': on(now - 5, movieJson('1'))});
      expect(liveKeys(SyncData.merge([phone, tv, laptop], now: now), 'list'),
          {'movie_1'});
    });

    test('gives the same result in any order, and again changes nothing', () {
      final a = page(
        list: {'movie_1': on(now - 10, movieJson('1')), 'movie_3': gone(now - 2)},
        episodes: {'tv_9_1_1': on(now - 30, 0.4)},
      );
      final b = page(
        list: {'movie_1': gone(now - 8), 'movie_3': on(now - 4, movieJson('3'))},
        episodes: {'tv_9_1_1': on(now - 20, 0.9)},
        lengths: {'tv_9_1_1': 2600},
      );
      final ab = SyncData.merge([a, b], now: now);
      final ba = SyncData.merge([b, a], now: now);
      expect(ab.sameAs(ba), isTrue);
      expect(SyncData.merge([ab, a, b], now: now).sameAs(ab), isTrue);
      expect(ab['episodes']['tv_9_1_1']!['v'], 0.9);
      expect(liveKeys(ab, 'list'), isEmpty);
    });

    test('settles a tie the same way on every device', () {
      final a = page(settings: {'player_subtitle_lang': on(now, 'si')});
      final b = page(settings: {'player_subtitle_lang': on(now, 'eng')});
      final ab = SyncData.merge([a, b], now: now);
      final ba = SyncData.merge([b, a], now: now);
      expect(ab['settings']['player_subtitle_lang'],
          ba['settings']['player_subtitle_lang']);
    });

    test("a clock that ran ahead can't win for months", () {
      final fast = page(list: {'movie_1': on(now + 365 * day, movieJson('1'))});
      final merged = SyncData.merge([fast], now: now);
      expect(SyncData.timeOf(merged['list']['movie_1']!), lessThan(now + day));

      final later = page(list: {'movie_1': gone(now + 60 * 60 * 1000)});
      expect(
          liveKeys(SyncData.merge([merged, later], now: now + 2 * 60 * 60 * 1000),
              'list'),
          isEmpty);
    });

    test('forgets removals after 180 days', () {
      final old = page(list: {
        'movie_1': gone(now - 200 * day),
        'movie_2': gone(now - 10 * day),
      });
      final merged = SyncData.merge([old], now: now);
      expect(merged['list'].keys, ['movie_2']);
    });

    test("a show taken off Continue Watching takes its earlier episodes' progress",
        () {
      final phone = page(history: {'tv_9': gone(now - 100)});
      final tv = page(
        history: {'tv_9': on(now - 500, {'movie': movieJson('9', type: 'tv')})},
        episodes: {
          'tv_9_1_1': on(now - 600, 0.5),
          'tv_9_1_2': on(now - 50, 0.2), // watched after the removal
          'tv_10_1_1': on(now - 600, 0.3),
        },
        lengths: {'tv_9_1_1': 2400, 'tv_10_1_1': 2500},
      );
      final merged = SyncData.merge([phone, tv], now: now);
      expect(merged['episodes'].keys.toSet(), {'tv_9_1_2', 'tv_10_1_1'});

      final allGone = SyncData.merge([
        phone,
        page(
          episodes: {'tv_9_1_1': on(now - 600, 0.5)},
          lengths: {'tv_9_1_1': 2400},
        ),
      ], now: now);
      expect(allGone.lengths.containsKey('tv_9_1_1'), isFalse);
    });

    test('carries along what a newer app version added', () {
      final json = {
        'format': 1,
        'something_new': {'a': 1},
        'list': {
          'movie_1': {
            't': now,
            'v': movieJson('1'),
            'extra_field': 'kept',
          },
          'broken': 'not an item',
        },
        'history': {},
        'episodes': {},
        'settings': {},
        'lengths': {'tv_1_1_1': 'not a number'},
      };
      final read = SyncData.fromJson(json);
      expect(read['list'].keys, ['movie_1']);
      expect(read.lengths, isEmpty);
      final merged = SyncData.merge([read], now: now);
      final written = merged.toJson();
      expect(written['something_new'], {'a': 1});
      expect((written['list'] as Map)['movie_1']['extra_field'], 'kept');
    });

    test('a page from a newer layout says so', () {
      final newer = SyncData.fromJson({'format': 2});
      expect(SyncData.merge([newer, page()], now: now).format, 2);
    });
  });

  group('reading the saved lists', () {
    setUp(() => SyncLedger().reset());

    test('things saved before sync lose to any real change, in list order', () {
      final ledger = SyncLedger();
      final data = SyncBridge.fromLocal(
        favorites: [movieJson('1'), movieJson('2'), movieJson('3')],
        history: {
          'movie_5': {'movie': movieJson('5'), 'last_watched': now - day},
        },
        episodes: {},
        lengths: {},
        settings: {'player_subtitle_lang': 'si'},
        ledger: ledger,
      );
      final t1 = SyncData.timeOf(data['list']['movie_1']!);
      final t3 = SyncData.timeOf(data['list']['movie_3']!);
      expect(t1, greaterThan(t3));
      expect(t1, lessThan(1000));
      expect(SyncData.timeOf(data['history']['movie_5']!), now - day);
      expect(SyncData.timeOf(data['settings']['player_subtitle_lang']!),
          lessThan(1000));
    });

    test('a removal recorded here is in the page, unless it was re-added', () {
      final ledger = SyncLedger()..remove('list', 'movie_1');
      ledger.remove('list', 'movie_2');
      ledger.touch('list', 'movie_2');
      final data = SyncBridge.fromLocal(
        favorites: [movieJson('2')],
        history: {},
        episodes: {},
        lengths: {},
        settings: {},
        ledger: ledger,
      );
      expect(SyncData.isRemoved(data['list']['movie_1']!), isTrue);
      expect(SyncData.isRemoved(data['list']['movie_2']!), isFalse);
    });
  });

  group('with the app', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SyncLedger().reset();
      await SavedMoviesService().init();
    });

    test("another device's list and removals arrive, and what's here stays",
        () async {
      final saved = SavedMoviesService();
      await saved.toggleFavorite(movie('1'));
      await saved.toggleFavorite(movie('2'));
      await saved.addToHistory(movie('7', type: 'tv'),
          season: 1, episode: 2, progress: 0.4);

      final here = await SyncBridge.gather();
      final t = SyncLedger().now();
      final other = page(
        list: {
          'movie_2': gone(t + 1000), // removed there, after it was added here
          'movie_3': on(t + 2000, movieJson('3')),
        },
        episodes: {'tv_7_1_3': on(t + 3000, 0.1)},
        settings: {'audio_language_tv_7': on(t + 3000, 'english')},
      );
      final merged = SyncData.merge([here, other], now: t + 5000);
      await SyncBridge.apply(merged);

      expect(saved.favorites.map((m) => m.storageKey), ['movie_3', 'movie_1']);
      expect(saved.getEpisodeProgress('7', 1, 2), 0.4);
      expect(saved.getEpisodeProgress('7', 1, 3), 0.1);
      expect(AudioLanguageService().of(movie('7', type: 'tv')),
          AudioLanguage.english);

      // This device's page now holds the same: nothing more to send.
      final again = await SyncBridge.gather();
      final m2 = SyncData.merge([again], now: t + 5000);
      expect(m2.sameAs(merged), isTrue);
    });

    test('a removal here is kept as one after a sync', () async {
      final saved = SavedMoviesService();
      final t = SyncLedger().now();
      await SyncBridge.apply(SyncData.merge([
        page(list: {'movie_4': on(t - 1000, movieJson('4'))})
      ], now: t));
      expect(saved.isFavorite('4', type: 'movie'), isTrue);

      await saved.toggleFavorite(movie('4'));
      final here = await SyncBridge.gather();
      final stale = page(list: {'movie_4': on(t - 1000, movieJson('4'))});
      await SyncBridge.apply(SyncData.merge([here, stale], now: t + 10));
      expect(saved.isFavorite('4', type: 'movie'), isFalse);
    });
  });
}
