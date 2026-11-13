import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_test/flutter_test.dart';

String hash(int n) => n.toRadixString(16).padLeft(40, '0');

TorrentStream stream(int n, String name, String size, {int seeders = 100}) =>
    TorrentStream.fromRelease(
      infoHash: hash(n),
      name: name,
      sizeBytes: (double.parse(size) * 1024 * 1024 * 1024).round(),
      seeders: seeders,
      source: 'test',
    );

void main() {
  group('codecRank', () {
    test('marks AV1 down', () {
      expect(StreamResolver.codecRank(stream(1, 'Movie 2026 1080p AV1', '1')), 1);
      expect(
          StreamResolver.codecRank(stream(2, 'Movie.2026.1080p.WEB.av1-GRP', '1')),
          1);
    });

    test('leaves everything else alone', () {
      expect(StreamResolver.codecRank(stream(1, 'Movie 1080p x264', '1')), 0);
      expect(StreamResolver.codecRank(stream(2, 'Movie 1080p x265 10bit', '1')), 0);
      // Not a word of its own.
      expect(StreamResolver.codecRank(stream(3, 'Movie.AV10.1080p', '1')), 0);
    });
  });

  test('an AV1 copy goes after a larger, easier one of the same quality', () {
    final av1 = stream(1, 'Movie 2026 1080p WEB AV1', '0.8');
    final x264 = stream(2, 'Movie 2026 1080p WEB x264', '2.0');
    final options = StreamResolver.qualityOptions([av1, x264]);
    expect(options.single.streams.map((s) => s.infoHash),
        [x264.infoHash, av1.infoHash]);
  });

  test('without AV1, the smaller copy still goes first', () {
    final small = stream(1, 'Movie 2026 1080p WEB x265', '0.8');
    final big = stream(2, 'Movie 2026 1080p WEB x264', '2.0');
    final options = StreamResolver.qualityOptions([big, small]);
    expect(options.single.streams.first.infoHash, small.infoHash);
  });
}
