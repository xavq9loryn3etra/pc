import 'package:path_provider/path_provider.dart';

final _infoHashPattern = RegExp(r'^[0-9a-fA-F]{40}$');

/// Whether [h] is a torrent info hash: 40 hex digits. The finders' answers
/// go into a magnet link and a folder name (see TorrentPaths.savePathFor),
/// so anything else — "&dn=…", "../" — is refused.
bool isValidInfoHash(String h) => _infoHashPattern.hasMatch(h);

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

  /// The engine's saved DHT state (see TorrentEngineService) — beside the
  /// torrents directory, not in it, so clearing downloads leaves it be.
  static Future<String> engineStateFile() async {
    final base = await getApplicationSupportDirectory();
    return '${base.path}/engine_state.dat';
  }

  /// Deterministic per-content save path. Re-adding the same infoHash always
  /// resolves to the same directory, so libtorrent's own piece hash-check
  /// finds and reuses whatever was already downloaded there instead of
  /// starting over.
  static Future<String> savePathFor(String infoHash) async {
    if (!isValidInfoHash(infoHash)) {
      throw ArgumentError.value(infoHash, 'infoHash', 'Not an info hash');
    }
    final dir = await torrentsDir();
    return '$dir/$infoHash';
  }
}
