// Retiming against reference subtitles, on Ghosts (US) S1E7 and S1E8:
// their English subtitles (web releases) against subtitles made for the
// Blu-ray (Hebrew and Arabic by one group, Greek by another). Runs only
// with SUBS_DIR set to a folder holding g7-*.srt and g8-*.srt (OpenSubtitles
// files, not in the repo).
import 'dart:io';

import 'package:flutter_client/services/subtitle_retime.dart';
import 'package:flutter_client/services/subtitle_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Platform.environment['SUBS_DIR'];

  List<SubtitleCue> cues(String name) =>
      SubtitleSync.parseCues(File('$dir/$name').readAsStringSync());

  for (final ep in ['g7', 'g8']) {
    test('$ep: the English subtitle retimed to the Blu-ray', () {
      final eng = cues('$ep-eng.srt');
      final heb = cues('$ep-heb-bluray.srt');
      final ell = cues('$ep-ell-bluray.srt');

      final sw = Stopwatch()..start();
      final toHeb = SubtitleRetime.mapAgainst(eng, heb)!;
      final toEll = SubtitleRetime.mapAgainst(eng, ell)!;
      print('$ep English → Hebrew Blu-ray (${sw.elapsedMilliseconds} ms '
          'for both): $toHeb');
      print('$ep English → Greek Blu-ray: $toEll');

      // Two references from different groups: the same answer.
      expect(toHeb.agreesWith(toEll), isTrue);

      // Retimed by the two together, checked against each: in time, to
      // within what they differ by themselves.
      final fixed = SubtitleSync.parseCues(SubtitleRetime.retime(
          File('$dir/$ep-eng.srt').readAsStringSync(),
          toHeb.averagedWith(toEll)));
      for (final (name, ref) in [('Hebrew', heb), ('Greek', ell)]) {
        final left = SubtitleRetime.mapAgainst(fixed, ref)!;
        print('$ep retimed English → $name Blu-ray: $left');
        final offs = [for (final p in left.points) p.delay.abs()]..sort();
        expect(offs[(offs.length * 0.8).floor()], lessThanOrEqualTo(0.5));
        expect(offs.last, lessThanOrEqualTo(1.0));
      }
    }, skip: dir == null);
  }

  test('a subtitle for something else: no map', () {
    final eng7 = cues('g7-eng.srt');
    final heb8 = cues('g8-heb-bluray.srt');
    final m = SubtitleRetime.mapAgainst(eng7, heb8);
    print('S1E7 English against S1E8 Hebrew: $m');
    // Either nothing, or two references wouldn't agree on it.
    final ell8 = cues('g8-ell-bluray.srt');
    final m2 = SubtitleRetime.mapAgainst(eng7, ell8);
    expect(m == null || m2 == null || !m.agreesWith(m2), isTrue);
  }, skip: dir == null);
}
