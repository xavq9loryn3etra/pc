import 'package:flutter_client/services/trending_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a slide saved with TMDB's smaller size is shown at full size", () {
    expect(
        TrendingItem.original('https://image.tmdb.org/t/p/w780/abc.jpg'),
        'https://image.tmdb.org/t/p/original/abc.jpg');
    expect(
        TrendingItem.original('https://image.tmdb.org/t/p/w1280/abc.jpg'),
        'https://image.tmdb.org/t/p/original/abc.jpg');
    expect(
        TrendingItem.original('https://image.tmdb.org/t/p/original/abc.jpg'),
        'https://image.tmdb.org/t/p/original/abc.jpg');
    // Not TMDB's.
    expect(TrendingItem.original('https://covers.openlibrary.org/b/w500/x.jpg'),
        'https://covers.openlibrary.org/b/w500/x.jpg');
    final saved = TrendingItem.fromJson({
      'title': 'The Odyssey',
      'subtitle': '',
      'imageUrl': 'https://image.tmdb.org/t/p/w780/p.jpg',
      'wideImageUrl': 'https://image.tmdb.org/t/p/w1280/b.jpg',
      'logoUrl': null,
    });
    expect(saved.imageUrl, 'https://image.tmdb.org/t/p/original/p.jpg');
    expect(saved.wideImageUrl, 'https://image.tmdb.org/t/p/original/b.jpg');
  });
}
