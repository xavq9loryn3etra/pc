import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

/// One subtitle's time on screen, in the subtitle file's own seconds.
class SubtitleCue {
  final double start;
  final double end;

  const SubtitleCue(this.start, this.end);

  @override
  String toString() => 'SubtitleCue($start–$end)';
}

/// What [SubtitleSync.align] found: the subtitle timing (mpv's sub-delay
/// and sub-speed — a subtitle at `t` in its file shows at
/// `t * speed + delay`) that best lines the subtitles up with the talking.
class SubtitleSyncResult {
  final double delay;
  final double speed;

  /// How well the talking and the subtitles line up there (-1 to 1).
  final double score;

  /// How much better that is than the best timing seconds away from it:
  /// small when the sound gave no clear answer (music, little talking).
  final double margin;

  /// Clear enough to go by (see [SubtitleSync.find]).
  final bool sure;

  const SubtitleSyncResult({
    required this.delay,
    required this.speed,
    required this.score,
    required this.margin,
    this.sure = false,
  });

  SubtitleSyncResult _withSure(bool sure) => SubtitleSyncResult(
      delay: delay, speed: speed, score: score, margin: margin, sure: sure);

  @override
  String toString() => 'delay ${delay.toStringAsFixed(2)} s, speed '
      '${speed.toStringAsFixed(4)}, score ${score.toStringAsFixed(3)}, '
      'margin ${margin.toStringAsFixed(3)}${sure ? '' : ', not sure'}';
}

/// Lines subtitles up with a video's sound, in any language: not by what's
/// said, but by when — the moments people talk against the moments
/// subtitles are on screen (as ffsubsync and alass do).
abstract final class SubtitleSync {
  /// The sound [speechScores] takes: 16 kHz, mono, 16-bit (see
  /// [decodeSound]).
  static const int sampleRate = 16000;

  /// The least sound [find] is sure from.
  static const Duration minSure = Duration(seconds: 150);

  /// [speechScores]' step: 10 ms.
  static const double frameSeconds = 0.01;
  static const int _frameSamples = 160;

  /// The frame rate changes a subtitle may have been made for (European TV
  /// copies run 25 frames a second, film 23.976): the speeds tried.
  static const List<double> speeds = [1.0, 25 / 23.976, 23.976 / 25];

  /// The timing that lines [cues] up with [pcm] — the sound from
  /// [windowStart] seconds into the video, best several minutes of it (see
  /// [decodeSound]) — and whether it's sure: [minSure] of sound or more,
  /// clear, and found again by one half of it on its own. (Tried on Tears
  /// of Steel, its subtitles moved by known amounts: right to 0.1 s
  /// wherever there's talking; in its long battle with little said, wrong
  /// — and never sure. But where talk hardly stops, as in a sitcom, the
  /// pauses it goes by are few: Ghosts' first 75 s gave a confident wrong
  /// answer, 30 s out — hence the minutes, and the second opinion.) Null
  /// when there are too few subtitles around there to tell.
  static SubtitleSyncResult? find(
    Int16List pcm, {
    required double windowStart,
    required List<SubtitleCue> cues,
    double maxDelay = 60,
  }) {
    final whole = align(speechScores(pcm),
        windowStart: windowStart, cues: cues, maxDelay: maxDelay);
    if (whole == null) return null;
    if (whole.score < 0.12 || whole.margin < 0.05) return whole;
    if (pcm.length < minSure.inMilliseconds * sampleRate ~/ 1000) {
      return whole;
    }
    final half = pcm.length ~/ 2 ~/ _frameSamples * _frameSamples;
    bool agrees(SubtitleSyncResult? r) =>
        r != null &&
        r.margin >= 0.05 &&
        r.speed == whole.speed &&
        (r.delay - whole.delay).abs() <= 0.3;
    final first = align(speechScores(pcm.sublist(0, half)),
        windowStart: windowStart, cues: cues, maxDelay: maxDelay);
    if (agrees(first)) return whole._withSure(true);
    final second = align(speechScores(pcm.sublist(half)),
        windowStart: windowStart + half / sampleRate,
        cues: cues,
        maxDelay: maxDelay);
    return whole._withSure(agrees(second));
  }

  // ─── Subtitles ───

  static final RegExp _arrow = RegExp(
      r'((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})');

  /// The cues of an SRT, WebVTT or ASS/SSA subtitle file [text] — only
  /// those with words: "[door slams]", "(laughs)" and song lyrics (♪) are
  /// left out, as they aren't talking.
  static List<SubtitleCue> parseCues(String text) {
    final cues = <SubtitleCue>[];
    final lines = text.replaceAll('\r', '').split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('Dialogue:')) {
        // ASS: Dialogue: layer,start,end,style,name,ml,mr,mv,effect,text
        final fields = line.substring(9).split(',');
        if (fields.length < 10) continue;
        final start = _seconds(fields[1].trim());
        final end = _seconds(fields[2].trim());
        final words = fields.sublist(9).join(',');
        if (start != null && end != null && end > start && _isTalk(words)) {
          cues.add(SubtitleCue(start, end));
        }
        continue;
      }
      final m = _arrow.firstMatch(line);
      if (m == null) continue;
      final start = _seconds(m.group(1)!);
      final end = _seconds(m.group(2)!);
      final words = StringBuffer();
      while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
        i++;
        words.writeln(lines[i]);
      }
      if (start != null && end != null && end > start &&
          _isTalk(words.toString())) {
        cues.add(SubtitleCue(start, end));
      }
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  /// "01:02:03,450", "02:03.45" (ASS: hundredths), "1:02:03.4" → seconds.
  static double? _seconds(String s) {
    final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})$')
        .firstMatch(s);
    if (m == null) return null;
    final h = int.parse(m.group(1) ?? '0');
    final min = int.parse(m.group(2)!);
    final sec = int.parse(m.group(3)!);
    final ms = int.parse(m.group(4)!.padRight(3, '0'));
    return h * 3600 + min * 60 + sec + ms / 1000;
  }

  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);

  static bool _isTalk(String words) {
    if (words.contains('♪') || words.contains('♫')) return false;
    final spoken = words
        .replaceAll(RegExp(r'<[^>]*>'), ' ') // <i>, <font …>
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ') // ASS {\i1}
        .replaceAll(r'\N', ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ') // [door slams]
        .replaceAll(RegExp(r'\([^)]*\)'), ' '); // (laughs)
    return _letter.hasMatch(spoken);
  }

  // ─── The sound ───

  /// How speech-like the sound is, every 10 ms of [pcm] (16 kHz mono):
  /// the loudness of the voice's band (300–3400 Hz), less its average over
  /// the 10 seconds around — so a steady music bed or rumble doesn't count
  /// as talking, the comings and goings of voices do — scaled to a mean of
  /// 0 and a spread of 1.
  static Float64List speechScores(Int16List pcm) {
    final frames = pcm.length ~/ _frameSamples;
    final loud = Float64List(frames);
    final hp = _Biquad.highPass(300, sampleRate);
    final lp = _Biquad.lowPass(3400, sampleRate);
    for (var f = 0; f < frames; f++) {
      var energy = 0.0;
      final from = f * _frameSamples;
      for (var i = from; i < from + _frameSamples; i++) {
        final y = lp.step(hp.step(pcm[i].toDouble()));
        energy += y * y;
      }
      loud[f] = 10 * math.log(energy / _frameSamples + 1) / math.ln10;
    }
    // Less the average around it (5 s each way).
    const half = 500;
    final sums = Float64List(frames + 1);
    for (var f = 0; f < frames; f++) {
      sums[f + 1] = sums[f] + loud[f];
    }
    final scores = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      final a = math.max(0, f - half);
      final b = math.min(frames, f + half + 1);
      scores[f] = loud[f] - (sums[b] - sums[a]) / (b - a);
    }
    _standardize(scores, clip: 3);
    return scores;
  }

  /// Scales [v] to a mean of 0 and a spread of 1, cut off at ±[clip].
  static void _standardize(Float64List v, {double? clip}) {
    if (v.isEmpty) return;
    var mean = 0.0;
    for (final x in v) {
      mean += x;
    }
    mean /= v.length;
    var variance = 0.0;
    for (final x in v) {
      variance += (x - mean) * (x - mean);
    }
    final sd = math.sqrt(variance / v.length);
    for (var i = 0; i < v.length; i++) {
      var z = sd > 0 ? (v[i] - mean) / sd : 0.0;
      if (clip != null) z = z.clamp(-clip, clip);
      v[i] = z;
    }
  }

  // ─── Lining them up ───

  /// The timing that best lines [cues] up with the talking in [scores]
  /// ([speechScores] of the sound from [windowStart] seconds into the
  /// video): every delay up to [maxDelay] seconds either way, at each of
  /// [speeds]. Null when too few cues fall around there to tell.
  static SubtitleSyncResult? align(
    Float64List scores, {
    required double windowStart,
    required List<SubtitleCue> cues,
    double maxDelay = 60,
  }) {
    final windowEnd = windowStart + scores.length * frameSeconds;
    // Enough talking around here to go by?
    final near = cues
        .where((c) =>
            c.end > windowStart - maxDelay && c.start < windowEnd + maxDelay)
        .length;
    if (near < 8 || scores.length < 3000) return null;

    // First every 100 ms, over the whole range…
    const coarse = 0.1;
    const per = 10; // frames in a coarse step
    final talk = Float64List(scores.length ~/ per);
    for (var j = 0; j < talk.length; j++) {
      var sum = 0.0;
      for (var k = 0; k < per; k++) {
        sum += scores[j * per + k];
      }
      talk[j] = sum / per;
    }
    _standardize(talk);

    ({double delay, double score, double margin})? bestAt(double speed) {
      final reach = (maxDelay / coarse).round();
      final curve = _correlate(talk, cues, speed,
          from: windowStart - maxDelay, step: coarse, shifts: 2 * reach + 1);
      var best = -1;
      for (var o = 0; o < curve.length; o++) {
        if (best < 0 || curve[o] > curve[best]) best = o;
      }
      if (best < 0) return null;
      // The best timing 2 s or more away from it.
      var runnerUp = -1.0;
      for (var o = 0; o < curve.length; o++) {
        if ((o - best).abs() * coarse >= 2 && curve[o] > runnerUp) {
          runnerUp = curve[o];
        }
      }
      return (
        delay: maxDelay - best * coarse,
        score: curve[best],
        margin: curve[best] - runnerUp,
      );
    }

    // At film speed, and the frame rate changes: one of those only when
    // clearly better (a little stretch can always be bent to fit).
    final atSpeed = {
      for (final s in speeds) s: bestAt(s),
    };
    var speed = 1.0;
    var best = atSpeed[1.0];
    if (best == null) return null;
    for (final s in speeds.skip(1)) {
      final r = atSpeed[s];
      if (r != null && r.score > best!.score * 1.15 + 0.02) {
        best = r;
        speed = s;
      }
    }

    // …then to 10 ms, around the best.
    final talkFine = Float64List.fromList(scores);
    _standardize(talkFine);
    const span = 0.3;
    final fine = _correlate(talkFine, cues, speed,
        from: windowStart - (best!.delay + span),
        step: frameSeconds,
        shifts: (2 * span / frameSeconds).round() + 1);
    var o = 0;
    for (var i = 1; i < fine.length; i++) {
      if (fine[i] > fine[o]) o = i;
    }
    return SubtitleSyncResult(
      delay: best.delay + span - o * frameSeconds,
      speed: speed,
      score: best.score,
      margin: best.margin,
    );
  }

  /// How well [talk] (standardized, every [step] seconds of the window)
  /// lines up with [cues] shown at [speed] — at each shift: shift `at`
  /// compares the window with the cues' coverage from `from + at * step`,
  /// i.e. a delay of `windowStart - from - at * step`. (Pearson's
  /// correlation: [talk] has a mean of 0 and a spread of 1.)
  static Float64List _correlate(
    Float64List talk,
    List<SubtitleCue> cues,
    double speed, {
    required double from,
    required double step,
    required int shifts,
  }) {
    final n = talk.length;
    final length = n + shifts - 1;
    // How much of each step a cue covers (0–1).
    final on = Float64List(length);
    for (final c in cues) {
      final a = (c.start * speed - from) / step;
      final b = (c.end * speed - from) / step;
      if (b <= 0 || a >= length) continue;
      final first = math.max(0, a.floor());
      final last = math.min(length - 1, b.ceil() - 1);
      for (var k = first; k <= last; k++) {
        final cover = math.min(b, k + 1.0) - math.max(a, k.toDouble());
        if (cover > 0) on[k] = math.min(1, on[k] + cover);
      }
    }
    final sum = Float64List(length + 1);
    final sumSq = Float64List(length + 1);
    for (var k = 0; k < length; k++) {
      sum[k + 1] = sum[k] + on[k];
      sumSq[k + 1] = sumSq[k] + on[k] * on[k];
    }
    // Shift `at`: the window's step j against on[at + j] — a delay of
    // windowStart - from - at * step.
    final curve = Float64List(shifts);
    for (var at = 0; at < shifts; at++) {
      final mean = (sum[at + n] - sum[at]) / n;
      final variance = (sumSq[at + n] - sumSq[at]) / n - mean * mean;
      if (variance <= 1e-9) {
        curve[at] = 0;
        continue;
      }
      var dot = 0.0;
      for (var j = 0; j < n; j++) {
        dot += talk[j] * on[at + j];
      }
      curve[at] = dot / n / math.sqrt(variance);
    }
    return curve;
  }

  // ─── Getting the sound ───

  /// The sound of [url] from [start] to [end] (seconds), as [speechScores]
  /// takes it — decoded by a second, silent player as fast as it can
  /// (mpv: no picture, sound written to a file rather than played, not in
  /// real time) — [audioTrack]'s (mpv's id), the one being heard, when
  /// there's a choice. Null if it couldn't be, or when [isCancelled] turns
  /// true (checked twice a second): the player closed or moved to another
  /// video, so there's no reason to go on reading the stream.
  static Future<Int16List?> decodeSound(
    String url, {
    required double start,
    required double end,
    String? audioTrack,
    Duration timeout = const Duration(minutes: 3),
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) return null;
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
        'popcorn_sync_${DateTime.now().microsecondsSinceEpoch}.pcm');
    final player = Player();
    final cancelled = Completer<void>();
    var failed = false; // Nothing will read the file: delete it.
    Timer? cancelPoll;
    if (isCancelled != null) {
      cancelPoll = Timer.periodic(const Duration(milliseconds: 500), (t) {
        if (!isCancelled()) return;
        t.cancel();
        cancelled.complete();
      });
    }
    try {
      final mpv = player.platform as NativePlayer;
      for (final p in {
        'vid': 'no',
        'sid': 'no',
        if (audioTrack != null) 'aid': audioTrack,
        'ao': 'pcm',
        'ao-pcm-file': file.path,
        'ao-pcm-waveheader': 'no',
        'audio-samplerate': '$sampleRate',
        'audio-channels': 'mono',
        'audio-format': 's16',
        'untimed': 'yes',
      }.entries) {
        await mpv.setProperty(p.key, p.value);
      }
      // orElse: closing the player ends the stream; that mustn't throw.
      final done =
          player.stream.completed.firstWhere((c) => c, orElse: () => false);
      Duration at(double seconds) =>
          Duration(milliseconds: (seconds * 1000).round());
      await player.open(Media(url, start: at(start), end: at(end)));
      try {
        await Future.any([done.timeout(timeout), cancelled.future]);
      } on TimeoutException {
        // The rest isn't downloaded yet: what's been heard so far.
        print('[sync] stopped listening after ${timeout.inSeconds} s');
      }
      if (cancelled.isCompleted) {
        failed = true;
        return null;
      }
    } catch (e) {
      print('[sync] couldn\'t get the sound: $e');
      failed = true;
      return null;
    } finally {
      cancelPoll?.cancel();
      // Closing it finishes the file.
      await player.dispose();
      if (failed) file.delete().ignore();
    }
    try {
      final bytes = await file.readAsBytes();
      final samples = bytes.lengthInBytes ~/ 2;
      final pcm = Int16List(samples);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < samples; i++) {
        pcm[i] = data.getInt16(i * 2, Endian.little);
      }
      return pcm;
    } catch (_) {
      return null;
    } finally {
      file.delete().ignore();
    }
  }
}

/// A second-order filter (RBJ's cookbook), 0.707 Q.
class _Biquad {
  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _Biquad.lowPass(double hz, int rate) {
    final w = 2 * math.pi * hz / rate;
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final c = math.cos(w);
    final a0 = 1 + alpha;
    return _Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0,
        -2 * c / a0, (1 - alpha) / a0);
  }

  factory _Biquad.highPass(double hz, int rate) {
    final w = 2 * math.pi * hz / rate;
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final c = math.cos(w);
    final a0 = 1 + alpha;
    return _Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0,
        -2 * c / a0, (1 - alpha) / a0);
  }

  double step(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
