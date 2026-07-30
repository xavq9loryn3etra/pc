import 'dart:io';
import 'torrent_download_registry.dart';
import 'torrent_engine_service.dart';
import 'torrent_paths.dart';

class CachedTorrentEntry {
  final String infoHash;
  final String path;
  final int sizeBytes;
  final DateTime modified;

  const CachedTorrentEntry({
    required this.infoHash,
    required this.path,
    required this.sizeBytes,
    required this.modified,
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
        ));
      } catch (_) {
        // Skip entries we can't stat/read rather than failing the whole list.
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  static int totalCachedBytes(List<CachedTorrentEntry> entries) =>
      entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

  /// Deletes a cached download. If its torrent is still registered in the
  /// current engine session, goes through the engine (also stops any stream
  /// and updates in-memory state); otherwise just deletes the directory
  /// (e.g. the app was restarted since this was last streamed).
  static Future<void> delete(CachedTorrentEntry entry) async {
    final engine = TorrentEngineService.instance.engine;
    int? liveId;
    for (final t in engine.torrents.entries) {
      if (t.value.savePath == entry.path) {
        liveId = t.key;
        break;
      }
    }

    if (liveId != null) {
      engine.removeTorrent(liveId, deleteFiles: true);
    } else {
      final dir = Directory(entry.path);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    await TorrentDownloadRegistry.remove(entry.infoHash);
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
