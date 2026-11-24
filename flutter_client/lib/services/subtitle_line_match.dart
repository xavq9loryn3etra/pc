import 'subtitle_sync.dart';

/// Times a downloaded subtitle copy by the video's own subtitles: the
/// lines built into the file are in time with it, so when the same words
/// show in both, the difference in when they show is the copy's timing.
///
/// The player follows a built-in track in the copy's language quietly (mpv's
/// secondary subtitle, never drawn: see the player's own subtitle view) and
/// hands each line it shows to [add]. Two separate lines that agree within
/// [_agree] seconds confirm the timing — as two stretches of listening do
/// (SubtitleTimingEvidence) — usually within the first few lines of talk,
/// where listening takes minutes. (The Mentalist S1E5, 24 Nov 2026: its
/// English was built in, so the Sinhala made from a downloaded English copy
/// waited minutes on "Syncing subtitles…" over English already in time.)
class SubtitleLineMatch {
  SubtitleLineMatch(List<SubtitleCue> cues)
      : _cues = [
          for (final c in cues)
            if (normalise(c.text).length >= _minLength)
              (start: c.start, key: normalise(c.text)),
        ];

  final List<({double start, String key})> _cues;

  /// Lines matched so far: when the video showed it, and when the copy does.
  final List<({double shown, double inFile, String key})> _pairs = [];

  /// Two delays this close confirm each other.
  static const double _agree = 0.4;

  /// Shorter lines ("Okay.", "Yeah.") repeat too often to place.
  static const int _minLength = 8;

  /// A line that begins another (one split in two in the other copy) has
  /// to be at least this long to count.
  static const int _minPrefix = 14;

  /// Whether any of the copy's lines could be matched at all.
  bool get isEmpty => _cues.isEmpty;

  /// The built-in line [text], shown from [start] (video time, seconds).
  /// Returns the copy's timing once it's confirmed — a subtitle at `t` in
  /// the copy shows at `t * speed + delay` — else null.
  ({double delay, double speed})? add(String text, double start) {
    final key = normalise(text);
    if (key.length < _minLength) return null;
    if (_pairs.any((p) => p.key == key)) return null;
    // Its place in the copy: the same words, or one beginning the other
    // (a line the two copies split differently starts at the same moment).
    // Only a line found once: a repeated one could be any of them.
    double? found;
    var count = 0;
    for (final c in _cues) {
      final same = c.key == key ||
          (key.length >= _minPrefix && c.key.startsWith(key)) ||
          (c.key.length >= _minPrefix && key.startsWith(c.key));
      if (!same) continue;
      count++;
      found = c.start;
      if (count > 1) return null;
    }
    if (found == null) return null;
    _pairs.add((shown: start, inFile: found, key: key));
    return _timing();
  }

  /// The timing the pairs agree on, if two do; else null. One delay when
  /// they agree on one; failing that, with three or more far apart along
  /// the video, a delay and a speed that fit them all (a copy for another
  /// frame rate drifts steadily).
  ({double delay, double speed})? _timing() {
    if (_pairs.length < 2) return null;
    final latest = _pairs.last;
    final d = latest.shown - latest.inFile;
    final agreeing = [
      for (final p in _pairs)
        if (((p.shown - p.inFile) - d).abs() <= _agree) p,
    ];
    if (agreeing.length >= 2) {
      final delay = agreeing
              .map((p) => p.shown - p.inFile)
              .reduce((a, b) => a + b) /
          agreeing.length;
      return (delay: delay, speed: 1.0);
    }
    if (_pairs.length < 3) return null;
    // A straight line through them: shown = inFile * speed + delay.
    final n = _pairs.length.toDouble();
    final mx = _pairs.map((p) => p.inFile).reduce((a, b) => a + b) / n;
    final my = _pairs.map((p) => p.shown).reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxy = 0.0;
    for (final p in _pairs) {
      sxx += (p.inFile - mx) * (p.inFile - mx);
      sxy += (p.inFile - mx) * (p.shown - my);
    }
    // Too close together to tell a speed from.
    if (sxx < 300 * 300) return null;
    final speed = sxy / sxx;
    if (speed < 0.9 || speed > 1.1) return null;
    final delay = my - speed * mx;
    final fit = _pairs
        .where((p) => (p.inFile * speed + delay - p.shown).abs() <= _agree)
        .length;
    return fit >= 3 ? (delay: delay, speed: speed) : null;
  }

  /// [text] as compared: no tags, speaker dashes or punctuation, lower
  /// case, single spaces.
  static String normalise(String text) => text
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
      .replaceAll(r'\N', ' ')
      .replaceAll(r'\n', ' ')
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}
