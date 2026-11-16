import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TorrentStream copy(String hash, String name, String quality, String size) =>
      TorrentStream(
        infoHash: hash.padRight(40, '0'),
        title: name,
        name: name,
        quality: quality,
        size: size,
      );

  final nolans = Movie(
    id: '1368337',
    title: 'The Odyssey',
    year: 2026,
    rating: '8.0',
    voteCount: 4942,
    description: '',
    type: 'movie',
    inCinemas: false,
    runtime: '2h 53m',
  );

  // As Torrentio listed them under Nolan's The Odyssey (2026), 16 Nov 2026.
  final listed = [
    // The Asylum's: its YTS copies, and re-uploads of them.
    copy('c7bcda86', 'The Odyssey (2026) [720p] [WEBRip]', '720p',
        '790.29 MB'),
    copy('5818bf07', 'The Odyssey (2026) [720p] [WEBRip]', '720p',
        '790.28 MB'),
    copy('9a9ce482', 'The Odyssey (2026) [1080p] [WEBRip] [5.1]', '1080p',
        '1.59 GB'),
    copy('65bc1ac2', 'The Odyssey (2026) 1080p WEBRip x265 10bit 5.1-LAMA',
        '1080p', '1.44 GB'),
    // Nolan's.
    copy('f566bbf0', 'The Odyssey (2026) [720p] [BluRay]', '720p', '1.55 GB'),
    copy('27dafe28', 'The Odyssey (2026) [1080p] [BluRay] [5.1]', '1080p',
        '3.18 GB'),
    copy('9bf23413', 'The Odyssey (2026) 1080p BluRay x265', '1080p',
        '1.74 GB'),
    copy('aaaa0001', 'The.Odyssey.2026.720p.10bit.BluRay.6CH.x265.HEVC-PSA',
        '720p', '1.36 GB'),
    copy('e504c0e3', 'The Odyssey (2026) [2160p] [BluRay] [x265]', '4k',
        '7.82 GB'),
  ];

  // YTS's copies of The Asylum's The Odyssey (2026).
  final asylumYts = [
    copy('5818bf07', 'The Odyssey (2026) 720p web x264 YTS', '720p',
        '790.58 MB'),
    copy('f4b8895a', 'The Odyssey (2026) 1080p web x264 YTS', '1080p',
        '1.59 GB'),
    copy('ea0a404f', 'The Odyssey (2026) 1080p web x265 YTS', '1080p',
        '1.44 GB'),
  ];

  test("a namesake's copies, and re-uploads of them, are left out", () {
    final kept = StreamResolver.withoutNamesakes(listed, asylumYts);
    expect(kept.map((s) => s.infoHash.substring(0, 8)), [
      'f566bbf0',
      '27dafe28',
      '9bf23413',
      'aaaa0001',
      'e504c0e3',
    ]);
  });

  test('with no namesake, nothing is left out', () {
    expect(StreamResolver.withoutNamesakes(listed, const []), listed);
  });

  test("a release saying it isn't the film is left out", () {
    expect(
        StreamResolver.saysAnotherFilm(
            copy('5e6b52b1',
                'The Odyssey 2026 (NOT The Chris Nolan FILM) 1080p WEB-DL',
                '1080p', '1.02 GB'),
            nolans),
        isTrue);
    expect(
        StreamResolver.saysAnotherFilm(
            copy('4b9fc633',
                'The.Odyssey.2026.720p.TUBI.WEB-DL.AAC2.0-NOtLAN (NOT The Chris Nolan FILM)',
                '720p', '1.29 GB'),
            nolans),
        isTrue);
    expect(StreamResolver.saysAnotherFilm(listed[4], nolans), isFalse);
    // "Not the" in a film's own name.
    final messiah = Movie(
      id: '2',
      title: "Not the Messiah (He's a Very Naughty Boy) Film",
      year: 2010,
      rating: '7.0',
      voteCount: 10,
      description: '',
      type: 'movie',
      inCinemas: false,
    );
    expect(
        StreamResolver.saysAnotherFilm(
            copy('bbbb0001',
                "Not.the.Messiah.He's.a.Very.Naughty.Boy.Film.2010.1080p",
                '1080p', '6 GB'),
            messiah),
        isFalse);
  });
}
