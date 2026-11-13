import 'package:flutter_client/services/torrent/torrent_engine_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

FileInfo file(int index, String path, int size, {bool streamable = true}) =>
    FileInfo(
      index: index,
      name: path.split('/').last,
      path: path,
      size: size,
      isStreamable: streamable,
    );

void main() {
  group('chooseVideoFile', () {
    test('picks the largest video, not the largest file', () {
      final files = [
        file(0, 'Movie/Movie.iso', 9000, streamable: false),
        file(1, 'Movie/Movie.mkv', 4000),
        file(2, 'Movie/Movie.srt', 10, streamable: false),
      ];
      expect(TorrentEngineService.chooseVideoFile(files), 1);
    });

    test('leaves out samples, trailers and extras', () {
      final files = [
        file(0, 'Movie/Sample/movie-sample.mkv', 9000),
        file(1, 'Movie/Trailer.mp4', 8000),
        file(2, 'Movie/Extras/making-of.mkv', 7000),
        file(3, 'Movie/Movie.mkv', 3000),
      ];
      expect(TorrentEngineService.chooseVideoFile(files), 3);
    });

    test('keeps words that only contain a bonus word', () {
      final files = [
        file(0, 'Examples.of.Samplers.S01E01.mkv', 3000),
        file(1, 'Show.S01E02.mkv', 2000),
      ];
      expect(TorrentEngineService.chooseVideoFile(files), 0);
    });

    test('throws when there is no video', () {
      final files = [
        file(0, 'a.rar', 100, streamable: false),
        file(1, 'sample.mkv', 50),
      ];
      expect(() => TorrentEngineService.chooseVideoFile(files), throwsException);
      expect(() => TorrentEngineService.chooseVideoFile([]), throwsException);
    });
  });
}
