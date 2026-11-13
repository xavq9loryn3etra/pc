import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_client/services/subtitle_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// [seconds] of made-up sound: a quiet hum and hiss, with a "voice" (a
/// buzzing 140 Hz tone with harmonics, swelling four times a second, as
/// syllables do) wherever [talk] has someone talking.
Int16List _sound(double seconds, List<SubtitleCue> talk, {int seed = 1}) {
  final rnd = math.Random(seed);
  const rate = SubtitleSync.sampleRate;
  final pcm = Int16List((seconds * rate).round());
  var c = 0;
  for (var i = 0; i < pcm.length; i++) {
    final t = i / rate;
    var v = 300 * math.sin(2 * math.pi * 60 * t) + 200 * (rnd.nextDouble() - .5);
    while (c < talk.length && talk[c].end < t) {
      c++;
    }
    if (c < talk.length && talk[c].start <= t) {
      final syllable = 0.5 + 0.5 * math.sin(2 * math.pi * 4 * t);
      var voice = 0.0;
      for (var h = 1; h <= 12; h++) {
        voice += math.sin(2 * math.pi * 140 * h * t) / h;
      }
      v += 4000 * syllable * voice;
    }
    pcm[i] = v.round().clamp(-32768, 32767);
  }
  return pcm;
}

/// Lines of talk, 1–4 s each with 0.5–4 s between, from 2 s to [until].
List<SubtitleCue> _talk(double until, {int seed = 7}) {
  final rnd = math.Random(seed);
  final cues = <SubtitleCue>[];
  var t = 2.0;
  while (true) {
    final length = 1 + rnd.nextDouble() * 3;
    if (t + length > until) break;
    cues.add(SubtitleCue(t, t + length));
    t += length + 0.5 + rnd.nextDouble() * 3.5;
  }
  return cues;
}

void main() {
  group('parseCues', () {
    test('SRT, leaving out sounds and songs', () {
      const srt = '1\r\n00:00:23,000 --> 00:00:24,500\r\nYou\'re a jerk, Thom.\r\n\r\n'
          '2\n00:00:25,000 --> 00:00:27,000\n[DOOR SLAMS]\n\n'
          '3\n00:00:28,000 --> 00:00:29,000\n♪ La la la ♪\n\n'
          '4\n01:02:03,4 --> 01:02:05,000\n<i>(whispering)</i> Over here.\n';
      final cues = SubtitleSync.parseCues(srt);
      expect(cues.length, 2);
      expect(cues[0].start, 23);
      expect(cues[0].end, 24.5);
      expect(cues[1].start, closeTo(3723.4, 1e-9));
    });

    test('WebVTT', () {
      const vtt = 'WEBVTT\n\n00:01.500 --> 00:03.000\nHi.\n\n'
          '1:00:00.000 --> 1:00:01.000 align:start\nBye.\n';
      final cues = SubtitleSync.parseCues(vtt);
      expect(cues.map((c) => c.start), [1.5, 3600]);
    });

    test('ASS, its text after the ninth comma', () {
      const ass = '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:05.50,0:00:07.25,Default,,0,0,0,,{\\i1}Well, hello\\Nthere{\\i0}\n'
          'Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,{\\an8}(sighs)\n';
      final cues = SubtitleSync.parseCues(ass);
      expect(cues.length, 1);
      expect(cues.single.start, 5.5);
      expect(cues.single.end, 7.25);
    });
  });

  group('find', () {
    const seconds = 240.0;
    final talk = _talk(seconds);
    final pcm = _sound(seconds, talk);

    test('subtitles 2.75 s early: shown 2.75 s later', () {
      final early = [
        for (final c in talk) SubtitleCue(c.start - 2.75, c.end - 2.75),
      ];
      final r = SubtitleSync.find(pcm, windowStart: 0, cues: early)!;
      expect(r.sure, isTrue);
      expect(r.speed, 1.0);
      expect(r.delay, closeTo(2.75, 0.1));
    });

    test('the sound from partway in, subtitles 12 s late', () {
      const from = 60.0;
      final part = pcm.sublist((from * SubtitleSync.sampleRate).round());
      final late = [for (final c in talk) SubtitleCue(c.start + 12, c.end + 12)];
      final r = SubtitleSync.find(part, windowStart: from, cues: late)!;
      expect(r.sure, isTrue);
      expect(r.delay, closeTo(-12, 0.1));
    });

    test('made for a 25 fps copy: sped up to fit', () {
      const speed = 25 / 23.976;
      final fast = [
        for (final c in talk) SubtitleCue(c.start / speed, c.end / speed),
      ];
      final r = SubtitleSync.find(pcm, windowStart: 0, cues: fast)!;
      expect(r.sure, isTrue);
      expect(r.speed, closeTo(speed, 1e-9));
      expect(r.delay, closeTo(0, 0.1));
    });

    test('subtitles for something else: not sure', () {
      final other = _talk(seconds, seed: 99);
      final r = SubtitleSync.find(pcm, windowStart: 0, cues: other);
      expect(r == null || !r.sure, isTrue);
    });

    test('too few subtitles around: no answer', () {
      final r = SubtitleSync.find(pcm,
          windowStart: 0, cues: const [SubtitleCue(5, 6), SubtitleCue(9, 10)]);
      expect(r, isNull);
    });
  });
}
