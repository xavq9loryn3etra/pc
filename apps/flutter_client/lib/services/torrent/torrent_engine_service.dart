import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'torrent_paths.dart';

class TorrentEngineService {
  static final TorrentEngineService _instance = TorrentEngineService._();
  static TorrentEngineService get instance => _instance;
  TorrentEngineService._();

  bool _initialized = false;

  static const int _downloadLimitBytesPerSec = 10 * 1024 * 1024; // 10 MB/s
  static const int _uploadLimitBytesPerSec = 1 * 1024 * 1024; // 1 MB/s

  /// Normal foreground piece-cache size — how far ahead of the read head a
  /// stream is allowed to buffer. See [setStreamCacheCapacity].
  static const int defaultStreamCacheBytes = 500 * 1024 * 1024; // 500 MB

  Future<void> init() async {
    if (_initialized) return;
    try {
      // Application-support dir, not the OS temp dir — see TorrentPaths for
      // why: temp can be purged by the OS independently of app logic, which
      // would silently undo the "keep downloaded data" behavior below.
      final savePath = await TorrentPaths.torrentsDir();

      await LibtorrentFlutter.init(
        downloadLimit: _downloadLimitBytesPerSec,
        uploadLimit: _uploadLimitBytesPerSec,
        fetchTrackers: true, // Inject public trackers
        defaultSavePath: savePath,
      );

      // Apply explicit session tuning instead of relying on whatever the
      // native library's own hardcoded defaults happen to be. In particular:
      // keep DHT/encryption/transports permissive — a smaller compatible-peer
      // pool makes "fails to stream despite seeds" worse, not better — and
      // raise the per-reader connection limit + preload share so a stream
      // fills its buffer faster once peers are actually available.
      // downloadRateLimit/uploadRateLimit here are in KB/s (vs. bytes/sec
      // above) — kept in sync so this doesn't silently override the caps
      // just set via LibtorrentFlutter.init().
      final defaults = engine.getDefaultConfig();
      engine.configureSession(defaults.copyWith(
        connectionsLimit: 50,
        preloadCache: 70,
        downloadRateLimit: _downloadLimitBytesPerSec ~/ 1024,
        uploadRateLimit: _uploadLimitBytesPerSec ~/ 1024,
        responsiveMode: true,
      ));

      _initialized = true;
    } catch (e) {
      print('Error initializing Torrent Engine: $e');
    }
  }

  LibtorrentFlutter get engine => LibtorrentFlutter.instance;

  // High-availability public trackers — appended to every magnet so
  // libtorrent can connect to the swarm immediately via announce URLs
  // instead of relying solely on DHT bootstrap (which can take 1–2 min).
  static const _trackers = [
    'udp://open.tracker.cl:1337/announce',
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://explodie.org:6969/announce',
    'udp://tracker.internetwarriors.net:1337/announce',
    'udp://9.rarbg.to:2710/announce',
    'https://tracker.tamersunion.org:443/announce',
  ];

  /// Add magnet, wait for metadata, start stream, return local URL
  Future<StreamResult> streamMagnet(String infoHash, {int? fileIndex}) async {
    if (!_initialized) {
      await init();
    }

    // Build magnet with tracker list for instant swarm discovery
    final trackerParams =
        _trackers.map((t) => '&tr=${Uri.encodeComponent(t)}').join();
    final magnetUri = 'magnet:?xt=urn:btih:$infoHash$trackerParams';

    // Deterministic, per-content save path (not the shared default) — one
    // directory per infoHash means re-streaming the same content later finds
    // and reuses whatever was already downloaded there (libtorrent hash-checks
    // existing files against the piece list on add), and it also means the
    // Storage screen can list/delete cached downloads one directory at a time
    // without risking touching another torrent's files.
    final savePath = await TorrentPaths.savePathFor(infoHash);
    final id = engine.addMagnet(magnetUri, savePath);

    try {
      // Wait for metadata (poll torrentUpdates until hasMetadata == true)
      await _waitForMetadata(id);

      // Get files list
      final files = engine.getFiles(id);
      if (files.isEmpty) {
        throw Exception('No files found in torrent');
      }

      final videoIdx = fileIndex ?? _findLargestVideoFile(files);

      // Start stream with a sliding-window piece cache
      final stream = engine.startStream(
        id,
        fileIndex: videoIdx,
        maxCacheBytes: defaultStreamCacheBytes,
      );

      // Preload head + tail of the file (TorrServer-style) so the player's
      // initial probe doesn't stall waiting for container index data —
      // often located at the file's end for MP4 — that hasn't been
      // prioritized yet. This is a likely cause of "has seeds but still
      // fails to start" for certain containers/encodes.
      engine.preloadStream(stream.id);

      return StreamResult(
        torrentId: id,
        streamId: stream.id,
        streamUrl: stream.url,
        fileName: files
            .firstWhere((f) => f.index == videoIdx, orElse: () => files.first)
            .name,
        fileSize: files
            .firstWhere((f) => f.index == videoIdx, orElse: () => files.first)
            .size,
      );
    } catch (e) {
      // Don't leave a dead torrent behind — especially important now that
      // resolveWithFallback() may try several candidates in sequence.
      cleanup(id);
      rethrow;
    }
  }

  Future<void> _waitForMetadata(int id) async {
    final torrent = engine.torrents[id];
    if (torrent != null && torrent.hasMetadata) {
      return;
    }

    final completer = Completer<void>();
    StreamSubscription? subscription;
    subscription = engine.torrentUpdates.listen((torrents) {
      final t = torrents[id];
      if (t != null && t.hasMetadata) {
        subscription?.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });

    // Timeout after 30 seconds if metadata cannot be fetched
    await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        subscription?.cancel();
        throw TimeoutException(
            'Timed out waiting for torrent metadata. Please check your internet connection or peer availability.');
      },
    );
  }

  int _findLargestVideoFile(List<FileInfo> files) {
    int largestIndex = files.first.index;
    int largestSize = files.first.size;
    for (final file in files) {
      if (file.size > largestSize) {
        largestSize = file.size;
        largestIndex = file.index;
      }
    }
    return largestIndex;
  }

  /// Clean up after playback — deletes the downloaded data. Only appropriate
  /// when the content is genuinely being abandoned (e.g. switching quality or
  /// episode mid-session discards the old stream on purpose), not for a
  /// normal player close.
  void cleanup(int torrentId) {
    try {
      engine.disposeTorrent(torrentId);
    } catch (e) {
      print('Error cleaning up torrent $torrentId: $e');
    }
  }

  /// Stop streaming without deleting downloaded data — used when the player
  /// closes but playback might resume later. Keeps whatever was already
  /// fetched (including the read-ahead buffer) on disk instead of the old
  /// delete-everything behavior, so resuming doesn't re-download it. Only
  /// releases the HTTP stream/reader resources; the torrent itself stays
  /// registered in the session and keeps downloading at the same rate as
  /// before — no separate "finish downloading" mode.
  void release(int torrentId) {
    try {
      engine.stopAllStreamsForTorrent(torrentId);
    } catch (e) {
      print('Error releasing torrent $torrentId: $e');
    }
  }

  /// Shrinks or restores how far ahead of the current read position a live
  /// stream is allowed to buffer, without stopping/restarting it. Used to
  /// stop eagerly pre-fetching the rest of the file while the app is
  /// backgrounded and playback isn't advancing — see PlayerScreen's
  /// app-lifecycle handling.
  void setStreamCacheCapacity(int streamId, int capacityBytes) {
    try {
      engine.setCacheSettings(streamId, capacity: capacityBytes);
    } catch (e) {
      print('Error adjusting stream cache: $e');
    }
  }

  /// Full shutdown on app exit
  Future<void> dispose() async {
    try {
      engine.disposeAll();
      await engine.dispose();
    } catch (e) {
      print('Error disposing Torrent Engine: $e');
    }
  }
}

class StreamResult {
  final int torrentId;
  final int streamId;
  final String streamUrl; // http://127.0.0.1:PORT/stream/...
  final String fileName;
  final int fileSize;

  StreamResult({
    required this.torrentId,
    required this.streamId,
    required this.streamUrl,
    required this.fileName,
    required this.fileSize,
  });
}
