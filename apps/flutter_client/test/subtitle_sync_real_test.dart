// Auto Sync on real sound: Tears of Steel (Blender Foundation, CC BY 3.0) —
// its sound as SubtitleSync.decodeSound gives it (16 kHz mono 16-bit, e.g.
// from https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov)
// and its subtitles (…/ToS/subtitles/TOS-en.srt), moved by known amounts.
// Runs only with SYNC_PCM and SYNC_SRT (';'-separated) set: the files
// aren't in the repo.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_client/services/subtitle_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pcmPath = Platform.environment['SYNC_PCM'];
  final srtPaths = Platform.environment['SYNC_SRT']?.split(';');

  test('right wherever it is sure; sure where there is talking', () {
    final bytes = File(pcmPath!).readAsBytesSync();
    final pcm = Int16List.view(bytes.buffer, 0, bytes.lengthInBytes ~/ 2);
    var sure = 0, all = 0;
    for (final srt in srtPaths!) {
      final cues = SubtitleSync.parseCues(File(srt).readAsStringSync());
      for (var start = 0.0; start <= 380; start += 50) {
        const length = 360.0;
        final to = math.min(((start + length) * 16000).round(), pcm.length);
        final part = pcm.sublist((start * 16000).round(), to);
        final asIs = SubtitleSync.find(part, windowStart: start, cues: cues);
        for (final (shift, speed) in [
          (0.0, 1.0),
          (3.5, 1.0),
          (-7.25, 1.0),
          (41.0, 1.0),
          (0.0, 25 / 23.976),
          (2.0, 23.976 / 25),
        ]) {
          // Made for a copy where, shown at t * speed + shift, it's right:
          // its own times are (t - shift) / speed.
          final moved = [
            for (final c in cues)
              SubtitleCue((c.start - shift) / speed, (c.end - shift) / speed),
          ];
          final r =
              SubtitleSync.find(part, windowStart: start, cues: moved);
          all++;
          // printOnFailure: what each window found.
          printOnFailure('${srt.split('/').last} @$start '
              '$shift/$speed: $r');
          if (r == null || !r.sure) continue;
          sure++;
          // Against the subtitles' own timing as found unmoved (they're
          // hand-timed to half seconds).
          final want = asIs!.delay * speed + shift;
          expect(r.speed, closeTo(speed, 0.001));
          expect(r.delay, closeTo(want, 0.3));
        }
      }
    }
    // Talking in the first 6+ minutes: those windows are sure.
    expect(sure, greaterThanOrEqualTo(all * 0.6));
  },
      skip: pcmPath == null || srtPaths == null,
      timeout: const Timeout(Duration(minutes: 5)));
}
