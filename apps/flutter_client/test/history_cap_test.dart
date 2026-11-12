import 'dart:convert';

import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Movie _show(int n) => Movie(
      id: '$n',
      title: 'Show $n',
      year: 2020,
      rating: '8',
      voteCount: 1,
      description: '',
      type: 'tv',
      inCinemas: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('history keeps the newest 200 titles and drops the rest with their episodes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = SavedMoviesService();
    await service.init();

    for (var n = 1; n <= 205; n++) {
      await service.addToHistory(_show(n),
          season: 1, episode: 1, progress: 0.5);
      // last_watched is in milliseconds: keep each title distinguishable.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await service.flush();

    expect(service.history.length, SavedMoviesService.maxHistoryTitles);
    expect(service.getMovieFromHistory('1', type: 'tv'), isNull);
    expect(service.getMovieFromHistory('5', type: 'tv'), isNull);
    expect(service.getMovieFromHistory('6', type: 'tv'), isNotNull);
    expect(service.getMovieFromHistory('205', type: 'tv'), isNotNull);
    // The evicted titles' episode progress goes with them.
    expect(service.getEpisodeProgress('1', 1, 1), isNull);
    expect(service.getEpisodeProgress('6', 1, 1), 0.5);

    final prefs = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(prefs.getString('watch_history_v1')!) as Map<String, dynamic>;
    expect(stored.length, 200);
    final episodes = jsonDecode(prefs.getString('episode_history_v1')!) as Map;
    expect(episodes.length, 200);
  });

  test('progress is written in batches, and flush writes it at once', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SavedMoviesService();
    await service.init();
    final prefs = await SharedPreferences.getInstance();

    await service.addToHistory(_show(1), season: 1, episode: 1, progress: 0.1);
    await service.addToHistory(_show(1), season: 1, episode: 1, progress: 0.2);
    // Held in memory for now...
    expect(service.getEpisodeProgress('1', 1, 1), 0.2);
    expect(prefs.getString('watch_history_v1'), isNull);

    // ...until flushed.
    await service.flush();
    final stored =
        jsonDecode(prefs.getString('watch_history_v1')!) as Map<String, dynamic>;
    expect(stored['tv_1']['movie']['progress'], 0.2);
    expect(jsonDecode(prefs.getString('episode_history_v1')!), {'tv_1_1_1': 0.2});
  });
}
