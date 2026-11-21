part of '../player_screen.dart';

extension _PlayerSkipIntro on _PlayerScreenState {
  // ─── Skip Intro / Recap / Credits / Preview (MKV chapters + API fallback) ───

  Future<void> _onMpvChapterList(String rawJson) async {
    if (!mounted) return;
    _lastRawChapterList = rawJson;
    _mkvChapters = SkipSegmentsService().parseMpvChapters(
      rawJson,
      totalDuration: _duration,
    );
    _mkvSkipSegments = SkipSegmentsService().parseMpvChapterList(
      rawJson,
      totalDuration: _duration,
    );
    _rebuildSkipSegments();
  }

  void _reparseMkvChaptersForDuration(Duration dur) {
    // No chapters: the skip-time services' parts are still fitted to the
    // file's length, now it's known (see _rebuildSkipSegments).
    if (_lastRawChapterList.isEmpty) {
      _rebuildSkipSegments();
      return;
    }
    _mkvChapters = SkipSegmentsService().parseMpvChapters(
      _lastRawChapterList,
      totalDuration: dur,
    );
    _mkvSkipSegments = SkipSegmentsService().parseMpvChapterList(
      _lastRawChapterList,
      totalDuration: dur,
    );
    _rebuildSkipSegments();
  }

  Future<void> _loadApiSkipSegments() async {
    final season = _currentSeason;
    final episode = _currentEpisode;
    final segments = await SkipSegmentsService().fetchApiSegments(
      tmdbId: widget.details.id,
      imdbId: widget.details.imdbId ?? widget.movie.imdbId,
      type: widget.details.type,
      season: season,
      episode: episode,
    );
    if (!mounted || season != _currentSeason || episode != _currentEpisode) {
      return;
    }
    _apiSkipSegments = segments;
    _rebuildSkipSegments();
  }

  void _rebuildSkipSegments() {
    _skipSegments = SkipSegmentsService().merge(
      mkvSegments: _mkvSkipSegments,
      // Measured on some copy of the video; fitted to this file.
      apiSegments:
          SkipSegmentsService().alignToFile(_apiSkipSegments, _duration),
    );
    _logSkipSegments();
    _updateTimelineShapes();
    _timelinePartitionRevision.value++;
    _updateActiveSkipSegment(_currentPosition);
  }

  /// Logs the skip times this file got, and where from ("[skip] 21:46
  /// long: credits 20:49–end (introdb)") — for when a Skip button's in the
  /// wrong place: was it the data, or the fitting to this file?
  void _logSkipSegments() {
    if (_duration <= Duration.zero) return;
    String clock(Duration d) =>
        '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    final parts = [
      for (final s in _skipSegments)
        '${s.type.name} ${clock(s.start)}–'
            '${s.end == null ? 'end' : clock(s.end!)} (${s.source})',
    ];
    final line = '[skip] S${_currentSeason ?? '-'}E${_currentEpisode ?? '-'}, '
        '${clock(_duration)} long: '
        '${parts.isEmpty ? 'nothing to skip' : parts.join(', ')}';
    if (line == _lastSkipLog) return;
    _lastSkipLog = line;
    print(line);
  }

  void _updateTimelineShapes() {
    _skipRanges = _skipRangesFor(_duration);
    _partitions = _partitionFractionsFor(_duration);
  }

  /// Normalized `(start, end)` fraction ranges (`0.0..1.0`) for skippable
  /// segments (`Intro`, `Recap`, `Credits`, `Preview`) on the seek bar.
  List<({double start, double end})> _skipRangesFor(Duration totalDuration) {
    final totalMs = totalDuration.inMilliseconds;
    if (totalMs <= 0 || _skipSegments.isEmpty) return const [];
    final ranges = <({double start, double end})>[];
    for (final s in _skipSegments) {
      final startFrac = (s.start.inMilliseconds / totalMs).clamp(0.0, 1.0);
      final endMs = (s.end ?? totalDuration).inMilliseconds;
      final endFrac = (endMs / totalMs).clamp(0.0, 1.0);
      if (endFrac - startFrac >= 0.003) {
        ranges.add((start: startFrac, end: endFrac));
      }
    }
    return ranges;
  }

  /// Normalized boundary fractions (`0.0 < f < 1.0`) where the seek bar
  /// draws a partition gap (MKV chapters + skip segment boundaries).
  List<double> _partitionFractionsFor(Duration totalDuration) {
    final totalMs = totalDuration.inMilliseconds;
    if (totalMs <= 0) return const [];
    final rawPoints = <double>[];
    // Chapters only when there are a few: an episode's parts (opening,
    // the episode, ending). A film's disc copy has 20 or more, which cut
    // the bar into pieces; their names still show when it's pointed at.
    final fewChapters = _mkvChapters.length <= _PlayerScreenState._maxChapterGaps;
    for (final ch in fewChapters ? _mkvChapters : const <VideoChapter>[]) {
      // Not inside a highlighted part: a chapter starting partway through
      // the credits cut them in two, which read as two credit sections.
      final inside = _skipSegments
          .any((s) => s.end != null && ch.start > s.start && ch.start < s.end!);
      if (inside) continue;
      final f = ch.start.inMilliseconds / totalMs;
      if (f > 0.008 && f < 0.992) rawPoints.add(f);
    }
    for (final s in _skipSegments) {
      final sf = s.start.inMilliseconds / totalMs;
      if (sf > 0.008 && sf < 0.992) rawPoints.add(sf);
      if (s.end != null) {
        final ef = s.end!.inMilliseconds / totalMs;
        if (ef > 0.008 && ef < 0.992) rawPoints.add(ef);
      }
    }
    if (rawPoints.isEmpty) return const [];
    rawPoints.sort();
    // Deduplicate points that are within 0.6% of total duration so adjacent
    // markers don't chew up the track.
    final deduped = <double>[rawPoints.first];
    for (var i = 1; i < rawPoints.length; i++) {
      if (rawPoints[i] - deduped.last >= 0.006) {
        deduped.add(rawPoints[i]);
      }
    }
    return deduped;
  }

  /// Chapter or skip-segment label for [position] to show inside the seek
  /// bar's hover/drag tooltip (e.g. `"Intro"`, `"Credits"`, or an MKV
  /// chapter title).
  String? _segmentLabelAt(Duration position, Duration totalDuration) {
    if (totalDuration <= Duration.zero) return null;
    for (final seg in _skipSegments) {
      final end = seg.end ?? totalDuration;
      if (position >= seg.start && position < end) {
        return seg.type.shortLabel;
      }
    }
    for (final ch in _mkvChapters) {
      if (ch.contains(position, totalDuration)) {
        return ch.meaningfulTitle;
      }
    }
    return null;
  }

  void _updateActiveSkipSegment(Duration pos) {
    if (_loadingVideo || _skipSegments.isEmpty) {
      if (_activeSkipSegmentNotifier.value != null) {
        _activeSkipSegmentNotifier.value = null;
      }
      return;
    }
    SkipSegment? active;
    for (final seg in _skipSegments) {
      if (seg.contains(pos, _duration)) {
        active = seg;
        break;
      }
    }
    if (_activeSkipSegmentNotifier.value != active) {
      _activeSkipSegmentNotifier.value = active;
      if (active != null) unawaited(_readySkipTarget(active));
    }
  }

  /// While its Skip button shows, has the engine fetch the spot [segment]
  /// skips to, a few MB there — so the skip lands on video that's already
  /// downloaded. (Not by reading it from the stream: the engine took a
  /// read that big for the player moving there, and dropped what playback
  /// needed.) A Skip Intro (a minute and a half on, in
  /// one go) waited on a slow copy, where the arrows' 10 s jumps, into
  /// what was already loaded, didn't. Where in the file that spot is comes
  /// from its share of the running time, read with some margin either
  /// side; a copy whose size isn't known, or a skip to the end (on to the
  /// next episode), is left alone.
  Future<void> _readySkipTarget(SkipSegment segment) async {
    if (_duration <= Duration.zero) return;
    final target = segment.targetFor(_duration);
    if (target >= _duration - const Duration(seconds: 30)) return;
    if (!_readiedSkipTargets.add(target.inSeconds)) return;
    final url = _streamUrl;
    final size = LibtorrentFlutter.instance.getStreamInfo(_streamId)?.fileSize ?? 0;
    if (size <= 0 || url.isEmpty) return;
    const before = 3 * 1024 * 1024;
    const length = 12 * 1024 * 1024;
    final at = (size * (target.inMilliseconds / _duration.inMilliseconds)).round();
    final from = at > before ? at - before : 0;
    if (from >= size) return;
    TorrentEngineService.instance.prefetch(_streamId, from, length);
    print('[skip] readying ${length >> 20} MB at ${target.inSeconds} s');
  }

  void _skipActiveSegment(SkipSegment segment) {
    _activeSkipSegmentNotifier.value = null;
    if (segment.type == SkipSegmentType.credits &&
        widget.details.type == 'tv' &&
        (_nextEpisode != null && !_nextEpisode!.isUnreleased) &&
        (segment.end == null ||
            (_duration > Duration.zero &&
                _duration - segment.end! <= const Duration(seconds: 15)))) {
      _playNextEpisode();
      return;
    }
    final target = segment.targetFor(_duration);
    if (target <= _currentPosition) return;
    _currentPosition = target;
    _positionNotifier.value = target;
    _seekTo(target);
    _syncMediaSessionPlaybackState();
  }
}

/// Custom seek-bar track shape that partitions the timeline by embedded MKV
/// chapters and skip segments (`Intro`, `Recap`, `Credits`, `Preview`), with
/// YouTube-style 2.5px gaps between partitions, a slight height expansion on
/// the hovered partition, and a subtle warm highlight on skippable ranges.
class _PartitionedSliderTrackShape extends RoundedRectSliderTrackShape {
  final List<double> partitions;
  final List<({double start, double end})> skipRanges;
  final double? hoveredFraction;

  const _PartitionedSliderTrackShape({
    this.partitions = const [],
    this.skipRanges = const [],
    this.hoveredFraction,
  });

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4.0;
    if (trackHeight <= 0) return;

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.width <= 0) return;

    final canvas = context.canvas;
    final activePaint = Paint()
      ..color = sliderTheme.activeTrackColor ?? Colors.white;
    final secondaryPaint = Paint()
      ..color = sliderTheme.secondaryActiveTrackColor ?? Colors.white30;
    final inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? Colors.white12;
    // Skippable segments (Intro / Recap / Credits) get a subtle warm gold/amber
    // tint over their unplayed portion so you can spot them at a glance.
    final skipPaint = Paint()
      ..color = const Color(0xFFFFD54F).withValues(alpha: 0.45);

    final boundaries = <double>[0.0, ...partitions, 1.0];
    final gapHalf = partitions.isEmpty ? 0.0 : 1.25;
    final thumbX = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final bufferX = (secondaryOffset?.dx ?? trackRect.left)
        .clamp(trackRect.left, trackRect.right);

    for (var i = 0; i < boundaries.length - 1; i++) {
      final fStart = boundaries[i];
      final fEnd = boundaries[i + 1];
      var segLeft =
          trackRect.left + fStart * trackRect.width + (i > 0 ? gapHalf : 0.0);
      var segRight = trackRect.left +
          fEnd * trackRect.width -
          (i < boundaries.length - 2 ? gapHalf : 0.0);
      if (segRight <= segLeft) continue;

      final isHovered = hoveredFraction != null &&
          hoveredFraction! >= fStart &&
          (i == boundaries.length - 2
              ? hoveredFraction! <= fEnd
              : hoveredFraction! < fEnd);

      final vExpand = isHovered ? 1.5 : 0.0;
      final segTop = trackRect.top - vExpand;
      final segBottom = trackRect.bottom + vExpand;
      final radius = Radius.circular((segBottom - segTop) / 2);
      final segRRect = RRect.fromLTRBR(
        segLeft,
        segTop,
        segRight,
        segBottom,
        radius,
      );

      canvas.save();
      canvas.clipRRect(segRRect);

      // 1. Base inactive background for the partition
      canvas.drawRect(
        Rect.fromLTRB(segLeft, segTop, segRight, segBottom),
        inactivePaint,
      );

      // 2. Buffered (secondary) fill
      if (bufferX > segLeft) {
        final bufRight = math.min(segRight, bufferX);
        canvas.drawRect(
          Rect.fromLTRB(segLeft, segTop, bufRight, segBottom),
          secondaryPaint,
        );
      }

      // 3. Skippable segment highlight (Intro / Recap / Credits / Preview)
      for (final sr in skipRanges) {
        final srLeft =
            math.max(segLeft, trackRect.left + sr.start * trackRect.width);
        final srRight =
            math.min(segRight, trackRect.left + sr.end * trackRect.width);
        if (srRight > srLeft) {
          canvas.drawRect(
            Rect.fromLTRB(srLeft, segTop, srRight, segBottom),
            skipPaint,
          );
        }
      }

      // 4. Active played progress fill
      if (thumbX > segLeft) {
        final actRight = math.min(segRight, thumbX);
        canvas.drawRect(
          Rect.fromLTRB(segLeft, segTop, actRight, segBottom),
          activePaint,
        );
      }

      canvas.restore();
    }
  }
}
