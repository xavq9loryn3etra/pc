import 'dart:convert';
import 'package:dio/dio.dart';

/// Type of skippable segment in a movie or TV episode.
enum SkipSegmentType {
  recap('Skip Recap', 'Recap'),
  intro('Skip Intro', 'Intro'),
  credits('Skip Credits', 'Credits'),
  preview('Skip Preview', 'Preview');

  final String buttonLabel;
  final String shortLabel;
  const SkipSegmentType(this.buttonLabel, this.shortLabel);
}

/// A chapter from an embedded MKV/MP4 chapter list (`libmpv`'s `chapter-list`).
class VideoChapter {
  final String title;
  final Duration start;
  final Duration? end;

  const VideoChapter({
    required this.title,
    required this.start,
    this.end,
  });

  bool contains(Duration position, Duration totalDuration) {
    if (position < start) return false;
    final effectiveEnd = end ?? totalDuration;
    return effectiveEnd > start && position < effectiveEnd;
  }

  /// Display title if it's a meaningful chapter name (not a bare timestamp
  /// like `"00:05:12.000"` or generic `"Chapter 01"` when another label applies).
  String? get meaningfulTitle {
    final t = title.trim();
    if (t.isEmpty) return null;
    // Scene tools like mkvmerge often emit raw timestamps as chapter titles
    // ("00:04:12.000" or "00:04:12").
    if (RegExp(r'^\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?$').hasMatch(t)) {
      return null;
    }
    return t;
  }
}

/// A time range `[start, end]` in the video where a skip button should appear.
/// When [end] is `null` (e.g. end credits running to the end of the file),
/// the segment runs until the end of the video.
class SkipSegment {
  final SkipSegmentType type;
  final Duration start;
  final Duration? end;
  final String source; // 'mkv' | 'theintrodb' | 'introdb'

  /// For a skip-time service's segment: how long the copy of the video it
  /// was measured on was, when the service says (see
  /// SkipSegmentsService.alignToFile). Null for the file's own chapters.
  final Duration? referenceLength;

  const SkipSegment({
    required this.type,
    required this.start,
    this.end,
    required this.source,
    this.referenceLength,
  });

  SkipSegment _copy({
    Duration? start,
    Duration? end,
    bool clearEnd = false,
    Duration? referenceLength,
  }) =>
      SkipSegment(
        type: type,
        start: start ?? this.start,
        end: clearEnd ? null : (end ?? this.end),
        source: source,
        referenceLength: referenceLength ?? this.referenceLength,
      );

  /// Whether [position] falls inside this segment's active window.
  bool contains(Duration position, Duration totalDuration) {
    if (position < start) return false;
    final effectiveEnd = end ?? totalDuration;
    if (effectiveEnd <= start) return false;
    // Leave at least 1.5s before the end of the segment so tapping right as
    // it ends doesn't seek to the exact spot playback is already at.
    return position < effectiveEnd - const Duration(milliseconds: 1500);
  }

  /// Target timestamp to seek to when the user taps the skip button.
  Duration targetFor(Duration totalDuration) {
    if (end != null && end! > start) {
      if (totalDuration > Duration.zero && end! > totalDuration) {
        return totalDuration;
      }
      return end!;
    }
    return totalDuration;
  }

  @override
  String toString() =>
      'SkipSegment(${type.name}, ${start.inSeconds}s..${end?.inSeconds ?? "EOF"}s, $source)';
}

/// Resolves skippable segments (Intro, Recap, Credits, Preview) for movies
/// and TV episodes using:
/// 1. Embedded MKV/MP4 chapter markers from `libmpv` (`chapter-list`).
/// 2. Fallback crowdsourced databases:
///    - **TheIntroDB v3** (`api.theintrodb.org/v3/media`) — supports both
///      movies and TV episodes (by `imdb_id` or `tmdb_id`).
///    - **IntroDB** (`api.introdb.app/segments`) — supports TV episodes
///      (by `imdb_id`, `season`, `episode`).
class SkipSegmentsService {
  static final SkipSegmentsService _instance = SkipSegmentsService._internal();
  factory SkipSegmentsService() => _instance;
  SkipSegmentsService._internal();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      headers: const {'User-Agent': 'Popcorn/1.0'},
    ),
  );

  final Map<String, List<SkipSegment>> _apiCache = {};

  // Chapter title patterns commonly used in scene/p2p MKV releases. Words
  // that also name story scenes ("Opening", "Ending", "OP", "ED", "Next")
  // count only as the chapter's whole title — "The Ending" or "Opening
  // Scene" is part of the story. "Epilogue" is always story.
  static final _recapPattern = RegExp(
    r'\b(recap|previously\s+on)\b|^previously$',
    caseSensitive: false,
  );
  static final _introPattern = RegExp(
    r'\b(intro|open(ing)?\s+credits|opening\s+titles|title\s+sequence|main\s+titles?)\b'
    r'|^(opening|op\s*\d*|theme(\s+song)?)$',
    caseSensitive: false,
  );
  static final _creditsPattern = RegExp(
    r'\b(outro|end\s+credits|closing\s+credits|credits)\b'
    r'|^(ending|ed\s*\d*|end)$',
    caseSensitive: false,
  );
  static final _previewPattern = RegExp(
    r'\b(preview|next\s+episode|next\s+time)\b|^next$',
    caseSensitive: false,
  );

  /// Parses `libmpv`'s `chapter-list` JSON string into all [VideoChapter]s.
  List<VideoChapter> parseMpvChapters(
    String rawJson, {
    Duration totalDuration = Duration.zero,
  }) {
    if (rawJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List || decoded.isEmpty) return const [];

      final raw = <({String title, Duration start})>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final title = (item['title'] ?? '').toString().trim();
        final timeNum = item['time'];
        if (timeNum is! num || timeNum < 0) continue;
        raw.add((
          title: title,
          start: Duration(milliseconds: (timeNum * 1000).round()),
        ));
      }
      if (raw.isEmpty) return const [];
      raw.sort((a, b) => a.start.compareTo(b.start));

      return [
        for (var i = 0; i < raw.length; i++)
          VideoChapter(
            title: raw[i].title,
            start: raw[i].start,
            end: (i + 1 < raw.length)
                ? raw[i + 1].start
                : (totalDuration > raw[i].start ? totalDuration : null),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Parses `libmpv`'s `chapter-list` JSON string into labeled [SkipSegment]s.
  ///
  /// Each chapter in mpv's `chapter-list` has `{"title": "...", "time": 123.45}`.
  /// A matched chapter's segment ends where the next chapter begins (or at
  /// [totalDuration] if it's the final chapter).
  List<SkipSegment> parseMpvChapterList(
    String rawJson, {
    Duration totalDuration = Duration.zero,
  }) {
    final chapters = parseMpvChapters(rawJson, totalDuration: totalDuration);
    if (chapters.isEmpty) return const [];

    final segments = <SkipSegment>[];
    for (final ch in chapters) {
      if (ch.title.isEmpty) continue;
      final type = _classifyChapterTitle(ch.title);
      if (type == null) continue;

      final end = ch.end;
      // Sanity checks so generic chapter splits don't create bogus buttons:
      final length = end != null ? end - ch.start : null;
      if (length != null && length < const Duration(seconds: 5)) continue;
      if ((type == SkipSegmentType.intro ||
              type == SkipSegmentType.recap ||
              type == SkipSegmentType.preview) &&
          length != null &&
          length > const Duration(minutes: 6)) {
        continue;
      }
      // And where it sits: an intro or recap near the start, credits or a
      // preview near the end — so a misnamed chapter mid-story can't skip
      // (or, for credits, end the episode) from the middle. Credits are
      // capped too: 12 minutes is a long roll.
      if (totalDuration > Duration.zero) {
        final at = ch.start.inMilliseconds / totalDuration.inMilliseconds;
        final early = type == SkipSegmentType.intro ||
            type == SkipSegmentType.recap;
        if (early && at > 0.4) continue;
        if (!early && at < 0.6) continue;
      }
      if (type == SkipSegmentType.credits &&
          length != null &&
          length > const Duration(minutes: 12)) {
        continue;
      }

      segments.add(SkipSegment(
        type: type,
        start: ch.start,
        end: end,
        source: 'mkv',
      ));
    }
    return segments;
  }

  SkipSegmentType? _classifyChapterTitle(String title) {
    if (_recapPattern.hasMatch(title)) return SkipSegmentType.recap;
    if (_introPattern.hasMatch(title)) return SkipSegmentType.intro;
    if (_creditsPattern.hasMatch(title)) return SkipSegmentType.credits;
    if (_previewPattern.hasMatch(title)) return SkipSegmentType.preview;
    return null;
  }

  /// Fetches crowdsourced skip segments from TheIntroDB v3 and IntroDB.
  Future<List<SkipSegment>> fetchApiSegments({
    required String tmdbId,
    String? imdbId,
    required String type, // 'movie' or 'tv'
    int? season,
    int? episode,
  }) async {
    final isTv = type == 'tv' && season != null && episode != null;
    final cacheKey = isTv
        ? 'tv_${imdbId ?? tmdbId}_s${season}_e$episode'
        : 'movie_${imdbId ?? tmdbId}';
    final cached = _apiCache[cacheKey];
    if (cached != null) return cached;

    final results = await Future.wait([
      _fetchFromTheIntroDb(
        tmdbId: tmdbId,
        imdbId: imdbId,
        isTv: isTv,
        season: season,
        episode: episode,
      ),
      if (isTv && imdbId != null && imdbId.startsWith('tt'))
        _fetchFromIntroDbApp(
          imdbId: imdbId,
          season: season,
          episode: episode,
        ),
    ]);

    // Both services' segments, TheIntroDB's first (null: that lookup
    // failed). Not merged here: which of the two to use for a part both
    // have depends on the file played (see alignToFile) — they can differ
    // by minutes, measured on different copies.
    var theIntroDb = results.first ?? const <SkipSegment>[];
    final introDb = results.length > 1 ? results[1] : null;

    // Only IntroDB.app says how long its copy was. Where TheIntroDB's
    // times agree with it (a part both have, within 3 s), they were
    // measured on the same copy, and get that length too.
    final reference = introDb
        ?.map((s) => s.referenceLength)
        .whereType<Duration>()
        .firstOrNull;
    if (reference != null) {
      final sameCopy = theIntroDb.any((a) => introDb!.any((b) =>
          a.type == b.type &&
          (a.start - b.start).abs() <= const Duration(seconds: 3)));
      if (sameCopy) {
        theIntroDb = [
          for (final s in theIntroDb)
            s.referenceLength != null
                ? s
                : s._copy(referenceLength: reference),
        ];
      }
    }

    final merged = [...theIntroDb, ...?introDb];
    // Remembered only when every lookup got an answer: one that failed (no
    // connection, a timeout) is tried again the next time this is played.
    if (!results.contains(null)) _apiCache[cacheKey] = merged;
    return merged;
  }

  /// A lookup's failure: "nothing known for this title" (404) is an
  /// answer, and an empty list; anything else (no connection, a timeout,
  /// a server error) is null — not an answer, so not remembered.
  static List<SkipSegment>? _failure(Object error) =>
      error is DioException && error.response?.statusCode == 404
          ? const []
          : null;

  Future<List<SkipSegment>?> _fetchFromTheIntroDb({
    required String tmdbId,
    String? imdbId,
    required bool isTv,
    int? season,
    int? episode,
  }) async {
    try {
      final query = <String, dynamic>{
        if (imdbId != null && imdbId.startsWith('tt'))
          'imdb_id': imdbId
        else
          'tmdb_id': tmdbId,
        if (isTv) ...{
          'season': season,
          'episode': episode,
        },
      };
      final response = await _dio.get(
        'https://api.theintrodb.org/v3/media',
        queryParameters: query,
      );
      final data = response.data;
      if (data is! Map) return const [];

      final segments = <SkipSegment>[];
      void parseList(String key, SkipSegmentType segType) {
        final raw = data[key];
        if (raw is! List || raw.isEmpty) return;
        final first = raw.first;
        if (first is! Map) return;
        final startMs = (first['start_ms'] as num?)?.toInt();
        final endMs = (first['end_ms'] as num?)?.toInt();
        if (startMs == null && endMs == null) return;
        final start = Duration(milliseconds: startMs ?? 0);
        final end = endMs != null ? Duration(milliseconds: endMs) : null;
        if (end != null && end <= start) return;
        segments.add(SkipSegment(
          type: segType,
          start: start,
          end: end,
          source: 'theintrodb',
        ));
      }

      parseList('recap', SkipSegmentType.recap);
      parseList('intro', SkipSegmentType.intro);
      parseList('credits', SkipSegmentType.credits);
      parseList('preview', SkipSegmentType.preview);
      return segments;
    } catch (e) {
      return _failure(e);
    }
  }

  Future<List<SkipSegment>?> _fetchFromIntroDbApp({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    try {
      final response = await _dio.get(
        'https://api.introdb.app/segments',
        queryParameters: {
          'imdb_id': imdbId,
          'season': season,
          'episode': episode,
        },
      );
      final data = response.data;
      if (data is! Map) return const [];

      // The copy's length, near enough: where its credits end, when
      // nothing comes after them (no post-credits scene).
      Duration? reference;
      final outro = data['outro'];
      if (outro is Map && data['post_credits'] == null) {
        final endMs = (outro['end_ms'] as num?)?.toInt() ??
            ((outro['end_sec'] as num?) != null
                ? ((outro['end_sec'] as num) * 1000).round()
                : null);
        if (endMs != null && endMs > 0) {
          reference = Duration(milliseconds: endMs);
        }
      }

      final segments = <SkipSegment>[];
      void parseObj(String key, SkipSegmentType segType) {
        final obj = data[key];
        if (obj is! Map) return;
        final startMs = (obj['start_ms'] as num?)?.toInt() ??
            ((obj['start_sec'] as num?) != null
                ? ((obj['start_sec'] as num) * 1000).round()
                : null);
        final endMs = (obj['end_ms'] as num?)?.toInt() ??
            ((obj['end_sec'] as num?) != null
                ? ((obj['end_sec'] as num) * 1000).round()
                : null);
        if (startMs == null && endMs == null) return;
        final start = Duration(milliseconds: startMs ?? 0);
        final end = endMs != null ? Duration(milliseconds: endMs) : null;
        if (end != null && end <= start) return;
        segments.add(SkipSegment(
          type: segType,
          start: start,
          end: end,
          source: 'introdb',
          referenceLength: reference,
        ));
      }

      parseObj('recap', SkipSegmentType.recap);
      parseObj('intro', SkipSegmentType.intro);
      parseObj('outro', SkipSegmentType.credits);
      return segments;
    } catch (e) {
      return _failure(e);
    }
  }

  /// Fits a skip-time service's [segments] to the file being played, of
  /// length [fileLength]. Their times were measured on one copy of the
  /// video, and copies differ:
  ///  * sped up or slowed down for another frame rate (European TV copies
  ///    run at 25 frames a second, ~4% faster than film's 24): every time
  ///    scales with the length;
  ///  * otherwise longer or shorter (a recap, logos or other bits there or
  ///    not): credits and previews keep their distance from the end, which
  ///    they run up to — the intro and recap keep theirs from the start.
  /// Only where the copy's length is known (see [SkipSegment.
  /// referenceLength]) and differs by more than a few seconds. And anything
  /// past the file's end is dropped, or cut to it.
  List<SkipSegment> alignToFile(
    List<SkipSegment> segments,
    Duration fileLength,
  ) {
    if (fileLength <= Duration.zero) {
      return _pickPerType(segments, fileLength);
    }
    final aligned = <SkipSegment>[];
    for (final s in segments) {
      var seg = s;
      final reference = s.referenceLength;
      if (reference != null && reference > Duration.zero) {
        final diff = fileLength - reference;
        if (diff.abs() > const Duration(seconds: 4)) {
          final ratio = fileLength.inMilliseconds / reference.inMilliseconds;
          if (_isFrameRateChange(ratio)) {
            Duration scale(Duration d) =>
                Duration(milliseconds: (d.inMilliseconds * ratio).round());
            seg = s._copy(
              start: scale(s.start),
              end: s.end == null ? null : scale(s.end!),
            );
          } else if (s.type == SkipSegmentType.credits ||
              s.type == SkipSegmentType.preview) {
            final start = s.start + diff;
            seg = s._copy(
              start: start < Duration.zero ? Duration.zero : start,
              end: s.end == null ? null : s.end! + diff,
            );
          }
        }
      }
      if (seg.start >= fileLength) continue;
      if (seg.end != null && seg.end! > fileLength) {
        seg = seg._copy(clearEnd: true); // Up to the end.
      }
      if (seg.end != null && seg.end! <= seg.start) continue;
      aligned.add(seg);
    }
    return _pickPerType(aligned, fileLength);
  }

  /// One segment per part (intro, credits, …) out of both services' (see
  /// fetchApiSegments), already fitted to the file (see alignToFile):
  ///  1. one measured on a copy as long as the file (within 5 s) — this
  ///     very copy's times;
  ///  2. otherwise, for the credits and preview, the later of the two: one
  ///     too early skips story — and Skip Credits then plays the next
  ///     episode mid-scene — where one too late only leaves a few seconds
  ///     of credits to sit through;
  ///  3. otherwise TheIntroDB's, listed first.
  /// (Ghosts S1E5: TheIntroDB has the credits at 18:31, two minutes into
  /// the story; IntroDB.app at 20:49 on a 21:46 copy — and every other
  /// episode around it has them there too.)
  static List<SkipSegment> _pickPerType(
    List<SkipSegment> segments,
    Duration fileLength,
  ) {
    bool fits(SkipSegment s) =>
        fileLength > Duration.zero &&
        s.referenceLength != null &&
        (fileLength - s.referenceLength!).abs() <= const Duration(seconds: 5);
    bool better(SkipSegment s, SkipSegment have) {
      if (fits(have) != fits(s)) return fits(s);
      final atTheEnd = s.type == SkipSegmentType.credits ||
          s.type == SkipSegmentType.preview;
      return !fits(have) && atTheEnd && s.start > have.start;
    }

    final byType = <SkipSegmentType, SkipSegment>{};
    for (final s in segments) {
      final have = byType[s.type];
      if (have == null || better(s, have)) byType[s.type] = s;
    }
    return byType.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Whether a copy [ratio] times as long as another is it at another
  /// frame rate: 24 (or 23.976) frames a second against 25, either way.
  static bool _isFrameRateChange(double ratio) =>
      (ratio - 25 / 24).abs() < 0.004 ||
      (ratio - 25 / 23.976).abs() < 0.004 ||
      (ratio - 24 / 25).abs() < 0.004 ||
      (ratio - 23.976 / 25).abs() < 0.004;

  /// Combines embedded MKV chapters ([mkvSegments]) with fallback API
  /// segments ([apiSegments]), preferring MKV chapters for any segment type
  /// they already cover (since MKV chapters match the exact encoded video
  /// file, whereas API timestamps might differ across cuts).
  List<SkipSegment> merge({
    required List<SkipSegment> mkvSegments,
    required List<SkipSegment> apiSegments,
  }) {
    final coveredTypes = {for (final s in mkvSegments) s.type};
    final combined = <SkipSegment>[
      ...mkvSegments,
      for (final s in apiSegments)
        if (!coveredTypes.contains(s.type)) s,
    ];
    combined.sort((a, b) => a.start.compareTo(b.start));
    return combined;
  }
}
