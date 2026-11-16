import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/torrent/stream_resolver.dart';
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

Movie film(String title, int year, {String type = 'movie'}) => Movie(
      id: '1',
      title: title,
      year: year,
      rating: '8.0',
      voteCount: 1,
      description: '',
      type: type,
      inCinemas: false,
    );

void main() {
  group('a film far off its length is another film', () {
    Duration minutes(int m) => Duration(minutes: m);

    test("The Asylum's 86-minute The Odyssey for Nolan's 173", () {
      expect(StreamResolver.wrongLength(minutes(86), 173), isTrue);
    });

    test('a sample or trailer', () {
      expect(StreamResolver.wrongLength(minutes(2), 120), isTrue);
    });

    test('the film itself, a cut or an extended cut', () {
      expect(StreamResolver.wrongLength(minutes(172), 173), isFalse);
      expect(StreamResolver.wrongLength(minutes(140), 173), isFalse);
      // The Lord of the Rings: The Return of the King, extended.
      expect(StreamResolver.wrongLength(minutes(263), 201), isFalse);
    });

    test('never without a known length, or for a short', () {
      expect(StreamResolver.wrongLength(minutes(86), null), isFalse);
      expect(StreamResolver.wrongLength(minutes(5), 20), isFalse);
    });
  });

  group('inside a copy', () {
    final odyssey = film('The Odyssey', 2026);

    test('a program among its files', () {
      final files = [
        file(0, 'The.Odyssey.2026.1080p/The.Odyssey.2026.1080p.mkv', 900),
        file(1, 'The.Odyssey.2026.1080p/Codec Installer.exe', 5),
      ];
      expect(StreamResolver.insideProblem(files, null, odyssey), isNotNull);
      final shortcut = [
        file(0, 'Movie/Movie.mp4', 900),
        file(1, 'Movie/Play Movie.lnk', 1, streamable: false),
      ];
      expect(StreamResolver.insideProblem(shortcut, 0, odyssey), isNotNull);
    });

    test("its video is another year's film", () {
      final files = [
        file(0, 'The.Odyssey.1997.Part.1.mkv', 900),
        file(1, 'readme.txt', 1, streamable: false),
      ];
      expect(StreamResolver.insideProblem(files, null, odyssey), isNotNull);
    });

    test('a collection, playing the right film from it', () {
      final nolan = film('Inception', 2010);
      final files = [
        file(0, 'Christopher Nolan Collection (2000-2023)/Tenet.2020.mkv', 900),
        file(1, 'Christopher Nolan Collection (2000-2023)/Inception.2010.mkv',
            800),
      ];
      expect(StreamResolver.insideProblem(files, 1, nolan), isNull);
    });

    test('a real copy, with its text and pictures', () {
      final files = [
        file(0, 'The Odyssey (2026) [1080p] [BluRay]/The.Odyssey.2026.mp4',
            900),
        file(1, 'The Odyssey (2026) [1080p] [BluRay]/YTS.MX.jpg', 1,
            streamable: false),
        file(2, 'The Odyssey (2026) [1080p] [BluRay]/www.YTS.MX.com.txt', 1,
            streamable: false),
        file(3, 'The Odyssey (2026) [1080p] [BluRay]/Subs/English.srt', 1,
            streamable: false),
      ];
      expect(StreamResolver.insideProblem(files, null, odyssey), isNull);
    });

    test('a series episode from a season pack', () {
      final show = film('Breaking Bad', 2008, type: 'tv');
      final files = [
        file(0, 'Breaking.Bad.S02.1080p/Breaking.Bad.S02E01.mkv', 900),
        file(1, 'Breaking.Bad.S02.1080p/Breaking.Bad.S02E02.mkv', 900),
      ];
      expect(StreamResolver.insideProblem(files, 1, show), isNull);
    });
  });
}
