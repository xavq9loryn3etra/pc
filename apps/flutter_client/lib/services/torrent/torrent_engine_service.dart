import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'download_ahead_settings.dart';
import 'torrent_download_registry.dart';
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
        sessionStatePath: await TorrentPaths.engineStateFile(),
      );
      _keepSessionStateSaved();

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

  Timer? _stateSaveTimer;
  AppLifecycleListener? _lifecycle;

  /// Saves the engine's map of the network (its DHT routing table) every
  /// few minutes and whenever the app leaves the screen — mobile apps are
  /// usually killed in the background rather than closed — so the next
  /// launch restores it (see LibtorrentFlutter.init's sessionStatePath)
  /// and finds peers right away instead of rediscovering the network for
  /// a minute or more first.
  void _keepSessionStateSaved() {
    void save() {
      try {
        if (engine.saveSessionState()) print('Torrent engine state saved');
      } catch (e) {
        print('Error saving torrent engine state: $e');
      }
    }

    _stateSaveTimer =
        Timer.periodic(const Duration(minutes: 3), (_) => save());
    _lifecycle = AppLifecycleListener(onHide: save);
  }

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

  // Torrents added this session, by lowercase info hash — so a torrent
  // that's already connecting (a head start, an earlier play) is reused
  // rather than added again under a second id.
  final Map<String, int> _idsByHash = {};
  // Connections in progress, by lowercase info hash: callers wanting the
  // same torrent at the same time share one wait.
  final Map<String, Future<int>> _connecting = {};
  // Torrents with a stream running: a head start or a lost race finishing
  // late must never pause one of these.
  final Set<int> _streaming = {};
  // Head starts still fetching, by lowercase info hash (see warmUp).
  final Set<String> _warming = {};

  /// Add magnet, wait for metadata, start stream, return local URL
  Future<StreamResult> streamMagnet(
    String infoHash, {
    int? fileIndex,
    List<String> trackers = const [],
  }) async {
    final id = await connect(infoHash, trackers: trackers);
    try {
      return startStream(id, fileIndex: fileIndex);
    } catch (e) {
      cleanup(id);
      rethrow;
    }
  }

  /// Adds [infoHash] (or finds it already added this session), lets it run
  /// and waits for its metadata — the torrent's table of contents, which
  /// has to come from the people sharing it before anything can play.
  /// Returns its id. [trackers] are the finder's own for this torrent, used
  /// next to ours. One that doesn't get its metadata in time is removed if
  /// this call added it.
  Future<int> connect(
    String infoHash, {
    List<String> trackers = const [],
  }) async {
    if (!_initialized) {
      await init();
    }
    if (!_initialized) {
      throw StateError(
          'The torrent engine failed to start on this device ($_initError)');
    }
    final key = infoHash.toLowerCase();
    // Possibly paused (a finished head start, a closed player): resumed
    // even when a connection is already in progress, which a page left
    // mid-head-start pauses (see coolDown).
    final known = _liveId(key);
    if (known != null) engine.resumeTorrent(known);
    // A block body, not `=> _connecting.remove(key)`: that returns the
    // removed future — this one — and whenComplete waits for a returned
    // future, so it would wait on itself forever.
    return _connecting[key] ??= _connect(key, trackers).whenComplete(() {
      _connecting.remove(key);
    });
  }

  /// The id torrent [key] was added under, unless it has since been
  /// removed — Settings > Storage and the player's stall recovery remove
  /// torrents straight from the engine.
  int? _liveId(String key) {
    final id = _idsByHash[key];
    if (id == null) return null;
    // One still connecting may not be in engine.torrents yet.
    if (engine.torrents.containsKey(id) || _connecting.containsKey(key)) {
      return id;
    }
    _idsByHash.remove(key);
    _streaming.remove(id);
    return null;
  }

  Future<int> _connect(String key, List<String> trackers) async {
    final stopwatch = Stopwatch()..start();
    var id = _liveId(key);
    final added = id == null;
    if (id == null) {
      // Build magnet with tracker list for instant swarm discovery
      final trackerParams = {..._trackers, ...trackers}
          .map((t) => '&tr=${Uri.encodeComponent(t)}')
          .join();
      final magnetUri = 'magnet:?xt=urn:btih:$key$trackerParams';

      // Deterministic, per-content save path (not the shared default) — one
      // directory per infoHash means re-streaming the same content later
      // finds and reuses whatever was already downloaded there (libtorrent
      // hash-checks existing files against the piece list on add), and it
      // also means the Storage screen can list/delete cached downloads one
      // directory at a time without risking touching another torrent's
      // files.
      final savePath = await TorrentPaths.savePathFor(key);
      id = engine.addMagnet(magnetUri, savePath);
      _idsByHash[key] = id;
    }
    // In case `id` refers to a torrent paused earlier (see startStream).
    engine.resumeTorrent(id);

    try {
      await _waitForMetadata(id);
      print('[timing] metadata for $key after '
          '${stopwatch.elapsedMilliseconds} ms${added ? '' : ' (reused)'}');
      return id;
    } catch (e) {
      print('[timing] no metadata for $key after '
          '${stopwatch.elapsedMilliseconds} ms');
      // Don't leave a dead torrent behind — especially important now that
      // resolveWithFallback() tries several candidates at once.
      if (added) cleanup(id);
      rethrow;
    }
  }

  /// Starts streaming torrent [id], already [connect]ed, and returns its
  /// local URL. Pauses every other torrent so this one gets the full
  /// download budget.
  StreamResult startStream(int id, {int? fileIndex}) {
    _streaming.add(id);

    // Torrents stay registered after their player closes (see pause()), so
    // a resumed watch doesn't need to refetch already-cached bytes. Pause
    // everything else so the current stream gets the full session-wide
    // _downloadLimitBytesPerSec budget; their downloaded bytes stay on disk
    // untouched. (Includes copies still racing to connect, which then time
    // out and are removed — see connect.)
    for (final otherId in {...engine.torrents.keys, ..._idsByHash.values}) {
      if (otherId != id) {
        // A paused torrent's stream stays open (the player may go back to
        // it — see resume()), so it still counts as streaming.
        try {
          engine.pauseTorrent(otherId);
        } catch (_) {}
      }
    }
    engine.resumeTorrent(id);

    // Get files list
    final files = engine.getFiles(id);
    if (files.isEmpty) {
      throw Exception('No files found in torrent');
    }

    final videoIdx = fileIndex ?? _findLargestVideoFile(files);

    // The head start's stream, already downloading the file's start (see
    // warmUp) — when it's for this same file.
    final warm = _warmStreams.remove(id);
    // The player reads for itself from here on.
    _cancelReadAhead(id);
    final StreamInfo stream;
    if (warm != null && warm.fileIndex == videoIdx) {
      stream = warm;
      print('[timing] playing from the head start '
          '(${((engine.torrents[id]?.totalDone ?? 0) / (1024 * 1024)).toStringAsFixed(1)} MB in)');
    } else {
      if (warm != null) _stopStream(warm.id);
      stream = _openStream(id, videoIdx);
    }
    _logOpening(id);

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
  }

  /// Starts streaming file [fileIndex] of torrent [id].
  StreamInfo _openStream(int id, int fileIndex) {
    // Start stream with a sliding-window piece cache
    final stream = engine.startStream(
      id,
      fileIndex: fileIndex,
      maxCacheBytes: defaultStreamCacheBytes,
    );

    // Preload head + tail of the file (TorrServer-style) so the player's
    // initial probe doesn't stall waiting for container index data —
    // often located at the file's end for MP4 — that hasn't been
    // prioritized yet. This is a likely cause of "has seeds but still
    // fails to start" for certain containers/encodes.
    engine.preloadStream(stream.id);
    return stream;
  }

  void _stopStream(int streamId) {
    try {
      engine.stopStream(streamId);
    } catch (e) {
      print('Error stopping stream $streamId: $e');
    }
  }

  /// Logs torrent [id]'s connections and speed each second for its first
  /// 30s of streaming ("[timing] +3s: …"), to show where a slow start's
  /// time goes: finding people to download from, or downloading from them.
  void _logOpening(int id) {
    var second = 0;
    Timer.periodic(const Duration(seconds: 1), (timer) {
      second++;
      final t = engine.torrents[id];
      if (second > 30 || t == null || !_streaming.contains(id)) {
        timer.cancel();
        return;
      }
      print('[timing] +${second}s: ${t.numPeers} connected '
          '(${t.numSeeds} with the whole file), '
          '${t.downloadRate ~/ 1024} KB/s, '
          '${(t.totalDone / (1024 * 1024)).toStringAsFixed(1)} MB in');
    });
  }

  /// Whether torrent [id] has a stream running.
  bool isStreaming(int id) => _streaming.contains(id);

  /// Whether torrent [infoHash] is in use right now: playing, or getting a
  /// head start (see warmUp). TorrentStorageService's size limit leaves
  /// those alone.
  bool isInUse(String infoHash) {
    final key = infoHash.toLowerCase();
    if (_warming.contains(key)) return true;
    final id = _liveId(key);
    return id != null &&
        (_streaming.contains(id) || _warmStreams.containsKey(id));
  }

  // Streams a head start opened ahead of Play (see warmUp), by torrent id:
  // startStream takes one over instead of opening its own.
  final Map<int, StreamInfo> _warmStreams = {};
  // A head start's reads at the resume position (see _readAhead), by
  // torrent id — cancelled once Play takes over or the page is left.
  final Map<int, HttpClient> _warmReads = {};

  /// How much a head start downloads on mobile data, when the user allows
  /// it at all (DownloadAheadSettings): enough to cut most of the wait,
  /// little enough not to matter.
  static const int _mobileHeadStartBytes = 6 * 1024 * 1024;

  /// How much a head start reads at the resume position: the player starts
  /// there, so the start of the file is no use to it.
  static const int _resumeReadBytes = 16 * 1024 * 1024;

  /// Whether torrent [infoHash] could start at once: added this session
  /// and its metadata in. StreamResolver.resolveWithFallback tries such
  /// copies first.
  bool isReady(String infoHash) {
    final id = _liveId(infoHash.toLowerCase());
    return id != null && (engine.torrents[id]?.hasMetadata ?? false);
  }

  /// A head start for what the user is likely to play next — the movie
  /// page's top pick, an episode's, the next episode near the end of one:
  /// the [targets] are that pick and a couple of others of its quality, as
  /// the pick may turn out to have no one sharing it. They connect at once
  /// and the first to get its metadata is kept, so Play needn't wait for
  /// that. Then, on Wi-Fi, it goes on to download the start of the file
  /// (and its end, which some formats need first) — or, with [resumeAt]
  /// (how far in it was left, 0–1), from there — so Play starts at once,
  /// rather than after the 10–20s it takes the people sharing it to let a
  /// newcomer download at speed. That's some 20–30 MB; on mobile data it's
  /// ~6 MB if the user allows it (DownloadAheadSettings), and otherwise
  /// stops at the metadata (a few KB). Does nothing if a target is already
  /// added (resuming from this session's download, or already warm).
  Future<void> warmUp(List<WarmTarget> targets, {double? resumeAt}) async {
    if (targets.isEmpty) return;
    final keys = [for (final t in targets) t.infoHash.toLowerCase()];
    if (keys.any((k) => _liveId(k) != null)) return;
    _warming.addAll(keys);
    try {
      final winner = Completer<(WarmTarget, int)?>();
      var failed = 0;
      for (final target in targets) {
        final key = target.infoHash.toLowerCase();
        connect(key, trackers: target.trackers).then((id) {
          if (!winner.isCompleted) {
            winner.complete((target, id));
          } else if (!_streaming.contains(id)) {
            // Lost the race: paused, and removed with the rest when the
            // page is left (see coolDown). Not removed now — Play may be
            // starting it this very moment.
            engine.pauseTorrent(id);
          }
        }, onError: (Object _) {
          if (++failed == targets.length && !winner.isCompleted) {
            winner.complete(null);
          }
        });
      }
      final won = await winner.future;
      if (won == null) return;
      final (target, id) = won;
      final key = target.infoHash.toLowerCase();
      // Play got here first, or the page was left meanwhile.
      if (_streaming.contains(id) || !_warming.contains(key)) return;
      final network = await _network();
      if (_streaming.contains(id) || !_warming.contains(key)) return;
      final mobileAllowed = network == _Network.mobile &&
          DownloadAheadSettings().onMobileData.value;
      if (network == _Network.unmetered || mobileAllowed) {
        _prebuffer(id, target.fileIndex,
            resumeAt: resumeAt, small: network == _Network.mobile);
      } else {
        engine.pauseTorrent(id);
      }
    } catch (_) {
      // Only a head start: Play tries again (and other copies) anyway.
    } finally {
      _warming.removeAll(keys);
    }
  }

  Future<_Network> _network() async {
    try {
      final links = await Connectivity().checkConnectivity();
      if (links.contains(ConnectivityResult.wifi) ||
          links.contains(ConnectivityResult.ethernet)) {
        return _Network.unmetered;
      }
      if (links.contains(ConnectivityResult.mobile)) return _Network.mobile;
    } catch (_) {}
    return _Network.none;
  }

  void _prebuffer(
    int id,
    int? fileIndex, {
    double? resumeAt,
    required bool small,
  }) {
    // One head start downloads at a time: one from a page further back
    // waits, paused (startStream resumes it if it's played after all).
    for (final other in _warmStreams.keys) {
      if (other != id) {
        try {
          engine.pauseTorrent(other);
        } catch (_) {}
      }
    }
    try {
      final files = engine.getFiles(id);
      if (files.isEmpty) return;
      final index = fileIndex ?? _findLargestVideoFile(files);
      final file = files.firstWhere((f) => f.index == index,
          orElse: () => files.first);
      // Barely started (under 2%): the start of the file covers it, and
      // gets the full preload.
      final resuming = resumeAt != null && resumeAt > 0.02 && resumeAt < 0.95;
      // Opening the stream already has the engine fetch the file's first
      // and last pieces; preloading adds 16 MB of the start — no use when
      // resuming, or on mobile data.
      final stream = engine.startStream(
        id,
        fileIndex: index,
        maxCacheBytes: defaultStreamCacheBytes,
      );
      if (!resuming && !small) engine.preloadStream(stream.id);
      _warmStreams[id] = stream;
      if (resuming) {
        // A little before the spot, as the player lands on the keyframe
        // before it; the byte offset is a rough guess from the time.
        final offset = (file.size * resumeAt - 2 * 1024 * 1024)
            .clamp(0, file.size)
            .toInt();
        _readAhead(id, stream.url, offset,
            small ? _mobileHeadStartBytes : _resumeReadBytes);
      }
      if (small) _capDownload(id, _mobileHeadStartBytes);
      print('[timing] head start downloading ahead (torrent $id'
          '${resuming ? ', from ${(resumeAt * 100).round()}%' : ''}'
          '${small ? ', mobile data' : ''})');
    } catch (e) {
      print('Error starting head start for torrent $id: $e');
      engine.pauseTorrent(id);
    }
  }

  /// Reads [length] bytes of stream [url] from [offset] and throws them
  /// away — which has the engine download that part, first.
  Future<void> _readAhead(int id, String url, int offset, int length) async {
    final client = HttpClient();
    _warmReads[id] = client;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers
          .set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + length - 1}');
      final response = await request.close();
      await response.drain<void>();
    } catch (_) {
      // Cancelled (Play took over, the page was left) or the stream went.
    } finally {
      if (_warmReads[id] == client) _warmReads.remove(id);
      client.close(force: true);
    }
  }

  void _cancelReadAhead(int id) =>
      _warmReads.remove(id)?.close(force: true);

  /// Pauses torrent [id] once it has downloaded [bytes] more — a head start
  /// on mobile data — unless Play has taken it over by then.
  void _capDownload(int id, int bytes) {
    final from = engine.torrents[id]?.totalDone ?? 0;
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      final t = engine.torrents[id];
      if (t == null || _streaming.contains(id) || !_warmStreams.containsKey(id)) {
        timer.cancel();
      } else if (t.totalDone - from >= bytes) {
        timer.cancel();
        _cancelReadAhead(id);
        engine.pauseTorrent(id);
      }
    });
  }

  /// Ends a [warmUp] that Play didn't take — the user left the page, or the
  /// player. [infoHashes] are its targets. Their downloads stop; what they
  /// got ahead is deleted, being only a few MB of something not watched,
  /// unless it's a download the user already had (Settings > Storage).
  Future<void> coolDown(List<String> infoHashes) async {
    final known = await TorrentDownloadRegistry.loadAll();
    for (final infoHash in infoHashes) {
      final key = infoHash.toLowerCase();
      final stillConnecting = _warming.remove(key);
      final id = _idsByHash[key];
      if (id == null || _streaming.contains(id)) continue;
      _cancelReadAhead(id);
      final warm = _warmStreams.remove(id);
      if (warm != null) _stopStream(warm.id);
      if (stillConnecting) {
        // Its connection times out and is removed (see connect), unless
        // Play picks it up again first.
        try {
          engine.pauseTorrent(id);
        } catch (_) {}
      } else if (known.containsKey(key)) {
        engine.pauseTorrent(id);
      } else {
        cleanup(id);
      }
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
    _idsByHash.removeWhere((_, id) => id == torrentId);
    _streaming.remove(torrentId);
    _warmStreams.remove(torrentId); // Its streams go with it.
    _cancelReadAhead(torrentId);
    try {
      // disposeTorrent() skips a torrent the engine hasn't reported on yet
      // (just added) — remove that one directly.
      if (!engine.disposeTorrent(torrentId)) {
        engine.removeTorrent(torrentId, deleteFiles: true);
      }
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
    _streaming.remove(torrentId);
    _warmStreams.remove(torrentId); // Stopped below.
    _cancelReadAhead(torrentId);
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
    _stateSaveTimer?.cancel();
    _lifecycle?.dispose();
    try {
      engine.saveSessionState();
    } catch (_) {}
    try {
      // Keeps what was downloaded: closing the app mustn't wipe the
      // cached downloads Settings > Storage lists and resuming reuses.
      await engine.dispose(deleteFiles: false);
    } catch (e) {
      print('Error disposing Torrent Engine: $e');
    }
  }
}

/// A torrent for TorrentEngineService.warmUp: its info hash, the finder's
/// trackers for it, and the file Play would stream (null: the largest).
typedef WarmTarget = ({
  String infoHash,
  List<String> trackers,
  int? fileIndex,
});

/// What a head start may spend: Wi-Fi or a cable, metered mobile data, or
/// neither (offline, or unknown).
enum _Network { unmetered, mobile, none }

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
