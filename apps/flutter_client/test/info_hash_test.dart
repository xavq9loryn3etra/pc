import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_client/services/torrent/torrent_paths.dart';
import 'package:flutter_test/flutter_test.dart';

const good = 'AbCdEf0123456789aBcDeF0123456789ABCDEF01';

void main() {
  group('isValidInfoHash', () {
    test('accepts 40 hex digits in either case', () {
      expect(isValidInfoHash(good), isTrue);
      expect(isValidInfoHash(good.toLowerCase()), isTrue);
    });

    test('rejects anything else', () {
      expect(isValidInfoHash(''), isFalse);
      expect(isValidInfoHash(good.substring(1)), isFalse);
      expect(isValidInfoHash('${good}0'), isFalse);
      expect(isValidInfoHash('${good.substring(0, 36)}&dn='), isFalse);
      expect(isValidInfoHash('../${good.substring(3)}'), isFalse);
      expect(isValidInfoHash('$good\n'), isFalse);
      expect(isValidInfoHash('g${good.substring(1)}'), isFalse);
    });
  });

  group('TorrentStream', () {
    test('fromJson lowercases a valid hash', () {
      final s = TorrentStream.fromJson({
        'infoHash': good,
        'title': 'Movie 1080p\n👤 10 💾 1.5 GB ⚙️ x',
        'name': 'Torrentio\n1080p',
      });
      expect(s.infoHash, good.toLowerCase());
    });

    test('fromJson refuses a bad or missing hash', () {
      for (final bad in ['x&dn=y', '../etc', '', null, 5]) {
        expect(
            () => TorrentStream.fromJson({'infoHash': bad, 'title': 't'}),
            throwsFormatException);
      }
    });

    test('fromRelease refuses a bad hash and lowercases a good one', () {
      expect(
          () => TorrentStream.fromRelease(
              infoHash: 'nope',
              name: 'n',
              sizeBytes: 1,
              seeders: 1,
              source: 's'),
          throwsArgumentError);
      expect(
          TorrentStream.fromRelease(
                  infoHash: good,
                  name: 'n',
                  sizeBytes: 1,
                  seeders: 1,
                  source: 's')
              .infoHash,
          good.toLowerCase());
    });
  });

  test('savePathFor refuses a hash that could leave the folder', () {
    expect(() => TorrentPaths.savePathFor('../..'), throwsArgumentError);
  });
}
