import 'dart:async';

import 'package:dio/dio.dart';

class TorrentStream {
  final String infoHash;
  final String title; // Full raw title
  final String name; // Parsed torrent name
  final String? quality; // Parsed: "4K", "1080p", "720p", etc.
  final String? size; // Parsed: "2.1 GB"
  final String? source; // Parsed: "RARBG", "YTS", etc.
  final int? fileIdx; // File index within the torrent (null for movies)
  final int? seeders; // Seeders count
  // Torrentio's languages line: flags and text like "Multi Audio / 🇫🇷".
  // Empty when unmarked, which usually means English only.
  final String languages;
  // Part of a season pack (or other multi-file torrent) rather than a
  // torrent of its own — slower to start: its metadata covers every file.
  final bool isPack;
  // For a title not made in English, whose original audio is what people
  // want: its languages line then doesn't affect ranking (see
  // StreamResolver.languageRank).
  final bool ignoreLanguage;
  // Trackers the finder lists for this particular torrent (Torrentio's
  // "sources") — added to the magnet next to our own general ones, so the
  // engine also asks where this torrent's sharers are known to gather.
  final List<String> trackers;

  TorrentStream({
    required this.infoHash,
    required this.title,
    required this.name,
    this.quality,
    this.size,
    this.source,
    this.fileIdx,
    this.seeders,
    this.languages = '',
    this.isPack = false,
    this.ignoreLanguage = false,
    this.trackers = const [],
  });

  /// This stream with [ignoreLanguage] set.
  TorrentStream withoutLanguagePreference() => TorrentStream(
        infoHash: infoHash,
        title: title,
        name: name,
        quality: quality,
        size: size,
        source: source,
        fileIdx: fileIdx,
        seeders: seeders,
        languages: languages,
        isPack: isPack,
        ignoreLanguage: true,
        trackers: trackers,
      );

  /// This stream, as also found by another finder ([other], the same
  /// torrent): the higher of the two sharer counts — finders' counts age
  /// at different rates — and both tracker lists.
  TorrentStream mergedWith(TorrentStream other) => TorrentStream(
        infoHash: infoHash,
        title: title,
        name: name,
        quality: quality,
        size: size,
        source: source,
        fileIdx: fileIdx,
        seeders: (other.seeders ?? 0) > (seeders ?? 0)
            ? other.seeders
            : seeders,
        languages: languages,
        isPack: isPack,
        ignoreLanguage: ignoreLanguage,
        trackers: {...trackers, ...other.trackers}.toList(),
      );

  /// A stream for a finder that gives plain fields rather than Torrentio's
  /// text lines (YTS, The Pirate Bay). [title] is laid out the way
  /// Torrentio's is, which the rest of the app reads.
  factory TorrentStream.fromRelease({
    required String infoHash,
    required String name,
    required int sizeBytes,
    required int seeders,
    required String source,
    String? quality,
  }) {
    final size = formatSize(sizeBytes);
    return TorrentStream(
      infoHash: infoHash.toLowerCase(),
      title: '$name\n👤 $seeders 💾 $size ⚙️ $source',
      name: name,
      quality: quality ?? qualityFromName(name) ?? 'HDRip',
      size: size,
      source: source,
      seeders: seeders,
      languages: languagesFromName(name),
    );
  }

  /// "1.85 GB" / "700 MB", the way Torrentio writes sizes.
  static String formatSize(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) {
      return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
    }
    return '${(bytes / mb).toStringAsFixed(0)} MB';
  }

  /// The quality a release name gives ("…1080p BluRay…"), or null.
  static String? qualityFromName(String name) {
    final n = name.toLowerCase();
    if (RegExp(r'2160p|\b4k\b|\buhd\b').hasMatch(n)) return '4K';
    if (n.contains('1080p') || n.contains('1080i')) return '1080p';
    if (n.contains('720p')) return '720p';
    if (n.contains('480p') || n.contains('576p') || n.contains('dvdrip')) {
      return '480p';
    }
    if (RegExp(r'\b(hd)?cam(rip)?\b|\btelesync\b|\bhdts\b|\bts(rip)?\b')
        .hasMatch(n)) {
      return 'CAM';
    }
    return null;
  }

  // Words in release names that mark their audio, as the flags Torrentio
  // shows for them (see StreamResolver.languageRank).
  static final _nameLanguages = <RegExp, String>{
    RegExp(r'(?<![A-Za-z])(ENG|English)(?![A-Za-z])'): '🇬🇧',
    RegExp(r'(?<![A-Za-z])(ITA|Italian)(?![A-Za-z])'): '🇮🇹',
    RegExp(r'(?<![A-Za-z])(FRENCH|TRUEFRENCH|VFF|VFQ|VF2|French)(?![A-Za-z])'):
        '🇫🇷',
    RegExp(r'(?<![A-Za-z])(SPANISH|Spanish|Castellano|ESP)(?![A-Za-z])'): '🇪🇸',
    RegExp(r'(?<![A-Za-z])(LATINO|Latino)(?![A-Za-z])'): '🇲🇽',
    RegExp(r'(?<![A-Za-z])(GERMAN|German|GER)(?![A-Za-z])'): '🇩🇪',
    RegExp(r'(?<![A-Za-z])(RUS|Russian)(?![A-Za-z])'): '🇷🇺',
    RegExp(r'(?<![A-Za-z])(Hindi|HINDI|Tamil|TAMIL|Telugu|TELUGU)(?![A-Za-z])'):
        '🇮🇳',
  };
  static final _multiPattern = RegExp(
      r'(?<![A-Za-z])(MULTi|MULTI|Multi|Dual[ .-]?Audio|DUAL)(?![A-Za-z])');

  /// A languages line like Torrentio's ("🇬🇧 / 🇮🇹", "Multi Audio") for a
  /// release name — empty when it names no language (usually English).
  static String languagesFromName(String name) {
    final parts = <String>[
      if (_multiPattern.hasMatch(name)) 'Multi Audio',
      for (final e in _nameLanguages.entries)
        if (e.key.hasMatch(name)) e.value,
    ];
    // English alone says nothing the empty line doesn't.
    if (parts.length == 1 && parts.first == '🇬🇧') return '';
    return parts.toSet().join(' / ');
  }

  factory TorrentStream.fromJson(Map<String, dynamic> json) {
    final String rawTitle = json['title'] ?? '';
    final String rawName = json['name'] ?? '';
    final String infoHash = json['infoHash'] ?? '';
    final int? fileIdx = json['fileIdx'] is int ? json['fileIdx'] : (json['fileIndex'] is int ? json['fileIndex'] : null);

    // Torrentio format:
    //   name:  "Torrentio\n4k HDR"  (quality is on line 2 of name)
    //   title: "Inception 2010 PROPER Bluray 2160p...\n👤 122 💾 8.91 GB ⚙️ 1337x\n🇬🇧 / 🇮🇹"
    //          Line 1: Torrent release name
    //          (Season packs only: the episode's file inside the pack)
    //          Then: Seeders + Size + Source (all on one line) — for a pack,
    //                the size is usually the episode file's, not the pack's
    //          Last: (optional) languages — flags, "Multi Audio", ...

    final titleLines = rawTitle.split('\n');
    final nameLines = rawName.split('\n');

    // --- Torrent display name (line 1 of title) ---
    String name = titleLines.isNotEmpty ? titleLines[0].trim() : 'Unknown Torrent';

    // --- Quality (from name field, line 2) ---
    String? quality;
    final qualityStr = nameLines.length > 1 ? nameLines[1].trim().toLowerCase() : '';
    // Torrentio's word for a cinema recording comes first: it says
    // "TeleSync" for "Movie.2026.1080p.TELESYNC", which the release-name
    // fallback below would otherwise take for 1080p.
    if (RegExp(r'cam|scr|tele').hasMatch(qualityStr)) {
      quality = 'CAM';
    } else if (qualityStr.contains('4k') || qualityStr.contains('2160')) {
      quality = '4K';
    } else if (qualityStr.contains('1080')) {
      quality = '1080p';
    } else if (qualityStr.contains('720')) {
      quality = '720p';
    } else if (qualityStr.contains('480') || qualityStr.contains('dvd')) {
      // A DVD rip is standard definition (480p/576p) — often all there is
      // for older shows.
      quality = '480p';
    }

    // Fallback: also check the release name (line 1 of title) for quality
    if (quality == null) {
      final titleLower = name.toLowerCase();
      if (titleLower.contains('2160p') || titleLower.contains('4k')) {
        quality = '4K';
      } else if (titleLower.contains('1080p')) {
        quality = '1080p';
      } else if (titleLower.contains('720p')) {
        quality = '720p';
      } else if (titleLower.contains('480p') || titleLower.contains('dvdrip')) {
        quality = '480p';
      }
    }

    // --- Seeders, Size, Source (the title's stats line) ---
    String? size;
    String? source;
    int? seeders;

    // The stats line holds 👤 seeders 💾 size ⚙️ source. Found by its
    // markers rather than position: season packs push it down a line.
    final statsIndex =
        titleLines.indexWhere((l) => l.contains('👤') || l.contains('💾'));
    final statsLine = statsIndex >= 0 ? titleLines[statsIndex] : '';
    final languages = statsIndex >= 0
        ? titleLines.skip(statsIndex + 1).join(' / ').trim()
        : '';

    // Seeders: 👤 122
    final seederRegExp = RegExp(r'👤\s*(\d+)');
    final seederMatch = seederRegExp.firstMatch(statsLine);
    if (seederMatch != null) {
      seeders = int.tryParse(seederMatch.group(1) ?? '');
    }

    // Size: 💾 8.91 GB
    final sizeRegExp = RegExp(r'💾\s*(\d+(?:\.\d+)?\s*(?:GB|MB|TB))', caseSensitive: false);
    final sizeMatch = sizeRegExp.firstMatch(statsLine);
    if (sizeMatch != null) {
      size = sizeMatch.group(1);
    }

    // Source: ⚙️ 1337x
    final sourceRegExp = RegExp(r'⚙️\s*(.+)$');
    final sourceMatch = sourceRegExp.firstMatch(statsLine);
    if (sourceMatch != null) {
      source = sourceMatch.group(1)?.trim();
    }

    // Default values if parsing failed
    quality ??= 'HDRip';
    size ??= 'Unknown size';
    source ??= 'P2P';
    seeders ??= 0;

    return TorrentStream(
      infoHash: infoHash,
      title: rawTitle,
      name: name,
      quality: quality,
      size: size,
      source: source,
      fileIdx: fileIdx,
      seeders: seeders,
      languages: languages,
      // A pack's title has the episode's file name between the release
      // name and the stats line (see above).
      isPack: statsIndex > 1,
      trackers: _trackersFrom(json['sources']),
    );
  }

  /// The trackers in Torrentio's `sources` ("tracker:udp://…", next to
  /// "dht:…" entries). HTTPS ones are left out: our engine build can't
  /// reach them.
  static List<String> _trackersFrom(Object? sources) {
    if (sources is! List) return const [];
    return sources
        .whereType<String>()
        .where((s) => s.startsWith('tracker:'))
        .map((s) => s.substring('tracker:'.length))
        .where((url) =>
            (url.startsWith('udp://') || url.startsWith('http://')) &&
            !url.contains('.local/'))
        .toList();
  }
}


/// Finds a title's torrents. Asks several finders at once and combines what
/// they return, so one being down or missing a title doesn't leave Play
/// with nothing: Torrentio (the main one, which also searches many sites
/// itself), YTS (movies — small, well-shared encodes) and The Pirate Bay.
class TorrentIndexService {
  // Singleton — avoids constructing a fresh Dio client (and its interceptors/
  // adapter) every time a screen builds a TorrentIndexService/StreamResolver.
  static final TorrentIndexService _instance = TorrentIndexService._internal();
  factory TorrentIndexService() => _instance;
  TorrentIndexService._internal();

  final Dio _dio = Dio();

  /// Once this long has passed and some finder has answered, the rest are
  /// no longer waited for — a slow one (Torrentio on a cache miss can take
  /// 20s) shouldn't hold up what the others already found.
  static const _patience = Duration(seconds: 8);

  // YTS keeps moving its address; the old ones forward to the new.
  static const _ytsApis = [
    'https://movies-api.accel.li/api/v2',
    'https://yts.lt/api/v2',
  ];

  // The Pirate Bay's video categories: movies (201, 202, 207, 209, 211)
  // and TV (205, 208, 212). Not 206 (phone-sized rips) or anything else.
  static const _pirateBayMovieCategories = {'201', '202', '207', '209', '211'};
  static const _pirateBayTvCategories = {'205', '208', '212'};

  Future<List<TorrentStream>> getMovieStreams(String imdbId) => _gather([
        _torrentio('movie/$imdbId'),
        _yts(imdbId),
        _pirateBay(imdbId),
      ]);

  Future<List<TorrentStream>> getSeriesStreams(
          String imdbId, int season, int episode) =>
      _gather([
        _torrentio('series/$imdbId:$season:$episode'),
        _pirateBay(imdbId, season: season, episode: episode),
      ]);

  /// Runs [lookups] together and combines their torrents, keeping the
  /// first lookup's copy of a torrent several of them find (Torrentio's
  /// carries the most: file index, season-pack info, languages).
  Future<List<TorrentStream>> _gather(
      List<Future<List<TorrentStream>>> lookups) async {
    final found = List<List<TorrentStream>?>.filled(lookups.length, null);
    final done = Completer<void>();
    var pending = lookups.length;
    var patienceUp = false;
    void check() {
      if (done.isCompleted) return;
      final anyFound = found.any((f) => f != null && f.isNotEmpty);
      if (pending == 0 || (patienceUp && anyFound)) done.complete();
    }

    for (var i = 0; i < lookups.length; i++) {
      lookups[i].then((streams) {
        found[i] = streams;
        pending--;
        check();
      });
    }
    final patience = Timer(_patience, () {
      patienceUp = true;
      check();
    });
    await done.future;
    patience.cancel();

    final byHash = <String, TorrentStream>{};
    for (final streams in found) {
      for (final s in streams ?? const <TorrentStream>[]) {
        final key = s.infoHash.toLowerCase();
        final known = byHash[key];
        byHash[key] = known == null ? s : known.mergedWith(s);
      }
    }
    return byHash.values.toList();
  }

  Future<List<TorrentStream>> _torrentio(String path) async {
    final url = 'https://torrentio.strem.fun/stream/$path.json';
    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {'User-Agent': 'Mozilla/5.0'},
          sendTimeout: const Duration(seconds: 10),
          // Torrentio's free public instance has to live-scrape trackers on
          // a cache miss, which can take 15-20s for less popular titles —
          // 10s was cutting the response off right before it arrived.
          receiveTimeout: const Duration(seconds: 25),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final List<dynamic> streamsJson = response.data['streams'] ?? [];
        print('Torrentio $url -> ${streamsJson.length} stream(s)');
        return streamsJson
            .where((json) => json['infoHash'] != null)
            .map((json) => TorrentStream.fromJson(json))
            .toList();
      }
      print('Torrentio $url -> unexpected status ${response.statusCode}');
    } catch (e) {
      print('Error fetching torrents from Torrentio ($url): $e');
    }
    return [];
  }

  Options get _quickOptions => Options(
        headers: {'User-Agent': 'Mozilla/5.0'},
        sendTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
      );

  Future<List<TorrentStream>> _yts(String imdbId) async {
    for (final api in _ytsApis) {
      try {
        final response = await _dio.get(
          '$api/movie_details.json',
          queryParameters: {'imdb_id': imdbId},
          options: _quickOptions,
        );
        final movie = response.data?['data']?['movie'];
        // An unknown movie comes back as an empty one, not an error.
        if (movie == null || movie['imdb_code'] != imdbId) return [];
        final torrents = (movie['torrents'] as List?) ?? const [];
        final title = '${movie['title_long'] ?? movie['title']}';
        final streams = [
          for (final t in torrents)
            if (t['hash'] is String)
              TorrentStream.fromRelease(
                infoHash: t['hash'],
                name: '$title ${t['quality']} ${t['type']} '
                    '${t['video_codec'] ?? ''} YTS',
                sizeBytes: (t['size_bytes'] as num?)?.toInt() ?? 0,
                seeders: (t['seeds'] as num?)?.toInt() ?? 0,
                source: 'YTS',
                quality: TorrentStream.qualityFromName('${t['quality']}'),
              ),
        ];
        print('YTS $imdbId -> ${streams.length} stream(s)');
        return streams;
      } catch (e) {
        print('Error fetching torrents from YTS ($api): $e');
      }
    }
    return [];
  }

  /// The Pirate Bay's torrents tagged with [imdbId]. For an episode
  /// ([season] and [episode] given), only torrents of that one episode:
  /// which of a season pack's files is the episode can't be told before
  /// its metadata arrives.
  Future<List<TorrentStream>> _pirateBay(
    String imdbId, {
    int? season,
    int? episode,
  }) async {
    final isEpisode = season != null && episode != null;
    final categories =
        isEpisode ? _pirateBayTvCategories : _pirateBayMovieCategories;
    // "S01E05" but not "S01E05-E08" or "S01E05E06".
    final episodePattern = RegExp(
        'S0?${season}E0?$episode(?![0-9])(?!\\s*[-–]\\s*E?[0-9])(?!E[0-9])',
        caseSensitive: false);
    try {
      final response = await _dio.get(
        'https://apibay.org/q.php',
        queryParameters: {'q': imdbId},
        options: _quickOptions,
      );
      final results = response.data is List ? response.data as List : const [];
      final streams = [
        for (final r in results)
          // "No results returned" comes back as a single id-0 entry.
          if (r['id'] != '0' &&
              r['imdb'] == imdbId &&
              categories.contains(r['category']) &&
              r['info_hash'] is String &&
              (!isEpisode || episodePattern.hasMatch('${r['name']}')))
            TorrentStream.fromRelease(
              infoHash: r['info_hash'],
              name: '${r['name']}',
              sizeBytes: int.tryParse('${r['size']}') ?? 0,
              seeders: int.tryParse('${r['seeders']}') ?? 0,
              source: 'ThePirateBay',
            ),
      ];
      print('The Pirate Bay $imdbId'
          '${isEpisode ? ' S${season}E$episode' : ''} -> '
          '${streams.length} stream(s)');
      return streams;
    } catch (e) {
      print('Error fetching torrents from The Pirate Bay ($imdbId): $e');
    }
    return [];
  }
}
