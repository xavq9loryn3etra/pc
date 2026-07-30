import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Identifies which movie/show/episode a cached torrent download (see
/// TorrentStorageService) actually is, and how big the full torrent is.
/// Neither is recoverable from the on-disk directory alone — it's just
/// named by infoHash — so this is persisted at the moment a stream is
/// resolved (see details_screen.dart/player_screen.dart), keyed by infoHash.
class TorrentDownloadInfo {
  final String movieId;
  final String? imdbId;
  final String title;
  final String? image;
  final int? season;
  final int? episode;
  final int? totalBytes;

  /// Real bytes actually downloaded so far, per libtorrent's own piece
  /// accounting (`totalDone`) — NOT derived from file size on disk. Files
  /// are sparse-allocated to their full final size the moment streaming
  /// starts (see torrent_bridge.cpp's `storage_mode_sparse`), so a file's
  /// apparent length on disk reads as ~100% almost immediately regardless
  /// of how much has actually downloaded. This is updated periodically
  /// while a torrent streams (see PlayerScreen._subscribeToTorrent) and is
  /// the only trustworthy "how much is actually done" figure available,
  /// including after the app restarts and the torrent is no longer live.
  final int? downloadedBytes;

  const TorrentDownloadInfo({
    required this.movieId,
    this.imdbId,
    required this.title,
    this.image,
    this.season,
    this.episode,
    this.totalBytes,
    this.downloadedBytes,
  });

  bool get isEpisode => season != null && episode != null;

  /// Groups episodes of the same show together — imdbId is stable across
  /// a show's episodes, movieId is the fallback for entries saved before
  /// an imdbId was available.
  String get showKey => imdbId ?? movieId;

  Map<String, dynamic> toJson() => {
        'movieId': movieId,
        'imdbId': imdbId,
        'title': title,
        'image': image,
        'season': season,
        'episode': episode,
        'totalBytes': totalBytes,
        'downloadedBytes': downloadedBytes,
      };

  factory TorrentDownloadInfo.fromJson(Map<String, dynamic> json) =>
      TorrentDownloadInfo(
        movieId: json['movieId'] as String? ?? '',
        imdbId: json['imdbId'] as String?,
        title: json['title'] as String? ?? 'Unknown',
        image: json['image'] as String?,
        season: json['season'] as int?,
        episode: json['episode'] as int?,
        totalBytes: json['totalBytes'] as int?,
        downloadedBytes: json['downloadedBytes'] as int?,
      );
}

class TorrentDownloadRegistry {
  static const _storageKey = 'torrent_download_registry_v1';

  static Future<void> save(String infoHash, TorrentDownloadInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _readAll(prefs);
    map[infoHash.toLowerCase()] = info.toJson();
    await prefs.setString(_storageKey, jsonEncode(map));
  }

  static Future<Map<String, TorrentDownloadInfo>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _readAll(prefs);
    return map.map((hash, json) => MapEntry(
        hash, TorrentDownloadInfo.fromJson(json as Map<String, dynamic>)));
  }

  /// Updates just the real-progress fields of an already-saved entry
  /// (leaving its movie/episode identity untouched). No-ops if [save]
  /// hasn't been called for this infoHash yet — progress with no known
  /// identity attached isn't useful for anything.
  static Future<void> updateProgress(
    String infoHash, {
    required int downloadedBytes,
    int? totalBytes,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _readAll(prefs);
    final key = infoHash.toLowerCase();
    final existingJson = map[key];
    if (existingJson == null) return;
    final existing =
        TorrentDownloadInfo.fromJson(existingJson as Map<String, dynamic>);
    var resolvedTotal = totalBytes ?? existing.totalBytes;
    // Guard against a stale/wrong total (e.g. mis-parsed from Torrentio's
    // size string) that's smaller than what's actually been downloaded —
    // that combination is impossible for a real torrent, so bump it up
    // rather than let the Storage screen show downloaded > total forever.
    if (resolvedTotal != null && downloadedBytes > resolvedTotal) {
      resolvedTotal = downloadedBytes;
    }
    map[key] = TorrentDownloadInfo(
      movieId: existing.movieId,
      imdbId: existing.imdbId,
      title: existing.title,
      image: existing.image,
      season: existing.season,
      episode: existing.episode,
      totalBytes: resolvedTotal,
      downloadedBytes: downloadedBytes,
    ).toJson();
    await prefs.setString(_storageKey, jsonEncode(map));
  }

  static Future<void> remove(String infoHash) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _readAll(prefs);
    if (map.remove(infoHash.toLowerCase()) != null) {
      await prefs.setString(_storageKey, jsonEncode(map));
    }
  }

  static Future<Map<String, dynamic>> _readAll(SharedPreferences prefs) async {
    final raw = prefs.getString(_storageKey);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// Parses Torrentio's human-readable size strings ("8.91 GB", "700 MB")
  /// into bytes so download progress can be compared against real
  /// on-disk byte counts.
  static int? parseSizeBytes(String? size) {
    if (size == null) return null;
    final match = RegExp(r'^([\d.]+)\s*(TB|GB|MB|KB)$', caseSensitive: false)
        .firstMatch(size.trim());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    switch (match.group(2)!.toUpperCase()) {
      case 'TB':
        return (value * tb).round();
      case 'GB':
        return (value * gb).round();
      case 'MB':
        return (value * mb).round();
      case 'KB':
        return (value * kb).round();
    }
    return null;
  }
}
