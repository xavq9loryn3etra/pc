import 'dart:math' as math;

import 'package:flutter_client/services/subtitle_retime.dart';
import 'package:flutter_client/services/subtitle_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lines of talk over [minutes]: 1–4 s each, 0.3–3 s apart.
List<SubtitleCue> _talk(double minutes, {int seed = 3}) {
  final rnd = math.Random(seed);
  final cues = <SubtitleCue>[];
  var t = 5.0;
  while (t < minutes * 60) {
    final len = 1 + rnd.nextDouble() * 3;
    cues.add(SubtitleCue(t, t + len));
    t += len + 0.3 + rnd.nextDouble() * 2.7;
  }
  return cues;
}

String _srt(List<SubtitleCue> cues) {
  String clock(double t) {
    final ms = (t * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},'
        '${(ms % 1000).toString().padLeft(3, '0')}';
  }

  return [
    for (var i = 0; i < cues.length; i++)
      '${i + 1}\n${clock(cues[i].start)} --> ${clock(cues[i].end)}\nLine $i\n',
  ].join('\n');
}

void main() {
  test('a step partway (an ad break): each side its own delay', () {
    final reference = _talk(20);
    // The other copy's subtitle: 2.5 s early, then 5 s early after 10 min.
    final other = [
      for (final c in reference)
        if (c.start < 600)
          SubtitleCue(c.start - 2.5, c.end - 2.5)
        else
          SubtitleCue(c.start - 5, c.end - 5),
    ];
    final map = SubtitleRetime.mapAgainst(other, reference)!;
    expect(map.speed, 1.0);
    expect(map.delayAt(120), closeTo(2.5, 0.15));
    expect(map.delayAt(1000), closeTo(5, 0.15));

    final fixed = SubtitleSync.parseCues(SubtitleRetime.retime(_srt(other), map));
    var near = 0;
    for (var i = 0; i < fixed.length; i++) {
      if ((fixed[i].start - reference[i].start).abs() <= 0.15) near++;
    }
    // All but those around the step (within the 3-minute windows' blur).
    expect(near, greaterThan(fixed.length * 0.9));
  });

  test('made for a 25 fps copy: sped up', () {
    final reference = _talk(15, seed: 5);
    const speed = 25 / 23.976;
    final other = [
      for (final c in reference) SubtitleCue(c.start / speed, c.end / speed),
    ];
    final map = SubtitleRetime.mapAgainst(other, reference)!;
    expect(map.speed, closeTo(speed, 1e-9));
    expect(map.delayAt(300), closeTo(0, 0.15));
  });

  test('subtitles for something else: no map', () {
    expect(
        SubtitleRetime.mapAgainst(_talk(15, seed: 1), _talk(15, seed: 2)),
        isNull);
  });

  test('rewrites SRT and ASS times, leaving the rest', () {
    const map = TimingMap(1.0, [(at: 0, delay: 2.0), (at: 100, delay: 3.5)]);
    final srt = SubtitleRetime.retime(
        '1\r\n00:00:10,000 --> 00:00:12,500\r\nHello, 00:00:10,000\r\n\r\n'
        '2\r\n00:02:00,000 --> 00:02:01,000\r\nLater.\r\n',
        map);
    expect(srt, contains('00:00:12,000 --> 00:00:14,500'));
    expect(srt, contains('00:02:03,500 --> 00:02:04,500'));
    expect(srt, contains('Hello, 00:00:10,000'));

    final ass = SubtitleRetime.retime(
        'Dialogue: 0,0:00:10.00,0:00:12.50,Default,,0,0,0,,Hi, there',
        map);
    expect(ass, 'Dialogue: 0,0:00:12.00,0:00:14.50,Default,,0,0,0,,Hi, there');
  });
}
