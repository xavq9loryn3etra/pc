import 'dart:typed_data';

import 'package:flutter_client/services/subtitle_service.dart';
import 'package:flutter_test/flutter_test.dart';

SubtitleTrackData _sub(String id, String release, String group,
        {bool matchesFile = false}) =>
    SubtitleTrackData(
      id: id,
      url: 'https://example.com/$id.srt',
      lang: 'eng',
      releaseName: release,
      releaseGroup: group,
      matchesFile: matchesFile,
    );

void main() {
  test("the fingerprint is OpenSubtitles' hash", () {
    // Expected worked out apart from this code (Python's struct, unsigned
    // 64-bit sums).
    final head = Uint8List.fromList(
        [for (var i = 0; i < 65536; i++) (i * 31 + 7) % 256]);
    final tail = Uint8List.fromList(
        [for (var i = 0; i < 65536; i++) (i * 17 + 3) % 256]);
    expect(SubtitleService.openSubtitlesHash(1000000, head, tail),
        '5f606060606f8240');
  });

  test('subtitles made for this file, then this release, come first', () {
    final web = _sub('1', 'Ghosts.2021.S01E07.1080p.WEB.H264-CAKES', 'CAKES');
    final amzn = _sub('2',
        'Ghosts.2021.S01E07.Flowers.Article.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb',
        'NTb');
    final bluray = _sub('3', 'Ghosts.2021.S01E07.1080p.BluRay.x264-BORDURE',
        'BORDURE');
    final exact = _sub('4', 'Something.Else', 'X', matchesFile: true);

    // A Blu-ray copy: the Blu-ray subtitles over the web ones.
    expect(
        SubtitleService.rank([web, amzn, bluray],
                'Ghosts 2021 S01 1080p BluRay x265\nGhosts.2021.S01E07.1080p.BluRay.x265-RARBG.mp4')
            .map((s) => s.id),
        ['3', '1', '2']);
    // NTb's Amazon copy: NTb's subtitles first.
    expect(
        SubtitleService.rank([web, bluray, amzn],
                'Ghosts.2021.S01E07.Flowers.Article.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv')
            .map((s) => s.id),
        ['2', '1', '3']);
    // One found by the file's fingerprint beats everything.
    expect(
        SubtitleService.rank([amzn, exact],
                'Ghosts.2021.S01E07.Flowers.Article.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv')
            .first
            .id,
        '4');
  });

  test("what OpenSubtitles says about a subtitle is kept", () {
    final s = SubtitleTrackData.fromJson({
      'id': '8873690',
      'url': 'https://subs5.strem.io/x',
      'lang': 'eng',
      'm': 'h',
      'subtitleFileName': 'Ghosts.2021.S01E07.1080p.WEB.H264-CAKES.srt',
      'movieReleaseName': 'Ghosts.2021.S01E07.1080p.WEB.H264-CAKES',
      'releaseGroup': 'CAKES',
    });
    expect(s.matchesFile, isTrue);
    expect(s.releaseGroup, 'CAKES');
    expect(s.releaseName, 'Ghosts.2021.S01E07.1080p.WEB.H264-CAKES');
  });
}
