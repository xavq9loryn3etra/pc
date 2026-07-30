import 'package:path_provider/path_provider.dart';

/// Single source of truth for where torrent data lives on disk, shared by
/// [TorrentEngineService] (which writes here) and the Settings storage
/// screen (which lists/deletes what's here) — keeping both in sync without
/// duplicating the path logic.
class TorrentPaths {
  /// Application-support dir, not the OS temp dir — temp can be purged by the
  /// OS independently of app logic, which would silently break resuming a
  /// partially-downloaded torrent.
  static Future<String> torrentsDir() async {
    final base = await getApplicationSupportDirectory();
    return '${base.path}/torrents';
  }

  /// Deterministic per-content save path. Re-adding the same infoHash always
  /// resolves to the same directory, so libtorrent's own piece hash-check
  /// finds and reuses whatever was already downloaded there instead of
  /// starting over.
  static Future<String> savePathFor(String infoHash) async {
    final dir = await torrentsDir();
    return '$dir/$infoHash';
  }
}
