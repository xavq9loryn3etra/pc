import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/services/subtitle_line_match.dart';
import 'package:flutter_client/services/subtitle_sync.dart';

const _srt = '''
1
00:00:05,000 --> 00:00:07,000
Okay.

2
00:00:10,000 --> 00:00:12,500
<i>Where were you last night, Mr. Jane?</i>

3
00:00:20,000 --> 00:00:22,000
- I was at home.
- Alone?

4
00:00:30,000 --> 00:00:33,000
Okay.

5
00:01:00,000 --> 00:01:03,000
The victim knew her killer, that much is obvious.

6
00:01:10,000 --> 00:01:12,000
You can't be serious about this.
''';

void main() {
  final cues = SubtitleSync.parseCues(_srt);

  test('keeps each line\'s words', () {
    expect(cues.first.text, contains('Okay.'));
    expect(cues[1].text, contains('Where were you last night'));
  });

  test('two lines agreeing confirm the delay', () {
    final match = SubtitleLineMatch(cues);
    // The built-in English shows them 2.3 s later than this copy has them.
    expect(match.add('Where were you last night, Mr. Jane?', 12.3), isNull);
    final timing =
        match.add('The victim knew her killer, that much is obvious.', 62.3);
    expect(timing, isNotNull);
    expect(timing!.delay, closeTo(2.3, 0.01));
    expect(timing.speed, 1.0);
  });

  test('short and repeated lines are not used', () {
    final match = SubtitleLineMatch(cues);
    expect(match.add('Okay.', 7.3), isNull);
    expect(match.add('Okay.', 32.3), isNull);
    // Still needs two real lines.
    expect(match.add('You can\'t be serious about this.', 72.3), isNull);
  });

  test('lines that disagree do not confirm', () {
    final match = SubtitleLineMatch(cues);
    expect(match.add('Where were you last night, Mr. Jane?', 12.3), isNull);
    expect(
        match.add('The victim knew her killer, that much is obvious.', 65.0),
        isNull);
    // A third agreeing with the first confirms that one.
    final timing = match.add('You can\'t be serious about this.', 72.3);
    expect(timing!.delay, closeTo(2.3, 0.01));
  });

  test('a line split differently still matches by its start', () {
    final match = SubtitleLineMatch(cues);
    // The built-in copy has only the first half of line 5.
    expect(match.add('Where were you last night, Mr. Jane?', 9.0), isNull);
    final timing = match.add('The victim knew her killer,', 59.0);
    expect(timing!.delay, closeTo(-1.0, 0.01));
  });

  test('tags, dashes and case are ignored', () {
    expect(SubtitleLineMatch.normalise('- <i>I was at HOME.</i>\n- Alone?'),
        'i was at home alone');
  });

  test('a steady drift (another frame rate) is found from three far apart',
      () {
    const speed = 25 / 23.976;
    final long = [
      for (var i = 0; i < 40; i++)
        SubtitleCue(i * 60.0, i * 60.0 + 2, 'Line number $i is quite unique'),
    ];
    final match = SubtitleLineMatch(long);
    ({double delay, double speed})? timing;
    for (final i in [2, 15, 30]) {
      timing = match.add('Line number $i is quite unique', i * 60.0 * speed);
    }
    expect(timing, isNotNull);
    expect(timing!.speed, closeTo(speed, 0.001));
    expect(timing.delay, closeTo(0, 0.05));
  });
}
