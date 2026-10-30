import 'dart:io';
import 'last_played_torrents.dart';
import 'torrent_download_registry.dart';
import 'torrent_engine_service.dart';
import 'torrent_paths.dart';

class CachedTorrentEntry {
  final String infoHash;
  final String path;
  final int sizeBytes;
  final DateTime modified;

  /// Space the download really takes up on disk, where it can be measured
  /// (Android). Unlike [sizeBytes] — files are sparse-allocated to their
  /// full size as soon as streaming starts — this counts only what's been
  /// written.
  final int? diskBytes;

  const CachedTorrentEntry({
    required this.infoHash,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    this.diskBytes,
  });
}

/// Lists and deletes torrent data that's been kept on disk after a player
/// close (see [TorrentEngineService.release]), for the Settings > Storage
/// screen. Each cached download lives in its own `$torrentsDir/$infoHash`
/// directory (see [TorrentPaths]), so a plain top-level directory listing
/// maps 1:1 to "one cached item" — no separate index/database needed.
class TorrentStorageService {
  static Future<List<CachedTorrentEntry>> listCached() async {
    final dir = Directory(await TorrentPaths.torrentsDir());
    if (!await dir.exists()) return [];

    final entries = <CachedTorrentEntry>[];
    await for (final child in dir.list()) {
      if (child is! Directory) continue;
      try {
        final stat = await child.stat();
        int size = 0;
        await for (final f in child.list(recursive: true, followLinks: false)) {
          if (f is File) size += await f.length();
        }
        if (size == 0) continue;
        entries.add(CachedTorrentEntry(
          infoHash: child.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
          path: child.path,
          sizeBytes: size,
          modified: stat.modified,
          diskBytes: await _diskUsage(child.path),
        ));
      } catch (_) {
        // Skip entries we can't stat/read rather than failing the whole list.
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// Bytes actually written under [path], via the system's `du` (Android
  /// ships it; iOS apps can't run processes). Null when unavailable.
  static Future<int?> _diskUsage(String path) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await Process.run('du', ['-sk', path]);
      if (result.exitCode != 0) return null;
      final kb = int.tryParse('${result.stdout}'.trim().split(RegExp(r'\s+')).first);
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

  static int totalCachedBytes(List<CachedTorrentEntry> entries) =>
      entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

  /// Deletes a cached download. If its torrent is still registered in the
  /// current engine session, goes through the engine (also stops any stream
  /// and updates in-memory state); otherwise just deletes the directory
  /// (e.g. the app was restarted since this was last streamed).
  static Future<void> delete(CachedTorrentEntry entry) =>
      _deleteByPath(entry.infoHash, entry.path);

  /// Same as [delete], but for callers that only have an infoHash on hand
  /// (e.g. the player recovering from a stalled stream mid-session) rather
  /// than a [CachedTorrentEntry] from a directory listing. Resolves the
  /// same deterministic per-infoHash path [TorrentEngineService] streams
  /// into (see torrent_paths.dart) and wipes it the same way.
  static Future<void> deleteByInfoHash(String infoHash) async {
    final path = await TorrentPaths.savePathFor(infoHash);
    await _deleteByPath(infoHash, path);
  }

  static Future<void> _deleteByPath(String infoHash, String path) async {
    final engine = TorrentEngineService.instance.engine;
    int? liveId;
    for (final t in engine.torrents.entries) {
      if (t.value.savePath == path) {
        liveId = t.key;
        break;
      }
    }

    if (liveId != null) {
      engine.removeTorrent(liveId, deleteFiles: true);
    } else {
      final dir = Directory(path);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    await TorrentDownloadRegistry.remove(infoHash);
    await LastPlayedTorrents.forgetTorrent(infoHash);
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
