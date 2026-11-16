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

  test('documentaries and behind-the-scenes extras are hidden', () {
    expect(
        hidden({
          'title': 'Free Solo',
          'genre_ids': [99],
          'vote_count': 2000,
          'release_date': '2018-09-28',
        }),
        isTrue);
    expect(
        hidden({
          'title': 'The Making of Dune',
          'genre_ids': [],
          'vote_count': 4,
          'release_date': '2021-10-01',
        }),
        isTrue);
    expect(
        hidden({
          'title': 'Oppenheimer: Behind the Scenes',
          'genre_ids': [],
          'vote_count': 2,
          'release_date': '2023-07-01',
        }),
        isTrue);
    expect(
        hidden({
          'title': 'Barbie Featurette',
          'genre_ids': [],
          'vote_count': 1,
          'release_date': '2023-07-01',
        }),
        isTrue);
    // A drama, not a making-of.
    expect(
        hidden({
          'title': 'The Making of a Lady',
          'genre_ids': [18, 10770],
          'vote_count': 60,
          'release_date': '2012-12-09',
        }),
        isFalse);
  });

  test('concert films are hidden, musicals stay', () {
    expect(
        hidden({
          'id': 1160164,
          'title': 'TAYLOR SWIFT | THE ERAS TOUR',
          'genre_ids': [10402],
          'vote_count': 554,
          'release_date': '2023-10-13',
        }),
        isTrue);
    expect(
        hidden({
          'id': 1,
          'title': 'Some Band: Live',
          'genre_ids': [10402, 10770],
          'vote_count': 5,
          'release_date': '2012-01-01',
        }),
        isTrue);
    expect(
        hidden({
          'id': 316029,
          'title': 'The Greatest Showman',
          'genre_ids': [18, 10402, 10751],
          'vote_count': 9000,
          'release_date': '2017-12-20',
        }),
        isFalse);
  });

  test('stand-up specials are hidden, comedy films and sitcoms stay', () {
    TMDBService.standUpSpecials = {'movie_823754', 'tv_32962'};
    addTearDown(() => TMDBService.standUpSpecials = {});
    expect(
        hidden({
          'id': 823754,
          'title': 'Bo Burnham: Inside',
          'genre_ids': [35],
          'vote_count': 664,
          'release_date': '2021-05-30',
        }),
        isTrue);
    // As a person's credits list it.
    expect(
        hidden({
          'id': 823754,
          'media_type': 'movie',
          'title': 'Bo Burnham: Inside',
          'genre_ids': [35],
          'vote_count': 664,
          'release_date': '2021-05-30',
        }),
        isTrue);
    // Comedy alone, but not stand-up.
    expect(
        hidden({
          'id': 8363,
          'title': 'Superbad',
          'genre_ids': [35],
          'vote_count': 8515,
          'release_date': '2007-08-17',
        }),
        isFalse);
    // Tagged stand-up, but a sitcom (Drama too).
    expect(
        hidden({
          'id': 32962,
          'name': 'Louie',
          'genre_ids': [35, 18],
          'vote_count': 400,
          'first_air_date': '2010-06-29',
        }),
        isFalse);
    // A series with the same number as a stand-up film.
    expect(
        hidden({
          'id': 823754,
          'name': 'Some Show',
          'genre_ids': [35],
          'vote_count': 10,
          'first_air_date': '2020-01-01',
        }),
        isFalse);
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
