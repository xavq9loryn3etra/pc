import 'package:flutter_client/services/subtitle_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads an SRT, dropping formatting', () {
    const srt = '1\r\n'
        '00:00:01,500 --> 00:00:03,000\r\n'
        '<i>Hey, Doc.</i>\r\n'
        '\r\n'
        '2\r\n'
        '00:01:02,000 --> 00:01:04,250\r\n'
        "That's right, but I came back again\r\n"
        'from the future.\r\n'
        '\r\n';
    final cues = SubtitleTranslator.parse(srt);
    expect(cues.length, 2);
    expect(cues[0].start, 1.5);
    expect(cues[0].end, 3.0);
    expect(cues[0].text, 'Hey, Doc.');
    expect(cues[1].start, 62.0);
    expect(cues[1].text, "That's right, but I came back again\nfrom the future.");
  });

  test('reads a VTT', () {
    const vtt = 'WEBVTT\n\n'
        '00:00:05.000 --> 00:00:07.000\n'
        'Hello.\n\n'
        '01:02.500 --> 01:04.000\n'
        'Short times too.\n';
    final cues = SubtitleTranslator.parse(vtt);
    expect(cues.length, 2);
    expect(cues[1].start, 62.5);
  });

  test('reads an ASS', () {
    const ass = '[Events]\n'
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
        r'Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,{\i1}Wait,\Nwhat?'
        '\n';
    final cues = SubtitleTranslator.parse(ass);
    expect(cues.length, 1);
    expect(cues[0].start, 10.5);
    expect(cues[0].text, 'Wait,\nwhat?');
  });

  test('writes the lines translated so far, in order, with their times', () {
    const cues = [
      TextCue(1.5, 3, 'Hey, Doc.'),
      TextCue(4, 5, 'Calm down.'),
      TextCue(3661.007, 3662, 'Later.'),
    ];
    final srt = SubtitleTranslator.toSrt(cues, ['හෙලෝ, ඩොක්.', null, 'පස්සේ.']);
    expect(
        srt,
        '1\n00:00:01,500 --> 00:00:03,000\nහෙලෝ, ඩොක්.\n\n'
        '2\n01:01:01,007 --> 01:01:02,000\nපස්සේ.\n\n');
  });

  test('names files by their text, the same every time', () {
    expect(SubtitleTranslator.nameFor('abc'), SubtitleTranslator.nameFor('abc'));
    expect(SubtitleTranslator.nameFor('abc'),
        isNot(SubtitleTranslator.nameFor('abd')));
  });
}
