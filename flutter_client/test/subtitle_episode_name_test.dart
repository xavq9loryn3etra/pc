import 'package:flutter_client/services/subtitle_service.dart';
import 'package:flutter_test/flutter_test.dart';

SubtitleTrackData named(String name) =>
    SubtitleTrackData(id: name, url: 'u', lang: 'eng', releaseName: name);

/// Subtitles uploaded under the wrong episode are left out by their name
/// (SubtitleService.namesAnotherEpisode) — only when it's sure.
void main() {
  const s1e7 = [(1, 7)];

  test('another episode of the same season: left out', () {
    expect(SubtitleService.namesAnotherEpisode(
        named('Ghosts.2021.S01E05.1080p.WEB.H264-CAKES'), s1e7), isTrue);
    expect(SubtitleService.namesAnotherEpisode(named('ghosts 1x05 web'), s1e7),
        isTrue);
  });

  test('this episode, or a double one with it: kept', () {
    expect(SubtitleService.namesAnotherEpisode(
        named('Ghosts.2021.S01E07.1080p.WEB.H264-CAKES'), s1e7), isFalse);
    expect(SubtitleService.namesAnotherEpisode(
        named('Ghosts.S01E06E07.720p.HDTV'), s1e7), isFalse);
    expect(SubtitleService.namesAnotherEpisode(named('Ghosts 1x07 HDTV'), s1e7),
        isFalse);
  });

  test('a name that says nothing, or numbers it another way: kept', () {
    expect(SubtitleService.namesAnotherEpisode(named('Ghosts.WEB-DL'), s1e7),
        isFalse);
    expect(SubtitleService.namesAnotherEpisode(
        named('Ghosts.2021.S01.COMPLETE.1080p'), s1e7), isFalse);
    // Another season: long anime number episodes differently in different
    // places (One Piece: IMDb S13E27 is TMDB S12E408, a release S21E1085).
    expect(SubtitleService.namesAnotherEpisode(
        named('One.Piece.S21E1085.1080p'), const [(13, 27), (12, 408)]), isFalse);
    // A resolution or year isn't an episode.
    expect(SubtitleService.namesAnotherEpisode(
        named('Movie.2021.1920x1080.BluRay'), s1e7), isFalse);
  });

  test('the TMDB numbering counts too', () {
    expect(SubtitleService.namesAnotherEpisode(
        named('Show.S12E408.WEB'), const [(13, 27), (12, 408)]), isFalse);
    expect(SubtitleService.namesAnotherEpisode(
        named('Show.S12E407.WEB'), const [(13, 27), (12, 408)]), isTrue);
  });
}
