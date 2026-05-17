import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

class TorrentEngineService {
  static final TorrentEngineService _instance = TorrentEngineService._();
  static TorrentEngineService get instance => _instance;
  TorrentEngineService._();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      await LibtorrentFlutter.init(
        downloadLimit: 10 * 1024 * 1024,  // 10 MB/s cap
        uploadLimit: 1 * 1024 * 1024,     // 1 MB/s upload cap
        fetchTrackers: true,              // Inject public trackers
      );
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
    final trackerParams = _trackers.map((t) => '&tr=${Uri.encodeComponent(t)}').join();
    final magnetUri = 'magnet:?xt=urn:btih:$infoHash$trackerParams';
    final id = engine.addMagnet(magnetUri);

    // Wait for metadata (poll torrentUpdates until hasMetadata == true)
    await _waitForMetadata(id);

    // Get files list
    final files = engine.getFiles(id);
    if (files.isEmpty) {
      throw Exception('No files found in torrent');
    }

    final videoIdx = fileIndex ?? _findLargestVideoFile(files);

    // Start stream with 500MB sliding window cache
    final stream = engine.startStream(
      id,
      fileIndex: videoIdx,
      maxCacheBytes: 500 * 1024 * 1024,
    );

    return StreamResult(
      torrentId: id,
      streamUrl: stream.url,
      fileName: files.firstWhere((f) => f.index == videoIdx, orElse: () => files.first).name,
      fileSize: files.firstWhere((f) => f.index == videoIdx, orElse: () => files.first).size,
    );
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
        throw TimeoutException('Timed out waiting for torrent metadata. Please check your internet connection or peer availability.');
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

  /// Clean up after playback
  void cleanup(int torrentId) {
    try {
      engine.disposeTorrent(torrentId);
    } catch (e) {
      print('Error cleaning up torrent $torrentId: $e');
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
  final String streamUrl;    // http://127.0.0.1:PORT/stream/...
  final String fileName;
  final int fileSize;

  StreamResult({
    required this.torrentId,
    required this.streamUrl,
    required this.fileName,
    required this.fileSize,
  });
}
