import 'package:flutter_client/services/tmdb_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool hidden(Map m) => TMDBService.isUnsuitable(m);

  test('uploads marked as nothing at all are hidden', () {
    // As TMDB lists them: not marked adult, so include_adult let them in.
    expect(
        hidden({
          'title': 'Super Boobs: Volume 1',
          'adult': false,
          'genre_ids': [],
          'vote_count': 0,
          'release_date': '',
        }),
        isTrue);
    expect(
        hidden({
          'title': 'Some Upload',
          'adult': false,
          'genre_ids': [],
          'vote_count': 0,
          'release_date': '',
        }),
        isTrue);
  });

  test('explicit words in a title hide it, whatever else it has', () {
    expect(
        hidden({
          'title': 'Busty Nights',
          'genre_ids': [35],
          'vote_count': 12,
          'release_date': '2019-01-01',
        }),
        isTrue);
    expect(hidden({'title': 'Anything', 'adult': true}), isTrue);
    expect(
        hidden({
          'title': 'X.X.X: Uncensored',
          'genre_ids': [18],
          'vote_count': 3,
          'release_date': '2010-01-01',
        }),
        isTrue);
  });

  test('talk, news and reality shows are hidden', () {
    expect(
        hidden({
          'name': 'Jimmy Kimmel Live!',
          'genre_ids': [10767, 35],
          'vote_count': 400,
          'first_air_date': '2003-01-26',
        }),
        isTrue);
    expect(
        hidden({
          'name': 'The Daily Show',
          'genre_ids': [10763, 35],
          'vote_count': 500,
          'first_air_date': '1996-07-22',
        }),
        isTrue);
    // Details give genres as objects.
    expect(
        hidden({
          'name': 'Late Show',
          'genres': [
            {'id': 10767, 'name': 'Talk'}
          ],
          'vote_count': 10,
          'first_air_date': '2015-09-08',
        }),
        isTrue);
    expect(
        hidden({
          'name': 'Survivor',
          'genre_ids': [10764],
          'vote_count': 300,
          'first_air_date': '2000-05-31',
        }),
        isTrue);
  });

  test('real films stay, however small', () {
    // Neera: Sinhala, a handful of details.
    expect(
        hidden({
          'title': 'Neera',
          'original_title': 'නීරා',
          'genre_ids': [],
          'vote_count': 0,
          'release_date': '2025-09-19',
        }),
        isFalse);
    expect(
        hidden({
          'title': 'Back to the Future Part II',
          'genre_ids': [12, 35, 878],
          'vote_count': 14000,
          'release_date': '1989-11-22',
        }),
        isFalse);
    // A real series with a cheeky title (rated 12).
    expect(
        hidden({
          'name': 'MILF of Norway',
          'genre_ids': [18, 35],
          'vote_count': 11,
          'first_air_date': '2024-05-21',
        }),
        isFalse);
    // Not inside another word.
    expect(
        hidden({
          'title': 'Analyze This',
          'genre_ids': [35],
          'vote_count': 2000,
          'release_date': '1999-03-05',
        }),
        isFalse);
  });
}
