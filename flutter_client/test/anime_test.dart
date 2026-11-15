import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/enums/app_mode.dart';
import 'package:flutter_client/services/tmdb_service.dart';

void main() {
  group('TMDBService.isAnime', () {
    test('a Japanese animated series in a list result', () {
      expect(
          TMDBService.isAnime({
            'original_language': 'ja',
            'genre_ids': [16, 10759],
          }),
          isTrue);
    });

    test('a Japanese animated film on its details page', () {
      expect(
          TMDBService.isAnime({
            'original_language': 'ja',
            'genres': [
              {'id': 16, 'name': 'Animation'},
              {'id': 18, 'name': 'Drama'},
            ],
          }),
          isTrue);
    });

    test('animation from elsewhere is not anime', () {
      expect(
          TMDBService.isAnime({
            'original_language': 'en',
            'genre_ids': [16, 10751],
          }),
          isFalse);
    });

    test('a Japanese live action drama is not anime', () {
      expect(
          TMDBService.isAnime({
            'original_language': 'ja',
            'genre_ids': [18],
          }),
          isFalse);
    });
  });

  test('Ramen is a video mode with its own orange', () {
    expect(AppMode.anime.isVideo, isTrue);
    expect(AppMode.anime.label, 'Ramen');
    expect(AppMode.anime.accentColor, const Color(0xFFFD5602));
    expect(AppMode.anime.logoHasOwnColors, isTrue);
    expect(AppMode.movies.logoHasOwnColors, isFalse);
  });
}
