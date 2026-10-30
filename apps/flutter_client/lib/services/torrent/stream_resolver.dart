import 'dart:async';
import 'dart:math' as math;

import '../../models/movie.dart';
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
  ///
  /// [title], when given, also drops releases of a different title — see
  /// [_fitsTitle].
  Future<List<TorrentStream>> getAvailableStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
    Movie? title,
  }) async {
    final stopwatch = Stopwatch()..start();
    final found = type == 'movie'
        ? await _indexService.getMovieStreams(imdbId)
        : await _indexService.getSeriesStreams(
            imdbId, season ?? 1, episode ?? 1);
    print('[timing] found ${found.length} copies in '
        '${stopwatch.elapsedMilliseconds} ms');
    var streams = found
        .where((s) =>
            tierOf(s) > 0 &&
            !_isExtra(s, title) &&
            !(type != 'movie' && (season ?? 1) > 0 && _isSpecial(s, title)) &&
            _fitsTitle(s, title))
        .toList();
    // Fan edits only when there's nothing else.
    final unedited = streams.where((s) => !_isCustomEdit(s, title)).toList();
    if (unedited.isNotEmpty) streams = unedited;
    // English audio is preferred only for titles made in English: for, say,
    // a Tamil film, an untagged (assumed English) copy with 11 sharers
    // otherwise outranked the Tamil one with 235, and every fallback
    // attempt went to barely-shared copies.
    final madeIn = title?.originalLanguage;
    if (madeIn != null && madeIn != 'en') {
      streams = [for (final s in streams) s.withoutLanguagePreference()];
    }

    final recommendedTier = _recommendedTierRank(streams);
    streams.sort((a, b) =>
        _score(b, recommendedTier).compareTo(_score(a, recommendedTier)));
    return streams;
  }

  // Words that mark a pack's file as a bonus clip rather than the feature.
  static final _extraPattern = RegExp(
      r'(?<![A-Za-z])(menu|sample|trailer|NCOP|NCED|creditless)(?![A-Za-z])',
      caseSensitive: false);

  /// Whether [stream] is a disc menu, sample, trailer or similar extra that
  /// Torrentio matched to the episode by mistake — e.g. a Blu-ray rip's
  /// 12 MB "menu/…[S1][D1][01]….mkv" listed as Naruto's episode 1. Judged
  /// by the file's own name (a pack's second title line; words that are
  /// part of [title]'s own name, as in "The Menu", don't count) and by
  /// size: no real episode is under 30 MB.
  static bool _isExtra(TorrentStream stream, Movie? title) {
    final lines = stream.title.split('\n');
    final ownName = title?.title.toLowerCase() ?? '';
    if (stream.isPack &&
        lines.length > 1 &&
        _extraPattern
            .allMatches(lines[1])
            .any((m) => !ownName.contains(m[0]!.toLowerCase()))) {
      return true;
    }
    final mb = _sizeInMB(stream.size);
    return mb != null && mb < 30;
  }

  static final _specialPattern =
      RegExp(r'(?<![A-Za-z])(OVAs?|OADs?)(?![A-Za-z])', caseSensitive: false);

  /// Whether [stream] is an OVA/OAD special rather than a regular episode —
  /// Torrentio matches "[NamikazeSubs] Naruto OVA 01 …" to Naruto's S1E1,
  /// a different 17-minute story. Either the file's own name (for a pack)
  /// says so, or the release is OVAs only — one named as a whole series
  /// that also has its OVAs ("Attack on Titan (S01-S04+OVA+Movies)") still
  /// holds the episode.
  static bool _isSpecial(TorrentStream stream, Movie? title) {
    final ownName = title?.title.toLowerCase() ?? '';
    bool saysSpecial(String name) => _specialPattern
        .allMatches(name)
        .any((m) => !ownName.contains(m[0]!.toLowerCase()));
    final lines = stream.title.split('\n');
    if (stream.isPack && lines.length > 1 && saysSpecial(lines[1])) {
      return true;
    }
    return saysSpecial(stream.name) &&
        !_collectionPattern.hasMatch(stream.name);
  }

  // A release of a whole series: seasons ("S01-S04"), "complete", or an
  // episode range ("001-220", "Episodes 001-750") — not a year span.
  static final _collectionPattern = RegExp(
      r'(?<![A-Za-z])(S\d{1,2}|seasons?|complete|collection|batch|episodes)(?![A-Za-z])'
      r'|(?<!\d)\d{1,3}\s*[-~]\s*\d{1,3}(?!\d)',
      caseSensitive: false);

  static final _customPattern =
      RegExp(r'(?<![A-Za-z])custom(?![A-Za-z])', caseSensitive: false);

  /// Whether [stream] is a fan edit ("[N-Custom] Naruto …"): these cut the
  /// opening, ending and recaps, so an episode plays at 17 minutes instead
  /// of 23 and doesn't match what people expect. Not when "custom" is part
  /// of [title]'s own name.
  static bool _isCustomEdit(TorrentStream stream, Movie? title) =>
      _customPattern.hasMatch(stream.name) &&
      !(title?.title.toLowerCase().contains('custom') ?? false);

  // A year standing on its own in a release name ("Baki (2018)",
  // "Show.2019.1080p"), not part of a longer number like "1920x1080".
  static final _yearPattern =
      RegExp(r'(?<![A-Za-z0-9])(19\d\d|20\d\d)(?![A-Za-z0-9])');
  // A span of years, as collections and complete series give them
  // ("(2000-2023)", "1994 - 2004", "2008 to 2021").
  static final _yearRangePattern = RegExp(
      r'(?<![A-Za-z0-9])(19\d\d|20\d\d)\s*(?:[-–]|to)\s*(19\d\d|20\d\d)(?![A-Za-z0-9])',
      caseSensitive: false);

  /// Whether [stream] could be a release of [title]: not when its name
  /// gives only years outside the title's own. Torrentio sometimes files a
  /// remake or namesake under the original — "Baki (Baki the Grappler
  /// 2018)" under 2001's Baki the Grappler — which would play the wrong
  /// show. Names without a year are kept, as are numbers that are part of
  /// the title itself ("Blade Runner 2049").
  static bool _fitsTitle(TorrentStream stream, Movie? title) {
    if (title == null || title.year <= 0) return true;
    final titleNumbers =
        _yearPattern.allMatches(title.title).map((m) => m[0]).toSet();
    final years = _yearPattern
        .allMatches(stream.name)
        .map((m) => m[0]!)
        .where((y) => !titleNumbers.contains(y))
        .map(int.parse);
    if (years.isEmpty) return true;
    // A year either side: release and air dates can straddle New Year,
    // and festival premieres come a year early.
    final first = title.year - 1;
    final last = title.type == 'tv'
        ? (title.lastAirYear ?? DateTime.now().year) + 1
        : title.year + 1;
    // A collection spanning the title's years ("The Christopher Nolan
    // Collection (2000-2023)") holds it too.
    for (final range in _yearRangePattern.allMatches(stream.name)) {
      if (int.parse(range[1]!) <= last && int.parse(range[2]!) >= first) {
        return true;
      }
    }
    return years.any((y) => y >= first && y <= last);
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
    // 4K is never the recommendation when there's anything else: the next
    // best quality looks much the same on most screens, for a fraction of
    // the download. It's still listed for whoever wants it.
    int chosen = ordered.first == 4 && ordered.length > 1 ? 1 : 0;
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
    if (stream.ignoreLanguage) return 0;
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
  /// healthy number of sharers come first — single episodes before season
  /// packs, then smallest first, the same picture for less to download —
  /// then the rest by sharers.
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

  /// What Play most likely starts from [streams] (as sorted by
  /// [getAvailableStreams]): the last-played torrent when it's among them,
  /// otherwise the best copy of the recommended quality — the popup's
  /// highlighted row either way.
  static TorrentStream? likelyPick(
    List<TorrentStream> streams, {
    String? lastPlayedHash,
  }) {
    if (streams.isEmpty) return null;
    if (lastPlayedHash != null) {
      for (final s in streams) {
        if (s.infoHash.toLowerCase() == lastPlayedHash.toLowerCase()) return s;
      }
    }
    final tier = tierOf(streams.first);
    return qualityOptions(streams).firstWhere((o) => o.tier == tier).best;
  }

  /// What a head start (see [warmUp]) races, from [streams]: the
  /// [likelyPick] and the next two of its quality — sharer counts are often
  /// stale, so the pick may have no one sharing it. Just the last-played
  /// torrent when there is one: resuming wants that one, with what it has
  /// downloaded.
  static List<TorrentStream> headStartCandidates(
    List<TorrentStream> streams, {
    String? lastPlayedHash,
  }) {
    final pick = likelyPick(streams, lastPlayedHash: lastPlayedHash);
    if (pick == null) return const [];
    if (lastPlayedHash != null &&
        pick.infoHash.toLowerCase() == lastPlayedHash.toLowerCase()) {
      return [pick];
    }
    return sameQuality(pick, streams).take(3).toList();
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
      // No English audio goes last whatever its sharers.
      final la = languageRank(sa), lb = languageRank(sb);
      if ((la == 2) != (lb == 2)) return la == 2 ? 1 : -1;
      // Then a healthy copy before a barely-shared one, even if the healthy
      // one also has other languages: the player picks the English track,
      // and a copy with 2,000 sharers starts far sooner than one with 300.
      // (Matchbox's best Full HD copy lists a dozen languages and was
      // ranked below every English-only one.)
      final ha = healthy(sa), hb = healthy(sb);
      if (ha != hb) return ha ? -1 : 1;
      if (la != lb) return la.compareTo(lb);
      if (ha) {
        // A torrent of just this episode before a season pack: it starts
        // sooner, as there's only one file's metadata to fetch.
        if (sa.isPack != sb.isPack) return sa.isPack ? 1 : -1;
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
      trackers: selected.trackers,
    );
  }

  /// Gives what Play will most likely start a head start: races
  /// [candidates] (see [headStartCandidates]) and starts downloading the
  /// first to connect — from [resumeAt] (0–1) when it's being resumed — so
  /// pressing Play starts it at once. See [TorrentEngineService.warmUp].
  void warmUp(List<TorrentStream> candidates, {double? resumeAt}) =>
      _engine.warmUp([
        for (final s in candidates)
          (infoHash: s.infoHash, trackers: s.trackers, fileIndex: s.fileIdx),
      ], resumeAt: resumeAt);

  /// Ends a [warmUp] Play didn't take — see [TorrentEngineService.coolDown].
  void coolDown(List<TorrentStream> candidates) =>
      _engine.coolDown([for (final s in candidates) s.infoHash]);

  /// How long a copy gets to connect on its own before the next one is
  /// started alongside it. A healthy top pick usually connects within a
  /// couple of seconds and so still wins; a dead one now costs this long
  /// rather than its full 20s timeout.
  static const _headStart = Duration(seconds: 3);

  /// Resolve [selected], automatically falling back to the next-best
  /// candidates in [allStreams] if it's slow, fails or times out.
  /// Torrentio's seed counts are scraped/cached and often stale — a
  /// "67 seeds" pick can turn out unreachable while a "0 seeds" one streams
  /// fine — so one failed attempt shouldn't be a dead end the user has to
  /// manually recover from.
  ///
  /// The candidates race rather than take turns: [selected] starts first,
  /// each next one [_headStart] later (or as soon as one fails), and the
  /// first to connect plays. The others are paused, or removed when they
  /// time out.
  ///
  /// Once [isCancelled] returns true, no further candidates are tried, a
  /// torrent that connected meanwhile is paused (keeping what it
  /// downloaded), and [ResolveCancelledException] is thrown.
  Future<StreamResolveResult> resolveWithFallback(
    TorrentStream selected,
    List<TorrentStream> allStreams, {
    int maxAttempts = 3,
    bool Function()? isCancelled,
  }) async {
    final ordered = [
      selected,
      ...allStreams.where((s) =>
          s.infoHash.toLowerCase() != selected.infoHash.toLowerCase()),
    ];
    // A copy a head start already connected to (see warmUp) goes first —
    // it starts at once, where [selected] may be the one the head start
    // found no one sharing.
    final candidates = [
      ...ordered.where((s) => _engine.isReady(s.infoHash)),
      ...ordered.where((s) => !_engine.isReady(s.infoHash)),
    ].take(maxAttempts).toList();
    bool cancelled() => isCancelled?.call() ?? false;
    if (cancelled()) throw const ResolveCancelledException();

    final stopwatch = Stopwatch()..start();
    final outcome = Completer<StreamResolveResult>();
    var started = 0;
    var failed = 0;

    void startNext() {
      if (outcome.isCompleted || started >= candidates.length) return;
      final candidate = candidates[started++];
      final number = started;
      // A connection that fails cleans up its own torrent (see
      // TorrentEngineService.connect) — nothing to dispose here.
      _engine.connect(candidate.infoHash, trackers: candidate.trackers).then(
          (id) {
        if (outcome.isCompleted) {
          // Lost the race, or the user gave up: stop it, keeping what it
          // has, unless it's what's playing.
          if (!_engine.isStreaming(id)) _engine.pause(id);
          return;
        }
        if (cancelled()) {
          _engine.pause(id);
          outcome.completeError(const ResolveCancelledException());
          return;
        }
        try {
          final result = _engine.startStream(id, fileIndex: candidate.fileIdx);
          print('[timing] copy $number of ${candidates.length} connected '
              'first, after ${stopwatch.elapsedMilliseconds} ms');
          outcome.complete(
              StreamResolveResult(stream: candidate, result: result));
        } catch (e) {
          _engine.cleanup(id);
          failed++;
          if (failed == candidates.length) {
            outcome.completeError(e);
          } else {
            startNext();
          }
        }
      }, onError: (Object e) {
        if (outcome.isCompleted) return;
        failed++;
        if (failed == candidates.length) {
          print('[timing] no copy connected, gave up after '
              '${stopwatch.elapsedMilliseconds} ms');
          outcome.completeError(e);
        } else {
          // A failure brings the next copy forward.
          startNext();
        }
      });
    }

    startNext();
    var sinceLastStart = Duration.zero;
    const tick = Duration(milliseconds: 250);
    final ticker = Timer.periodic(tick, (_) {
      if (outcome.isCompleted) return;
      if (cancelled()) {
        outcome.completeError(const ResolveCancelledException());
        return;
      }
      sinceLastStart += tick;
      if (sinceLastStart >= _headStart) {
        sinceLastStart = Duration.zero;
        startNext();
      }
    });
    try {
      return await outcome.future;
    } finally {
      ticker.cancel();
    }
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
