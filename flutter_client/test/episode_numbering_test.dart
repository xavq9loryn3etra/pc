import 'package:flutter_client/services/episode_numbering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime day(String d) => DateTime.parse(d);

  // A show IMDb splits 3 + 3, aired weekly from 1 January.
  final imdb = <ImdbEpisode>[
    for (var i = 0; i < 6; i++)
      (
        season: i < 3 ? 1 : 2,
        episode: i < 3 ? i + 1 : i - 2,
        aired: day('2020-01-01').add(Duration(days: 7 * i)),
      ),
  ];

  test('the same numbers when IMDb has them airing then', () {
    expect(
      EpisodeNumbering.matchEpisode(imdb,
          season: 2, episode: 1, position: 3, aired: day('2020-01-22')),
      (2, 1),
    );
  });

  test("TMDB's other split: matched by place in the run", () {
    // TMDB splits it 2 + 4: its S2E1 is the third episode, IMDb's S1E3.
    expect(
      EpisodeNumbering.matchEpisode(imdb,
          season: 2, episode: 1, position: 2, aired: day('2020-01-15')),
      (1, 3),
    );
  });

  test('One Piece style: TMDB numbers episodes across the whole run', () {
    // TMDB's season 2 starts at episode 4, numbered 4.
    expect(
      EpisodeNumbering.matchEpisode(imdb,
          season: 2, episode: 4, position: 3, aired: day('2020-01-22')),
      (2, 1),
    );
  });

  test('a day off still counts (time zones)', () {
    expect(
      EpisodeNumbering.matchEpisode(imdb,
          season: 2, episode: 1, position: 2, aired: day('2020-01-16')),
      (1, 3),
    );
  });

  test('place off but the air date known: the episode aired that day', () {
    // A missing episode on one side shifts the count by one.
    expect(
      EpisodeNumbering.matchEpisode(imdb,
          season: 2, episode: 3, position: 5, aired: day('2020-01-29')),
      (2, 2),
    );
  });

  test('nothing matching: null (the numbers stay as they were)', () {
    expect(
      EpisodeNumbering.matchEpisode(imdb,
          season: 5, episode: 1, position: 40, aired: day('2024-06-01')),
      isNull,
    );
  });
}
