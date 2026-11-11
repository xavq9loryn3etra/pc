import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/services/skip_segments_service.dart';

// Breaking Bad S1E2 as IntroDB.app has it: intro 314.5–331 s, credits
// 2843–2901 s, measured on a copy 2901 s long.
const _reference = Duration(seconds: 2901);
const _intro = SkipSegment(
  type: SkipSegmentType.intro,
  start: Duration(milliseconds: 314500),
  end: Duration(seconds: 331),
  source: 'introdb',
  referenceLength: _reference,
);
const _credits = SkipSegment(
  type: SkipSegmentType.credits,
  start: Duration(seconds: 2843),
  end: Duration(seconds: 2901),
  source: 'introdb',
  referenceLength: _reference,
);

void main() {
  final service = SkipSegmentsService();

  test('a copy the same length (within a few seconds) is left alone', () {
    final out = service.alignToFile(
        [_intro, _credits], const Duration(seconds: 2903));
    expect(out[0].start, _intro.start);
    expect(out[1].start, _credits.start);
  });

  test('a 25 fps copy (~4% shorter) has every time scaled', () {
    final file = Duration(
        milliseconds: (_reference.inMilliseconds * 23.976 / 25).round());
    final out = service.alignToFile([_intro, _credits], file);
    expect(out[0].start.inMilliseconds / 1000, closeTo(301.6, 0.5));
    expect(out[1].start.inMilliseconds / 1000, closeTo(2726.6, 0.5));
  });

  test('a longer copy keeps credits their distance from the end', () {
    // 40 s longer (say, a recap the measured copy didn't have).
    final out = service.alignToFile(
        [_intro, _credits], const Duration(seconds: 2941));
    expect(out[0].start, _intro.start); // The intro: from the start.
    expect(out[1].start, const Duration(seconds: 2883));
    expect(out[1].end, const Duration(seconds: 2941)); // The file's end.
  });

  test('parts past the end of a shorter file are dropped', () {
    final out = service.alignToFile([
      const SkipSegment(
        type: SkipSegmentType.credits,
        start: Duration(seconds: 2843),
        source: 'theintrodb',
      ),
    ], const Duration(seconds: 1300));
    expect(out, isEmpty);
  });

  test('the service measured on a copy like the file wins (Ghosts S1E5)', () {
    const theIntroDb = SkipSegment(
      type: SkipSegmentType.credits,
      start: Duration(seconds: 1111),
      source: 'theintrodb',
    );
    const introDb = SkipSegment(
      type: SkipSegmentType.credits,
      start: Duration(seconds: 1249),
      end: Duration(seconds: 1306),
      source: 'introdb',
      referenceLength: Duration(seconds: 1306),
    );
    // A 21:47 file, as IntroDB.app's copy: its credits.
    var out = service.alignToFile(
        [theIntroDb, introDb], const Duration(seconds: 1307));
    expect(out.single.start, const Duration(seconds: 1249));
    // A copy 24 s longer: IntroDB.app's credits, kept their distance from
    // the end — still later than TheIntroDB's, which would cut into the
    // story.
    out = service.alignToFile(
        [theIntroDb, introDb], const Duration(seconds: 1330));
    expect(out.single.source, 'introdb');
    expect(out.single.start, const Duration(seconds: 1273));
    // TheIntroDB's later than IntroDB.app's (moved to a shorter copy): it.
    out = service.alignToFile(
        [theIntroDb, introDb], const Duration(seconds: 1150));
    expect(out.single.source, 'theintrodb');
  });

  test('chapter names: story scenes are not taken for skippable parts', () {
    String chapters(List<String> titles) => '[${[
          for (var i = 0; i < titles.length; i++)
            '{"title":"${titles[i]}","time":${i * 600}}'
        ].join(',')}]';
    final out = service.parseMpvChapterList(
      chapters(['Prologue', 'Opening Scene', 'Epilogue', 'The Ending',
          'Intro', 'End Credits']),
      totalDuration: const Duration(seconds: 3600),
    );
    // "Intro" at 40 min of 60 is too late to be one; "End Credits" fits.
    expect(out.map((s) => s.type), [SkipSegmentType.credits]);
  });
}
