import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/backup_service.dart';
import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _stored({
  required String id,
  required String title,
  String? type = 'tv',
  double progress = 0.5,
  int? season,
  int? episode,
}) =>
    {
      'id': id,
      'title': title,
      'year': 2011,
      'image': 'https://image.tmdb.org/t/p/w500/p.jpg',
      'backdrop': null,
      'rating': '8.4',
      'vote_count': 1234,
      'description': 'd',
      if (type != null) 'type': type,
      'in_cinemas': false,
      'release_date_raw': '2011-04-17',
      'trailer_url': null,
      'imdb_id': 'tt0944947',
      'current_season': season,
      'current_episode': episode,
      'progress': progress,
    };

// What an older build (before the storage key included the type) left in
// the prefs: a show and a movie share the id 1399, an episode is keyed by
// the bare id, and one entry has no stored type at all.
Map<String, Object> _oldPrefs() {
  final history = {
    '1399': {
      'movie': _stored(
          id: '1399', title: 'Game of Thrones', season: 2, episode: 3),
      'last_watched': 3000,
    },
    '603': {
      'movie': _stored(id: '603', title: 'The Matrix', type: 'movie'),
      'last_watched': 2000,
    },
    '777': {
      'movie': _stored(id: '777', title: 'Typeless', type: null),
      'last_watched': 1000,
    },
  };
  return {
    'watch_history_v1': jsonEncode(history),
    'episode_history_v1': jsonEncode({'1399_2_3': 0.4, '1399_1_1': 1.0}),
    'episode_lengths_v1': jsonEncode({'1399_2_3': 3300}),
    'favorites_v1': jsonEncode([
      _stored(id: '603', title: 'The Matrix', type: 'movie'),
      _stored(id: '1399', title: 'Game of Thrones'),
    ]),
    'selected_app_mode': 0,
    'has_seen_welcome': true,
    'last_played_torrent_1399': 'abc',
  };
}

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('re-keys by type, keeps a backup of every original, loses nothing',
      () async {
    final old = _oldPrefs();
    SharedPreferences.setMockInitialValues(old);
    await SavedMoviesService().init();
    final prefs = await _prefs();

    // Originals preserved verbatim.
    for (final key in [
      'watch_history_v1',
      'episode_history_v1',
      'episode_lengths_v1',
      'favorites_v1',
    ]) {
      expect(prefs.getString('${key}_premigration_backup'), old[key]);
    }
    expect(prefs.getBool('storage_key_migrated_v1'), isTrue);

    // Unrelated settings untouched.
    expect(prefs.getInt('selected_app_mode'), 0);
    expect(prefs.getBool('has_seen_welcome'), isTrue);
    expect(prefs.getString('last_played_torrent_1399'), 'abc');

    final history =
        jsonDecode(prefs.getString('watch_history_v1')!) as Map<String, dynamic>;
    expect(history.keys, unorderedEquals(['tv_1399', 'movie_603', '777']));
    expect(history['tv_1399']['last_watched'], 3000);
    expect(history['tv_1399']['movie']['current_episode'], 3);

    expect(jsonDecode(prefs.getString('episode_history_v1')!),
        {'tv_1399_2_3': 0.4, 'tv_1399_1_1': 1.0});
    expect(jsonDecode(prefs.getString('episode_lengths_v1')!),
        {'tv_1399_2_3': 3300});
    // Favourites hold whole movies and need no re-keying.
    expect(prefs.getString('favorites_v1'), old['favorites_v1']);

    final service = SavedMoviesService();
    expect(service.history.map((m) => m.title),
        ['Game of Thrones', 'The Matrix', 'Typeless']);
    expect(service.getEpisodeProgress('1399', 2, 3), 0.4);
    expect(service.getEpisodeMinutes('1399', 2, 3), 55);
    expect(service.favorites.length, 2);
  });

  test('is idempotent: a second run changes nothing', () async {
    SharedPreferences.setMockInitialValues(_oldPrefs());
    await SavedMoviesService().init();
    final prefs = await _prefs();
    final before = {for (final k in prefs.getKeys()) k: prefs.get(k)};

    await SavedMoviesService().init();
    await SavedMoviesService.migrateStorageKeys(prefs);
    expect({for (final k in prefs.getKeys()) k: prefs.get(k)}, before);
  });

  test('an interrupted run (flag unset, some keys already moved) is finished',
      () async {
    final old = _oldPrefs();
    // As if the episode data was re-keyed and the app died before the rest.
    old['episode_history_v1'] = jsonEncode({'tv_1399_2_3': 0.4});
    old['watch_history_v1_premigration_backup'] = 'the first backup';
    SharedPreferences.setMockInitialValues(old);
    await SavedMoviesService().init();
    final prefs = await _prefs();

    // An earlier backup is never overwritten with later data.
    expect(prefs.getString('watch_history_v1_premigration_backup'),
        'the first backup');
    expect(
        (jsonDecode(prefs.getString('watch_history_v1')!) as Map).keys,
        unorderedEquals(['tv_1399', 'movie_603', '777']));
    expect(SavedMoviesService().getEpisodeProgress('1399', 2, 3), 0.4);
  });

  test('a movie and a show with the same id do not collide', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SavedMoviesService();
    await service.init();

    Movie make(String type, String title) => Movie(
          id: '1399',
          title: title,
          year: 2011,
          rating: '8',
          voteCount: 1,
          description: '',
          type: type,
          inCinemas: false,
        );
    final show = make('tv', 'The Show');
    final film = make('movie', 'The Film');

    await service.addToHistory(show, season: 1, episode: 2, progress: 0.7);
    await service.addToHistory(film, progress: 0.2);

    expect(service.history.length, 2);
    expect(service.getMovieFromHistory('1399', type: 'tv')?.title, 'The Show');
    expect(service.getMovieFromHistory('1399', type: 'movie')?.title,
        'The Film');
    expect(service.getMovieFromHistory('1399', type: 'tv')?.progress, 0.7);
    expect(service.getMovieFromHistory('1399', type: 'movie')?.progress, 0.2);
    expect(service.getEpisodeProgress('1399', 1, 2), 0.7);

    await service.toggleFavorite(show);
    expect(service.isFavorite('1399', type: 'tv'), isTrue);
    expect(service.isFavorite('1399', type: 'movie'), isFalse);

    // Removing the movie leaves the show, its progress and its episodes.
    await service.removeFromHistory('1399', type: 'movie');
    expect(service.getMovieFromHistory('1399', type: 'movie'), isNull);
    expect(service.getMovieFromHistory('1399', type: 'tv')?.title, 'The Show');
    expect(service.getEpisodeProgress('1399', 1, 2), 0.7);

    await service.removeFromHistory('1399', type: 'tv');
    expect(service.getEpisodeProgress('1399', 1, 2), isNull);
  });

  test('an entry with no stored type stays readable and moves on save',
      () async {
    SharedPreferences.setMockInitialValues(_oldPrefs());
    final service = SavedMoviesService();
    await service.init();

    expect(service.getMovieFromHistory('777', type: 'movie')?.title,
        'Typeless');
    expect(service.getMovieFromHistory('777')?.title, 'Typeless');

    final m = service.getMovieFromHistory('777', type: 'movie')!;
    await service.addToHistory(m, progress: 0.9);
    expect(service.history.where((x) => x.id == '777').length, 1);
    expect(service.getMovieFromHistory('777', type: 'movie')?.progress, 0.9);
  });

  test('unreadable history is left alone, with the flag unset', () async {
    SharedPreferences.setMockInitialValues({'watch_history_v1': '{oops'});
    await SavedMoviesService().init();
    final prefs = await _prefs();
    expect(prefs.getString('watch_history_v1'), '{oops');
    expect(prefs.getString('watch_history_v1_premigration_backup'), '{oops');
    expect(prefs.getBool('storage_key_migrated_v1'), isNull);
  });

  test('importing an old backup runs the migration afterwards', () async {
    SharedPreferences.setMockInitialValues({'has_seen_welcome': false});
    final backup = {'_popcorn_backup': 1, ..._oldPrefs()};
    final ok = await BackupService().importJson(jsonEncode(backup));
    expect(ok, isTrue);

    final prefs = await _prefs();
    expect(prefs.getBool('storage_key_migrated_v1'), isTrue);
    expect(prefs.getString('watch_history_v1_premigration_backup'),
        _oldPrefs()['watch_history_v1']);
    expect(SavedMoviesService().getMovieFromHistory('1399', type: 'tv'),
        isNotNull);
    expect(SavedMoviesService().getEpisodeProgress('1399', 2, 3), 0.4);
  });
}
