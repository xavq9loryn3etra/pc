import 'dart:math' as math;
import 'dart:typed_data';

import 'subtitle_sync.dart';

/// How a subtitle's times map onto the video, piece by piece: shown at
/// `t * speed + delayAt(t * speed)`. Found against a subtitle made for a
/// copy like the one playing (see [SubtitleRetime.mapAgainst]) — copies
/// differ not just by a constant: Ghosts S1E8's web-rip English subtitle
/// needs 2.6 s at the start of its Blu-ray copy and 5.6 s by the end, in
/// steps at the ad breaks.
class TimingMap {
  final double speed;

  /// Delays (seconds) at points along the video (seconds), in order.
  final List<({double at, double delay})> points;

  const TimingMap(this.speed, this.points);

  /// The delay at [videoTime]: the nearest point's.
  double delayAt(double videoTime) {
    var best = points.first;
    for (final p in points) {
      if ((p.at - videoTime).abs() < (best.at - videoTime).abs()) best = p;
    }
    return best.delay;
  }

  /// Where a subtitle time [t] shows.
  double map(double t) {
    final at = t * speed;
    return at + delayAt(at);
  }

  /// Whether [other] says the same, to within [tolerance] seconds, at
  /// [share] of the points or more. (Two references, timed by different
  /// people, differ by up to half a second or so — S1E8's Hebrew and Greek
  /// Blu-ray subtitles by 0.3–0.7 s; a mismatch is seconds out.)
  bool agreesWith(TimingMap other, {double tolerance = 0.8, double share = 0.8}) {
    if ((speed - other.speed).abs() > 0.001 || points.isEmpty) return false;
    var same = 0;
    for (final p in points) {
      if ((p.delay - other.delayAt(p.at)).abs() <= tolerance) same++;
    }
    return same >= points.length * share;
  }

  /// [other]'s and this one's, averaged where they're close: between two
  /// references' timing.
  TimingMap averagedWith(TimingMap other) => TimingMap(speed, [
        for (final p in points)
          (
            at: p.at,
            delay: (p.delay - other.delayAt(p.at)).abs() <= 1.0
                ? (p.delay + other.delayAt(p.at)) / 2
                : p.delay,
          ),
      ]);

  @override
  String toString() => 'speed ${speed.toStringAsFixed(4)}: ' +
      points
          .map((p) => '${(p.at / 60).toStringAsFixed(1)}m '
              '${p.delay >= 0 ? '+' : ''}${p.delay.toStringAsFixed(1)}')
          .join(', ');
}

/// Retiming a subtitle against another made for the copy playing — in any
/// language: what's compared is when lines are on screen, not what they
/// say. No sound needed, so it's done in a moment.
abstract final class SubtitleRetime {
  static const double _step = 0.1; // seconds per bin
  static const double _maxDelay = 60;
  static const double _window = 180; // seconds compared at each point
  static const double _every = 30; // seconds between points
  static const double _localReach = 15; // search around the overall delay

  /// How [cues] line up with [reference] (made for the copy playing): the
  /// speed (a 25 fps copy's subtitles, or not) and overall delay first,
  /// then the delay every 30 s, each from the 3 minutes around it. Points
  /// that don't match clearly take their neighbours'. Null when there's too
  /// little to go by, or no clear match overall.
  static TimingMap? mapAgainst(
    List<SubtitleCue> cues,
    List<SubtitleCue> reference,
  ) {
    if (cues.length < 20 || reference.length < 20) return null;
    final length = math.max(cues.last.end, reference.last.end) + _maxDelay + 5;
    final n = (length / _step).ceil();
    final ref = _coverage(reference, 1.0, 0, n);

    // Overall: each speed, every delay.
    final reach = (_maxDelay / _step).round();
    ({double speed, int shift, double score, double margin})? overall;
    for (final speed in SubtitleSync.speeds) {
      final sub = _coverage(cues, speed, reach, n + 2 * reach);
      final scores = _scores(ref, sub, 0, n, reach, -reach, reach);
      // Against shifts 5 s or more away: a subtitle that drifts along the
      // video (S1E8's, 2.6 s to 5.6 s) has no one shift clearly best
      // within a second or two.
      final r = _best(scores, -reach, apart: 5);
      if (overall == null || r.score > overall.score * 1.05) {
        overall = (speed: speed, shift: r.shift, score: r.score, margin: r.margin);
      }
    }
    if (overall == null || overall.margin < 0.03) return null;

    // Every 30 s: the delay around there, near the overall one.
    final sub = _coverage(cues, overall.speed, reach, n + 2 * reach);
    final local = (_localReach / _step).round();
    final half = (_window / 2 / _step).round();
    final points = <({double at, double delay, bool clear})>[];
    final last = math.min(cues.last.end * overall.speed, reference.last.end);
    for (var at = _every / 2; at < last; at += _every) {
      final centre = (at / _step).round();
      final from = math.max(0, centre - half);
      final to = math.min(n, centre + half);
      final lo = math.max(-reach, overall.shift - local);
      final hi = math.min(reach, overall.shift + local);
      final scores = _scores(ref, sub, from, to, reach, lo, hi);
      final r = _best(scores, lo);
      points.add((
        at: at,
        delay: r.shift * _step,
        clear: r.score > 0.2 && r.margin > 0.02,
      ));
    }
    if (points.where((p) => p.clear).length < points.length / 2) return null;

    // Unclear points: the nearest clear one's. Then each the middle of
    // itself and its neighbours, against a stray one.
    final filled = <double>[];
    for (var i = 0; i < points.length; i++) {
      if (points[i].clear) {
        filled.add(points[i].delay);
        continue;
      }
      var d = 1;
      while (true) {
        if (i - d >= 0 && points[i - d].clear) {
          filled.add(points[i - d].delay);
          break;
        }
        if (i + d < points.length && points[i + d].clear) {
          filled.add(points[i + d].delay);
          break;
        }
        d++;
      }
    }
    final smoothed = <double>[
      for (var i = 0; i < filled.length; i++)
        _median([
          filled[math.max(0, i - 1)],
          filled[i],
          filled[math.min(filled.length - 1, i + 1)],
        ]),
    ];
    return TimingMap(overall.speed, [
      for (var i = 0; i < points.length; i++)
        (at: points[i].at, delay: smoothed[i]),
    ]);
  }

  static double _median(List<double> v) => (List.of(v)..sort())[v.length ~/ 2];

  /// +1 where a cue is on screen, -1 where none is, every [_step]; cue
  /// times × [speed], starting [offset] bins in, [n] bins in all.
  static Int8List _coverage(List<SubtitleCue> cues, double speed, int offset, int n) {
    final v = Int8List(n)..fillRange(0, n, -1);
    for (final c in cues) {
      final a = math.max(0, (c.start * speed / _step).round() + offset);
      final b = math.min(n, (c.end * speed / _step).round() + offset);
      for (var k = a; k < b; k++) {
        v[k] = 1;
      }
    }
    return v;
  }

  /// Agreement (-1 to 1) of [ref] bins [from, to) with [sub] shifted by
  /// each shift in [lo, hi] (bins): the subtitle at bin k - shift + offset
  /// shown at bin k — i.e. a delay of shift bins.
  static Float64List _scores(Int8List ref, Int8List sub, int from, int to,
      int offset, int lo, int hi) {
    final out = Float64List(hi - lo + 1);
    final len = to - from;
    if (len <= 0) return out;
    for (var s = lo; s <= hi; s++) {
      var sum = 0;
      for (var k = from; k < to; k++) {
        sum += ref[k] * sub[k - s + offset];
      }
      out[s - lo] = sum / len;
    }
    return out;
  }

  /// The best shift of [scores] (index 0 is shift [lo]), its score, and how
  /// much better it is than the best one [apart] seconds or more away.
  static ({int shift, double score, double margin}) _best(
      Float64List scores, int lo, {double apart = 1}) {
    var best = 0;
    for (var i = 1; i < scores.length; i++) {
      if (scores[i] > scores[best]) best = i;
    }
    final away = (apart / _step).round();
    var runnerUp = -1.0;
    for (var i = 0; i < scores.length; i++) {
      if ((i - best).abs() >= away && scores[i] > runnerUp) runnerUp = scores[i];
    }
    return (
      shift: best + lo,
      score: scores[best],
      margin: scores[best] - runnerUp,
    );
  }

  // ─── Writing the subtitle anew ───

  static final RegExp _srtTimes = RegExp(
      r'((?:\d+:)?\d{1,2}:\d{2}([,.])\d{1,3})(\s*-->\s*)((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})');
  static final RegExp _assTimes =
      RegExp(r'^(Dialogue:\s*[^,]*,)(\d+:\d{2}:\d{2}\.\d{2}),(\d+:\d{2}:\d{2}\.\d{2}),');

  /// [text] (SRT, WebVTT or ASS) with every line's times moved as [map]
  /// says — each line by the delay where it starts, so it keeps its length
  /// (but for the speed).
  static String retime(String text, TimingMap map) {
    double moved(double t, double start) =>
        math.max(0, t * map.speed + map.delayAt(start * map.speed));
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      final ass = _assTimes.firstMatch(lines[i]);
      if (ass != null) {
        final a = _seconds(ass.group(2)!), b = _seconds(ass.group(3)!);
        if (a == null || b == null) continue;
        lines[i] = '${ass.group(1)}${_assClock(moved(a, a))},'
            '${_assClock(moved(b, a))},${lines[i].substring(ass.end)}';
        continue;
      }
      final m = _srtTimes.firstMatch(lines[i]);
      if (m == null) continue;
      final a = _seconds(m.group(1)!), b = _seconds(m.group(4)!);
      if (a == null || b == null) continue;
      final sep = m.group(2)!;
      lines[i] = lines[i].substring(0, m.start) +
          _clock(moved(a, a), sep) +
          m.group(3)! +
          _clock(moved(b, a), sep) +
          lines[i].substring(m.end);
    }
    return lines.join('\n');
  }

  static double? _seconds(String s) {
    final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})$').firstMatch(s);
    if (m == null) return null;
    return int.parse(m.group(1) ?? '0') * 3600 +
        int.parse(m.group(2)!) * 60 +
        int.parse(m.group(3)!) +
        int.parse(m.group(4)!.padRight(3, '0')) / 1000;
  }

  static String _clock(double t, String sep) {
    final ms = (t * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}'
        '$sep${(ms % 1000).toString().padLeft(3, '0')}';
  }

  static String _assClock(double t) {
    final cs = (t * 100).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${cs ~/ 360000}:${two(cs ~/ 6000 % 60)}:${two(cs ~/ 100 % 60)}.${two(cs % 100)}';
  }
}
