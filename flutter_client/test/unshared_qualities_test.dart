import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';

int _n = 0;

TorrentStream copy(String quality, int? seeders) => TorrentStream(
      infoHash: (++_n).toRadixString(16).padLeft(40, '0'),
      title: 'Show.S01E01.$quality',
      name: 'Show.S01E01.$quality',
      quality: quality,
      seeders: seeders,
    );

List<String> qualities(List<TorrentStream> streams) =>
    {for (final s in streams) s.quality!}.toList();

void main() {
  test('a quality nobody shares is left out, the others kept', () {
    // The Falcon and the Winter Soldier S1E1: three SD copies, none shared.
    final streams = [
      copy('1080p', 40),
      copy('720p', 12),
      copy('480p', 0),
      copy('480p', 0),
      copy('480p', 0),
    ];
    expect(qualities(StreamResolver.withoutUnsharedQualities(streams)),
        ['1080p', '720p']);
  });

  test('one shared copy keeps the whole quality, unshared ones as backups',
      () {
    final streams = [copy('480p', 0), copy('480p', 3)];
    expect(StreamResolver.withoutUnsharedQualities(streams), hasLength(2));
  });

  test('an unknown count is not taken for no one', () {
    final streams = [copy('480p', null)];
    expect(StreamResolver.withoutUnsharedQualities(streams), hasLength(1));
  });

  test('a copy already on the device keeps its quality', () {
    final mine = copy('720p', 0);
    final streams = [copy('1080p', 9), mine];
    expect(
        qualities(StreamResolver.withoutUnsharedQualities(streams,
            onDevice: {mine.infoHash})),
        ['1080p', '720p']);
  });

  test('nothing shared at all: nothing left', () {
    final streams = [copy('1080p', 0), copy('480p', 0)];
    expect(StreamResolver.withoutUnsharedQualities(streams), isEmpty);
  });
}
