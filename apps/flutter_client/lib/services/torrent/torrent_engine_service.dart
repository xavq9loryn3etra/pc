import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'torrent_paths.dart';

class TorrentEngineService {
  static final TorrentEngineService _instance = TorrentEngineService._();
  static TorrentEngineService get instance => _instance;
  TorrentEngineService._();

  bool _initialized = false;
  // Why the last init() attempt failed, if it did — surfaced by
  // streamMagnet() instead of the much vaguer "init() not called" that
  // LibtorrentFlutter.instance throws afterwards.
  Object? _initError;

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
      _initError = null;
    } catch (e) {
      _initError = e;
      print('Error initializing Torrent Engine: $e');
    }
  }

  LibtorrentFlutter get engine => LibtorrentFlutter.instance;

  // High-availability public trackers — appended to every magnet so
  // libtorrent can connect to the swarm immediately via announce URLs
  // instead of relying solely on DHT bootstrap (which can take 1–2 min).
  // Long-running ones from ngosang/trackerslist's "best" list (Oct 2026);
  // UDP only, as our own engine build has no HTTPS support.
  static const _trackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://explodie.org:6969/announce',
    'udp://tracker.dler.org:6969/announce',
    'udp://open.tracker.cl:1337/announce',
  ];

  /// Add magnet, wait for metadata, start stream, return local URL
  Future<StreamResult> streamMagnet(String infoHash, {int? fileIndex}) async {
    if (!_initialized) {
      await init();
    }
    if (!_initialized) {
      throw StateError(
          'The torrent engine failed to start on this device ($_initError)');
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

    // Torrents stay registered after their player closes (see pause()), so
    // a resumed watch doesn't need to refetch already-cached bytes. Pause
    // everything else so the current stream gets the full session-wide
    // _downloadLimitBytesPerSec budget; their downloaded bytes stay on disk
    // untouched. (A failed start leaves the previous stream paused — see
    // resume().)
    for (final otherId in engine.torrents.keys) {
      if (otherId != id) {
        try {
          engine.pauseTorrent(otherId);
        } catch (_) {}
      }
    }
    // In case `id` refers to a torrent from an earlier session that we'd
    // previously paused this same way.
    engine.resumeTorrent(id);

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

    // Give up after 20 seconds: a well-shared torrent's metadata arrives in
    // a few, and the caller usually has other copies to try next (see
    // StreamResolver.resolveWithFallback), so waiting longer mostly just
    // keeps the user staring at "Starting…".
    await completer.future.timeout(
      const Duration(seconds: 20),
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

  /// Stop a torrent entirely — its stream and its downloading — but keep
  /// what it downloaded on disk, so resuming later only fetches the rest.
  /// For a normal player close, and a start the user abandoned (closed the
  /// popup mid-way). Starting the same content again resumes it (see
  /// [streamMagnet]).
  void pause(int torrentId) {
    try {
      engine.stopAllStreamsForTorrent(torrentId);
      engine.pauseTorrent(torrentId);
    } catch (e) {
      print('Error pausing torrent $torrentId: $e');
    }
  }

  /// Undo the pause [streamMagnet] puts every other torrent in — for going
  /// back to what was playing when starting something else failed. Its
  /// stream was never stopped, so the player can just carry on.
  void resume(int torrentId) {
    try {
      engine.resumeTorrent(torrentId);
    } catch (e) {
      print('Error resuming torrent $torrentId: $e');
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
