import 'torrent_engine_service.dart';
import 'torrent_index_service.dart';

/// The result of resolving a stream, possibly after falling back away from
/// the originally-requested one.
class StreamResolveResult {
  final TorrentStream stream;
  final StreamResult result;
  StreamResolveResult({required this.stream, required this.result});
}

class StreamResolver {
  final _indexService = TorrentIndexService();
  final _engine = TorrentEngineService.instance;

  /// How much bigger a quality tier is allowed to be than the best size
  /// available one tier down before it's considered "not worth it" and we
  /// step down instead. People pick torrents by size and quality, not
  /// seeder count: a 4K release that happens to be smaller than the 1080p
  /// alternative is an easy win, but a 1080p release costing 2x+ what a
  /// solid 720p costs isn't worth it to most people, no matter the seeds.
  static const double _sizeJumpThreshold = 2.2;

  /// Get available qualities for a movie/show, sorted so the best practical
  /// pick — balancing quality against file size the way people actually
  /// choose — comes first.
  Future<List<TorrentStream>> getAvailableStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final streams = type == 'movie'
        ? await _indexService.getMovieStreams(imdbId)
        : await _indexService.getSeriesStreams(
            imdbId, season ?? 1, episode ?? 1);

    final recommendedTier = _recommendedTierRank(streams);
    streams.sort((a, b) =>
        _score(b, recommendedTier).compareTo(_score(a, recommendedTier)));
    return streams;
  }

  /// Starting from the highest available quality tier, keep stepping down
  /// a tier as long as that tier costs disproportionately more size than
  /// what's available one tier down — this is what "all the 1080p options
  /// are too big, I'll take 720p instead" looks like as a rule. Stops as
  /// soon as a tier's size premium looks reasonable, or size data is
  /// missing (in which case we don't second-guess and keep the tier).
  int? _recommendedTierRank(List<TorrentStream> streams) {
    if (streams.isEmpty) return null;

    // Best (smallest) size per tier, only counting candidates that actually
    // report seeders — an unseeded torrent isn't a real "deal", it's a risk.
    final bestSizePerTier = <int, double>{};
    final tiersPresent = <int>{};
    for (final s in streams) {
      final tier = _tierRank(s);
      tiersPresent.add(tier);
      if ((s.seeders ?? 0) <= 0) continue;
      final mb = _sizeInMB(s.size);
      if (mb == null) continue;
      final existing = bestSizePerTier[tier];
      if (existing == null || mb < existing) bestSizePerTier[tier] = mb;
    }

    final ordered = tiersPresent.toList()..sort((a, b) => b.compareTo(a));
    int chosen = 0;
    while (chosen < ordered.length - 1) {
      final currentSize = bestSizePerTier[ordered[chosen]];
      final nextSize = bestSizePerTier[ordered[chosen + 1]];
      if (currentSize != null &&
          nextSize != null &&
          currentSize > nextSize * _sizeJumpThreshold) {
        chosen++;
      } else {
        break;
      }
    }
    return ordered[chosen];
  }

  /// Final per-stream score: the recommended tier always sorts above every
  /// other tier; within it (and when ranking the rest), quality and seeders
  /// still matter, with size as a light tie-breaker — smaller wins between
  /// otherwise-similar options.
  double _score(TorrentStream stream, int? recommendedTier) {
    final tier = _tierRank(stream);
    final recommendedBonus =
        (recommendedTier != null && tier == recommendedTier) ? 10000.0 : 0.0;
    final seederScore = (stream.seeders ?? 0).clamp(0, 500).toDouble();
    final sizeMB = _sizeInMB(stream.size);
    final sizePenalty = sizeMB != null ? sizeMB / 1000 : 0.0;
    return recommendedBonus + tier * 1000 + seederScore - sizePenalty;
  }

  int _tierRank(TorrentStream stream) {
    final q = stream.quality?.toLowerCase() ?? '';
    if (q.contains('4k') || q.contains('2160')) return 4;
    if (q.contains('1080')) return 3;
    if (q.contains('720')) return 2;
    if (q.contains('480')) return 1;
    return 0; // CAM/HDRip/unknown
  }

  double? _sizeInMB(String? size) {
    if (size == null) return null;
    final match = RegExp(r'^([\d.]+)\s*(TB|GB|MB)$', caseSensitive: false)
        .firstMatch(size.trim());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    switch (match.group(2)!.toUpperCase()) {
      case 'TB':
        return value * 1024 * 1024;
      case 'GB':
        return value * 1024;
      default:
        return value; // MB
    }
  }

  /// Resolve a specific torrent to a playable local URL.
  Future<StreamResult> resolve(TorrentStream selected) async {
    return await _engine.streamMagnet(
      selected.infoHash,
      fileIndex: selected.fileIdx,
    );
  }

  /// Resolve [selected], automatically falling back through the next-best
  /// candidates in [allStreams] if it fails or times out. Torrentio's seed
  /// counts are scraped/cached and often stale — a "67 seeds" pick can turn
  /// out unreachable while a "0 seeds" one streams fine — so one failed
  /// attempt shouldn't be a dead end the user has to manually recover from.
  Future<StreamResolveResult> resolveWithFallback(
    TorrentStream selected,
    List<TorrentStream> allStreams, {
    int maxAttempts = 3,
  }) async {
    final candidates = [
      selected,
      ...allStreams.where((s) => s.infoHash != selected.infoHash),
    ].take(maxAttempts);

    // Note: a failed resolve() cleans up its own torrent internally (see
    // TorrentEngineService.streamMagnet) — nothing to dispose here.
    Object? lastError;
    for (final candidate in candidates) {
      try {
        final result = await resolve(candidate);
        return StreamResolveResult(stream: candidate, result: result);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('Failed to resolve any stream');
  }

  /// Cleanup after playback — deletes downloaded data. Use for abandoned
  /// mid-session switches (quality/episode change), not a normal player close.
  void cleanup(int torrentId) => _engine.cleanup(torrentId);

  /// Stop streaming but keep downloaded data on disk for a later resume.
  /// Use on normal player close.
  void release(int torrentId) => _engine.release(torrentId);
}
