import 'package:dio/dio.dart';

class TorrentStream {
  final String infoHash;
  final String title;       // Full raw title
  final String name;        // Parsed torrent name
  final String? quality;    // Parsed: "4K", "1080p", "720p", etc.
  final String? size;       // Parsed: "2.1 GB"
  final String? source;     // Parsed: "RARBG", "YTS", etc.
  final int? fileIdx;       // File index within the torrent (null for movies)
  final int? seeders;       // Seeders count

  TorrentStream({
    required this.infoHash,
    required this.title,
    required this.name,
    this.quality,
    this.size,
    this.source,
    this.fileIdx,
    this.seeders,
  });

  factory TorrentStream.fromJson(Map<String, dynamic> json) {
    final String rawTitle = json['title'] ?? '';
    final String rawName = json['name'] ?? '';
    final String infoHash = json['infoHash'] ?? '';
    final int? fileIdx = json['fileIdx'] is int ? json['fileIdx'] : (json['fileIndex'] is int ? json['fileIndex'] : null);

    // Torrentio format:
    //   name:  "Torrentio\n4k HDR"  (quality is on line 2 of name)
    //   title: "Inception 2010 PROPER Bluray 2160p...\n👤 122 💾 8.91 GB ⚙️ 1337x\n🇬🇧 / 🇮🇹"
    //          Line 1: Torrent release name
    //          Line 2: Seeders + Size + Source (all on one line)
    //          Line 3: (optional) language flags

    final titleLines = rawTitle.split('\n');
    final nameLines = rawName.split('\n');

    // --- Torrent display name (line 1 of title) ---
    String name = titleLines.isNotEmpty ? titleLines[0].trim() : 'Unknown Torrent';

    // --- Quality (from name field, line 2) ---
    String? quality;
    final qualityStr = nameLines.length > 1 ? nameLines[1].trim().toLowerCase() : '';
    if (qualityStr.contains('4k') || qualityStr.contains('2160')) {
      quality = '4K';
    } else if (qualityStr.contains('1080')) {
      quality = '1080p';
    } else if (qualityStr.contains('720')) {
      quality = '720p';
    } else if (qualityStr.contains('480')) {
      quality = '480p';
    } else if (qualityStr.contains('cam') || qualityStr.contains('scr')) {
      quality = 'CAM';
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
      } else if (titleLower.contains('480p')) {
        quality = '480p';
      }
    }

    // --- Seeders, Size, Source (from title field, line 2) ---
    String? size;
    String? source;
    int? seeders;

    // The stats line is line 2 of title (index 1), which contains 👤 seeders 💾 size ⚙️ source
    final statsLine = titleLines.length > 1 ? titleLines[1] : '';

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
    );
  }
}

class TorrentIndexService {
  // Singleton — avoids constructing a fresh Dio client (and its interceptors/
  // adapter) every time a screen builds a TorrentIndexService/StreamResolver.
  static final TorrentIndexService _instance = TorrentIndexService._internal();
  factory TorrentIndexService() => _instance;
  TorrentIndexService._internal();

  final Dio _dio = Dio();

  Future<List<TorrentStream>> getMovieStreams(String imdbId) async {
    try {
      final response = await _dio.get(
        'https://torrentio.strem.fun/stream/movie/$imdbId.json',
        options: Options(
          headers: {'User-Agent': 'Mozilla/5.0'},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final List<dynamic> streamsJson = response.data['streams'] ?? [];
        return streamsJson
            .where((json) => json['infoHash'] != null)
            .map((json) => TorrentStream.fromJson(json))
            .toList();
      }
    } catch (e) {
      print('Error fetching movie torrents: $e');
    }
    return [];
  }

  Future<List<TorrentStream>> getSeriesStreams(String imdbId, int season, int episode) async {
    try {
      final response = await _dio.get(
        'https://torrentio.strem.fun/stream/series/$imdbId:$season:$episode.json',
        options: Options(
          headers: {'User-Agent': 'Mozilla/5.0'},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final List<dynamic> streamsJson = response.data['streams'] ?? [];
        return streamsJson
            .where((json) => json['infoHash'] != null)
            .map((json) => TorrentStream.fromJson(json))
            .toList();
      }
    } catch (e) {
      print('Error fetching series torrents: $e');
    }
    return [];
  }
}
