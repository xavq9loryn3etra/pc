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

  test('a broken reply keeps its whole lines', () {
    // A stray quote breaks the JSON after the second line.
    // (Raw: as Gemini sends it, its quotes in a line escaped.)
    const reply = r'[{"i": 3, "t": "හෙලෝ, ඩොක්."}, '
        r'{"i": 4, "t": "එයා කිව්වා \"හරි\" කියලා"}, '
        r'{"i": 5, "t": "broken" here"}, {"i": 6, "t": "යමු."}]';
    final lines = SubtitleTranslator.decodeReply(reply);
    final byId = {for (final l in lines.cast<Map>()) l['i']: l['t']};
    expect(byId[3], 'හෙලෝ, ඩොක්.');
    expect(byId[4], 'එයා කිව්වා "හරි" කියලා');
    expect(byId.containsKey(5), isFalse);
    expect(byId[6], 'යමු.');
  });

  test('English left in a line is a slip, unless it was in the line', () {
    expect(SubtitleTranslator.strayEnglish('තයර් screech හඬ', '[Tires squealing]'),
        isTrue);
    expect(SubtitleTranslator.strayEnglish('ය Dist යකෝ!', 'Holy shit!'), isTrue);
    expect(
        SubtitleTranslator.strayEnglish(
            '[Mr. Sandman සින්දුව වදිනවා]', '[Mr. Sandman playing]'),
        isFalse);
    expect(SubtitleTranslator.strayEnglish('යමු.', "Let's go."), isFalse);
  });

  test('a whole reply is read as it is', () {
    final lines = SubtitleTranslator.decodeReply('[{"i": 1, "t": "හරි"}]');
    expect(lines, [
      {'i': 1, 't': 'හරි'}
    ]);
  });
}
