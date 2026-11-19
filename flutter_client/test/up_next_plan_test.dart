import 'package:flutter_client/services/skip_segments_service.dart';
import 'package:flutter_test/flutter_test.dart';

Duration s(int seconds) => Duration(seconds: seconds);

SkipSegment part(SkipSegmentType type, int from, [int? to]) => SkipSegment(
      type: type,
      start: s(from),
      end: to == null ? null : s(to),
      source: 'mkv',
    );

void main() {
  // Attack on Titan S2E3: 24:12, credits 22:00–23:30, then a preview.
  final length = s(1452);
  final anime = [
    part(SkipSegmentType.intro, 60, 150),
    part(SkipSegmentType.credits, 1320, 1410),
    part(SkipSegmentType.preview, 1410, 1452),
  ];

  test('before the credits: nothing, starting at the credits', () {
    final plan = UpNextPlan.at(anime, length, s(1200));
    expect(plan.stage, UpNextStage.none);
    expect(plan.start, s(1320));
  });

  test('the credits: Skip Credits to the preview, nothing counting', () {
    final plan = UpNextPlan.at(anime, length, s(1330));
    expect(plan.stage, UpNextStage.credits);
    expect(plan.previewStart, s(1410));
  });

  test('the preview: the fill follows it to its end', () {
    expect(UpNextPlan.at(anime, length, s(1410)).previewShare, 0);
    final half = UpNextPlan.at(anime, length, s(1431));
    expect(half.stage, UpNextStage.preview);
    expect(half.previewShare, closeTo(0.5, 0.01));
    expect(UpNextPlan.at(anime, length, length).previewShare, 1);
  });

  test('a preview with no credits known: up next with the preview', () {
    final plan = UpNextPlan.at(
        [part(SkipSegmentType.preview, 1410)], length, s(1300));
    expect(plan.stage, UpNextStage.none);
    expect(plan.start, s(1410));
    expect(UpNextPlan.at([part(SkipSegmentType.preview, 1410)], length,
            s(1420))
        .stage, UpNextStage.preview);
  });

  test('credits last: the countdown at their start, as before', () {
    final film = [part(SkipSegmentType.credits, 1350)];
    expect(UpNextPlan.at(film, length, s(1340)).stage, UpNextStage.none);
    final plan = UpNextPlan.at(film, length, s(1360));
    expect(plan.stage, UpNextStage.countdown);
    expect(plan.start, s(1350));
  });

  test('nothing known: the countdown 25 s from the end, as before', () {
    final plan = UpNextPlan.at(const [], length, s(1430));
    expect(plan.stage, UpNextStage.countdown);
    expect(plan.start, s(1427));
  });

  test('a preview mid-episode is not the end', () {
    final odd = [part(SkipSegmentType.preview, 100, 130)];
    expect(UpNextPlan.at(odd, length, s(110)).stage, UpNextStage.none);
  });
}
