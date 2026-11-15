import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TorrentStream copy(String quality, String size) => TorrentStream(
        infoHash: '0' * 40,
        title: 'One Piece - 011 [$quality]',
        name: 'One Piece - 011 [$quality]',
        quality: quality,
        size: size,
      );

  Movie show(String? runtime, {String type = 'tv'}) => Movie(
        id: '1',
        title: 'One Piece',
        year: 1999,
        rating: '9.0',
        voteCount: 1,
        description: '',
        type: type,
        inCinemas: false,
        runtime: runtime,
      );

  test('runtimes as TMDB gives them', () {
    expect(StreamResolver.minutesOf('24m'), 24);
    expect(StreamResolver.minutesOf('1h 48m'), 108);
    expect(StreamResolver.minutesOf('2h 0m'), 120);
    expect(StreamResolver.minutesOf(null), isNull);
    expect(StreamResolver.minutesOf('N/A'), isNull);
  });

  test("a 74 MB '720p' episode is far too small", () {
    expect(StreamResolver.tooSmallFor(copy('720p', '74.03 MB'), show('24m')),
        isTrue);
  });

  test('real copies pass', () {
    // Erai-raws' 720p episode, a squeezed 1080p one, a 4K film.
    expect(StreamResolver.tooSmallFor(copy('720p', '338.37 MB'), show('24m')),
        isFalse);
    expect(StreamResolver.tooSmallFor(copy('1080p', '174.26 MB'), show('24m')),
        isFalse);
    expect(
        StreamResolver.tooSmallFor(
            copy('4k', '1.6 GB'), show('1h 48m', type: 'movie')),
        isFalse);
    // SD is never too small; nor is a copy of unknown size.
    expect(StreamResolver.tooSmallFor(copy('480p', '40 MB'), show('24m')),
        isFalse);
  });

  test('length unknown: a short one is taken', () {
    expect(StreamResolver.tooSmallFor(copy('720p', '60 MB'), show(null)),
        isTrue);
    expect(StreamResolver.tooSmallFor(copy('720p', '90 MB'), show(null)),
        isFalse);
  });
}
