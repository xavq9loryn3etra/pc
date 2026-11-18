import 'package:flutter_client/services/subtitle_service.dart';
import 'package:flutter_test/flutter_test.dart';

SubtitleTrackData track({String? release, String? label}) => SubtitleTrackData(
    id: '${release ?? ''}|${label ?? ''}',
    url: 'u',
    lang: 'eng',
    releaseName: release,
    label: label);

/// What a subtitle was written for, read from its name or title
/// (SubtitleService.kindOf): an English dub wants the dub's captions, the
/// original voices the usual translation, and signs-only tracks neither.
void main() {
  SubtitleKind kind({String? release, String? label}) =>
      SubtitleService.kindOf(track(release: release, label: label));

  test('signs and songs, and forced tracks', () {
    expect(kind(label: 'Signs & Songs'), SubtitleKind.signsOnly);
    expect(kind(label: 'English [Signs/Songs]'), SubtitleKind.signsOnly);
    expect(kind(label: 'Forced'), SubtitleKind.signsOnly);
  });

  test('full subtitles that include signs follow the dialogue', () {
    expect(kind(label: 'Full Subs (Signs included)'), SubtitleKind.dialogue);
  });

  test("the dub's captions", () {
    expect(kind(label: 'English CC'), SubtitleKind.forDub);
    expect(kind(label: 'English (SDH)'), SubtitleKind.forDub);
    expect(kind(release: 'Attack.on.Titan.S02E02.Dubtitles.1080p'),
        SubtitleKind.forDub);
    expect(kind(release: 'Show.S01E01.DUBBED.1080p.WEB'), SubtitleKind.forDub);
    expect(kind(label: 'Closed Captions'), SubtitleKind.forDub);
  });

  test('the usual translation, and a Dual Audio release name', () {
    expect(kind(label: 'English [Full]'), SubtitleKind.dialogue);
    expect(
        kind(
            release: '[AniDL] Shingeki no Kyojin S2 - E02 [27] [BD][720p]'
                '[10bit][Dual Audio][x265][Ranger]'),
        SubtitleKind.dialogue);
    expect(kind(), SubtitleKind.dialogue);
  });
}
