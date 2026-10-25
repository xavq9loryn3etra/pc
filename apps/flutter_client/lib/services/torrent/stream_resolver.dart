import 'dart:math' as math;

import 'torrent_engine_service.dart';
import 'torrent_index_service.dart';

/// The result of resolving a stream, possibly after falling back away from
/// the originally-requested one.
class StreamResolveResult {
  final TorrentStream stream;
  final StreamResult result;
  StreamResolveResult({required this.stream, required this.result});
}

/// Thrown by [StreamResolver.resolveWithFallback] when its `isCancelled`
/// says the user gave up (e.g. closed the popup) — not an error to show.
class ResolveCancelledException implements Exception {
  const ResolveCancelledException();
}

/// One quality the user can pick (4K, 1080p, ...) instead of a specific
/// torrent: [streams] holds every torrent of that quality, best pick first.
/// Playing an option starts [best] and falls back through the rest, so the
/// user never has to choose between releases.
class QualityOption {
  /// See [StreamResolver.tierOf]: 4 = 4K down to 0 = CAM/unknown.
  final int tier;
  final List<TorrentStream> streams;

  const QualityOption(this.tier, this.streams);

  TorrentStream get best => streams.first;

  /// Short mark for the quality badge.
  String get badge => const {4: '4K', 3: 'FHD', 2: 'HD', 1: 'SD'}[tier] ?? '—';

  String get name =>
      const {4: 'Ultra HD', 3: 'Full HD', 2: 'HD', 1: 'SD'}[tier] ?? 'Other';

  String get resolution =>
      const {4: '2160p', 3: '1080p', 2: '720p', 1: '480p'}[tier] ??
      (best.quality == 'CAM' ? 'Cinema recording' : 'Unknown quality');

  /// [best]'s download size ("2.1 GB"), or null when it isn't known.
  String? get size =>
      StreamResolver._sizeInMB(best.size) != null ? best.size : null;
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
  /// choose — comes first. Only SD (480p) and up: cinema recordings and
  /// releases of unknown quality (tier 0, see [tierOf]) are left out
  /// altogether, so nothing — a list, a fallback — ever lands on one.
  Future<List<TorrentStream>> getAvailableStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final found = type == 'movie'
        ? await _indexService.getMovieStreams(imdbId)
        : await _indexService.getSeriesStreams(
            imdbId, season ?? 1, episode ?? 1);
    final streams = found.where((s) => tierOf(s) > 0).toList();

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

    // Only weigh releases with English audio when there are any — a
    // quality available only in other languages shouldn't be recommended.
    final english = streams.where((s) => languageRank(s) < 2).toList();
    final pool = english.isEmpty ? streams : english;

    // Best (smallest) size per tier, only counting candidates that actually
    // report seeders — an unseeded torrent isn't a real "deal", it's a risk.
    final bestSizePerTier = <int, double>{};
    final tiersPresent = <int>{};
    for (final s in pool) {
      final tier = tierOf(s);
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
  /// other tier; within it (and when ranking the rest), English audio,
  /// quality and seeders still matter, with size as a light tie-breaker —
  /// smaller wins between otherwise-similar options.
  double _score(TorrentStream stream, int? recommendedTier) {
    final tier = tierOf(stream);
    final recommendedBonus =
        (recommendedTier != null && tier == recommendedTier) ? 10000.0 : 0.0;
    // Outweighs any seeder difference (capped at 500) within a tier.
    final languagePenalty = languageRank(stream) * 600.0;
    final seederScore = (stream.seeders ?? 0).clamp(0, 500).toDouble();
    final sizeMB = _sizeInMB(stream.size);
    final sizePenalty = sizeMB != null ? sizeMB / 1000 : 0.0;
    return recommendedBonus +
        tier * 1000 -
        languagePenalty +
        seederScore -
        sizePenalty;
  }

  /// Flags that mean English audio. Change these to prefer another
  /// language.
  static const _preferredFlags = {'🇬🇧', '🇺🇸'};

  static final _flagPattern =
      RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);
  static final _multiAudioPattern =
      RegExp(r'(multi|dual) audio', caseSensitive: false);

  /// How well [stream]'s audio suits an English speaker, from Torrentio's
  /// languages line ([TorrentStream.languages]) — lower is better:
  ///  0 — English only: unmarked (the usual case), or only English flags
  ///  1 — English among other languages, which may play by default (the
  ///      player asks for English audio first, see PlayerScreen)
  ///  2 — no English at all
  static int languageRank(TorrentStream stream) {
    final flags =
        _flagPattern.allMatches(stream.languages).map((m) => m[0]!).toSet();
    final multiAudio = _multiAudioPattern.hasMatch(stream.languages);
    final english = flags.intersection(_preferredFlags);
    if (!multiAudio && english.length == flags.length) return 0;
    if (english.isNotEmpty || multiAudio) return 1;
    return 2;
  }

  static int tierOf(TorrentStream stream) {
    final q = stream.quality?.toLowerCase() ?? '';
    if (q.contains('4k') || q.contains('2160')) return 4;
    if (q.contains('1080')) return 3;
    if (q.contains('720')) return 2;
    if (q.contains('480')) return 1;
    return 0; // CAM/HDRip/unknown
  }

  /// Groups [streams] (as sorted by [getAvailableStreams]) into one option
  /// per quality, highest quality first. Within a quality, torrents with a
  /// healthy number of sharers come first, smallest first among them — the
  /// same picture for less to download — then the rest by sharers.
  /// [preferHash] (the last-played torrent) is put first in its quality
  /// regardless, so resuming reuses what's already downloaded.
  static List<QualityOption> qualityOptions(
    List<TorrentStream> streams, {
    String? preferHash,
  }) {
    final byTier = <int, List<TorrentStream>>{};
    for (final s in streams) {
      byTier.putIfAbsent(tierOf(s), () => []).add(s);
    }

    final tiers = byTier.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final tier in tiers)
        QualityOption(tier, _bestFirst(byTier[tier]!, preferHash)),
    ];
  }

  /// The torrents to try when [stream] is picked: [stream] itself, then the
  /// rest of [all] that share its quality, best first — so a failed start
  /// falls back to the same quality rather than a lower one.
  static List<TorrentStream> sameQuality(
    TorrentStream stream,
    List<TorrentStream> all,
  ) {
    final tier = tierOf(stream);
    return [
      stream,
      ..._bestFirst(all.where((s) => tierOf(s) == tier).toList(), null)
          .where((s) => s.infoHash != stream.infoHash),
    ];
  }

  /// "Healthy" means at least this many sharers, or a fifth of the
  /// best-shared torrent of the same quality if that's more — seed counts
  /// are only rough, so this just weeds out the barely-shared ones.
  static const int _minHealthySeeders = 5;

  static List<TorrentStream> _bestFirst(
    List<TorrentStream> group,
    String? preferHash,
  ) {
    final maxSeeds = group.fold<int>(0, (m, s) => math.max(m, s.seeders ?? 0));
    final floor = math.max(_minHealthySeeders, (maxSeeds * 0.2).round());
    bool healthy(TorrentStream s) => (s.seeders ?? 0) >= floor;

    // Index tie-break keeps the incoming (score) order between equals —
    // List.sort isn't stable.
    final indexed = group.asMap().entries.toList();
    indexed.sort((a, b) {
      final sa = a.value, sb = b.value;
      if (preferHash != null) {
        final pa = sa.infoHash.toLowerCase() == preferHash.toLowerCase();
        final pb = sb.infoHash.toLowerCase() == preferHash.toLowerCase();
        if (pa != pb) return pa ? -1 : 1;
      }
      final la = languageRank(sa), lb = languageRank(sb);
      if (la != lb) return la.compareTo(lb);
      final ha = healthy(sa), hb = healthy(sb);
      if (ha != hb) return ha ? -1 : 1;
      if (ha) {
        // Unknown sizes go after known ones.
        final ma = _sizeInMB(sa.size) ?? double.infinity;
        final mb = _sizeInMB(sb.size) ?? double.infinity;
        if (ma != mb) return ma.compareTo(mb);
      } else {
        final c = (sb.seeders ?? 0).compareTo(sa.seeders ?? 0);
        if (c != 0) return c;
      }
      return a.key.compareTo(b.key);
    });
    return [for (final e in indexed) e.value];
  }

  static double? _sizeInMB(String? size) {
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
  ///
  /// Once [isCancelled] returns true, no further candidates are tried, a
  /// torrent that started meanwhile is paused (keeping what it
  /// downloaded), and [ResolveCancelledException] is thrown.
  Future<StreamResolveResult> resolveWithFallback(
    TorrentStream selected,
    List<TorrentStream> allStreams, {
    int maxAttempts = 3,
    bool Function()? isCancelled,
  }) async {
    final candidates = [
      selected,
      ...allStreams.where((s) => s.infoHash != selected.infoHash),
    ].take(maxAttempts).toList();
    bool cancelled() => isCancelled?.call() ?? false;

    // Note: a failed resolve() cleans up its own torrent internally (see
    // TorrentEngineService.streamMagnet) — nothing to dispose here.
    Object? lastError;
    for (var i = 0; i < candidates.length; i++) {
      if (cancelled()) throw const ResolveCancelledException();
      try {
        final result = await resolve(candidates[i]);
        if (cancelled()) {
          pause(result.torrentId);
          throw const ResolveCancelledException();
        }
        return StreamResolveResult(stream: candidates[i], result: result);
      } on ResolveCancelledException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('Failed to resolve any stream');
  }

  /// Stop a torrent — its stream and its downloading — while keeping what
  /// it downloaded, for a later resume. Use on normal player close, and for
  /// an abandoned start.
  void pause(int torrentId) => _engine.pause(torrentId);

  /// Let a torrent paused by a later start download again — for going back
  /// to it when that start failed.
  void resume(int torrentId) => _engine.resume(torrentId);

  /// Cleanup after playback — deletes downloaded data. Use for abandoned
  /// mid-session switches (quality/episode change), not a normal player close.
  void cleanup(int torrentId) => _engine.cleanup(torrentId);
}
