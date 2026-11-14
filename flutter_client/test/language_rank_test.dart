import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_test/flutter_test.dart';

int _n = 0;

/// A copy as Torrentio lists it: its release name and languages line.
TorrentStream copy(String name, [String languages = '']) => TorrentStream(
      infoHash: (++_n).toRadixString(16).padLeft(40, '0'),
      title: name,
      name: name,
      languages: languages,
    );

int rank(TorrentStream s, String wanted,
        {String own = 'en', String title = ''}) =>
    StreamResolver.languageRank(s.wantingLanguage(WantedAudio(
        language: wanted, titleLanguage: own, titleName: title)));

void main() {
  group('Aavesham (Malayalam), real copy names', () {
    final unmarked = copy('Aavesham 2024 720p WEBRip');
    final malayalam = copy(
        'Aavesham (2024) Malayalam 720p 10bit DS4K AMZN WEBRip AAC5.1 x265 HEVC ESub-LSSJBroly [ProtonMovies]');
    final hindi =
        copy('Aavesham 2024 HINDI 1080P HULU WEB-DL H264 DDP5.1 ESUB-SHB931', '🇮🇳');
    final dual = copy(
        'Aavesham (2024) 720p 10bit DS4K AMZN WEBRip [ Org Hindi DDP 5.1 Malayalam AAC 5.1] Dual Audio x265 HEVC ESub ~ TheAvi [ProtonMovies]',
        'Dual Audio / 🇮🇳');
    final hinMal = copy(
        'Aavesham (2024) 720p WEBRip x265 AAC [ Hin Mal ] ESub [krishh1337]', '🇮🇳');
    final codes = copy(
        'Aavesham.2024.1080p.DS4K.AMZN.WEBrip.[HIN-MAL].DDP5.1.SDR.10bit.X265.HEVC-ZiroMB',
        '🇮🇳');

    int ml(TorrentStream s) => rank(s, 'ml', own: 'ml', title: 'Aavesham');
    int en(TorrentStream s) => rank(s, 'en', own: 'ml', title: 'Aavesham');

    test('none is offered in English', () {
      for (final s in [unmarked, malayalam, hindi, dual, hinMal, codes]) {
        expect(en(s), 2, reason: s.name);
      }
    });

    test('in Malayalam: its own copies, never the Hindi dub', () {
      expect(ml(unmarked), 0);
      expect(ml(malayalam), 0);
      expect(ml(hindi), 2);
      expect(ml(dual), 1);
      expect(ml(hinMal), 1);
      expect(ml(codes), 1);
    });
  });

  test("Trance's misspelt Malayalam copy is still Malayalam", () {
    final s = copy(
        'Trance (2020) 720p WEBRip x264 AAC [ Hin Tel Malyalam ] ESub', '🇮🇳');
    expect(rank(s, 'ml', own: 'ml', title: 'Trance'), 1);
    expect(rank(s, 'en', own: 'ml', title: 'Trance'), 2);
  });

  group('a title made in English', () {
    test('unmarked is English', () {
      expect(rank(copy('Back to the Future Part II 1989 720p BluRay'), 'en'), 0);
    });
    test('a dub is not', () {
      expect(rank(copy('Back to the Future II 1989 ITA 720p', '🇮🇹'), 'en'), 2);
      expect(rank(copy('Back to the Future II 1989 Hindi 720p', '🇮🇳'), 'en'), 2);
    });
    test('with English among others, it can be picked', () {
      expect(
          rank(copy('Back to the Future II 1989 ITA ENG 720p', '🇬🇧 / 🇮🇹'), 'en'), 1);
    });
    test('English subtitles say nothing of the audio', () {
      expect(rank(copy('Movie 2020 Hindi 720p English Subs', '🇮🇳'), 'en'), 2);
    });
  });

  group('Dark (German)', () {
    int de(TorrentStream s) => rank(s, 'de', own: 'de', title: 'Dark');
    int en(TorrentStream s) => rank(s, 'en', own: 'de', title: 'Dark');

    test('unmarked is German, not English', () {
      final s = copy('Dark S01E01 1080p WEB');
      expect(de(s), 0);
      expect(en(s), 2);
    });
    test('dual audio with English can be picked in either', () {
      final s = copy('Dark S01E01 German English Dual Audio 1080p', 'Dual Audio / 🇬🇧 / 🇩🇪');
      expect(de(s), 1);
      expect(en(s), 1);
    });
  });

  test("a title's own words don't name its language", () {
    final s = copy('English Vinglish 2012 1080p WEBRip');
    expect(rank(s, 'hi', own: 'hi', title: 'English Vinglish'), 0);
    expect(rank(s, 'en', own: 'hi', title: 'English Vinglish'), 2);
  });
}
