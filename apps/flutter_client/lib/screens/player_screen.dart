import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart' hide WebPlayer;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/background_download_service.dart';
import '../services/saved_movies_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/torrent_engine_service.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/torrent/torrent_download_registry.dart';
import '../services/tmdb_service.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../widgets/player_gesture_overlay.dart';
import '../widgets/episode_browser.dart';
import '../widgets/player_settings_panel.dart';
import '../widgets/shimmer_loader.dart';
import 'details_screen.dart';
import 'web_player/web_player.dart';
import '../services/scraper_service.dart';
import '../services/subtitle_service.dart';

class PlayerScreen extends StatefulWidget {
  final String url;
  final int torrentId;
  final int streamId;
  final TorrentStream selectedStream;
  final List<TorrentStream> availableStreams;
  final Movie movie;
  final Movie details;
  final int? season;
  final int? episode;
  final List<Episode> episodes;

  const PlayerScreen({
    super.key,
    required this.url,
    required this.torrentId,
    required this.streamId,
    required this.selectedStream,
    required this.availableStreams,
    required this.movie,
    required this.details,
    this.season,
    this.episode,
    required this.episodes,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player player;
  late final VideoController controller;

  // True when we auto-paused for backgrounding, so we only auto-resume
  // playback that we paused ourselves (not a pause the user chose manually
  // right before backgrounding).
  bool _pausedForBackground = false;

  // Mutable Stream/Torrent State
  late TorrentStream _currentStream;
  late int _torrentId;
  late int _streamId;
  late String _streamUrl;
  late int? _currentEpisode;
  late int? _currentSeason;

  // Episode Drawer state
  bool _showEpisodeDrawer = false;
  late int? _browsingSeason;
  late List<Episode> _episodes;
  // True when we auto-paused because the episode browser opened, so we only
  // auto-resume if the user didn't pick a different episode/source while in
  // there (picking one starts its own playback and shouldn't also resume
  // whatever was playing before).
  bool _pausedForEpisodeBrowser = false;

  // Settings Panel state
  bool _showSettingsPanel = false;
  String _settingsPanelInitialView = 'main';

  // Peer & Torrent Statistics — libtorrent emits an update roughly once a
  // second, which isn't a "many times/sec" hot path like position ticks, but
  // it's still a stream-driven, continuous-during-playback update, so it
  // gets the same ValueNotifier treatment to avoid a whole-screen rebuild
  // every second for a small stats pill.
  final ValueNotifier<int> _peersNotifier = ValueNotifier(0);
  final ValueNotifier<double> _downloadSpeedNotifier = ValueNotifier(0.0);
  StreamSubscription? _torrentSub;
  DateTime? _lastProgressPersist;

  // UI Control State
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _switchingQuality = false;
  String? _switchingMessage;

  // Playback position tracking
  // Position/duration/buffer are mirrored into ValueNotifiers so only the
  // seek bar rebuilds on every playback tick, instead of setState() on the
  // whole 700+ line screen build() several times a second.
  Duration _currentPosition = Duration.zero;
  Duration _duration = Duration.zero;
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _bufferNotifier = ValueNotifier(Duration.zero);
  bool _isPlaying = false;
  bool _isDragging = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _bufferingSub;
  List<SubtitleTrackData> _availableSubtitles = [];
  SubtitleTrackData? _selectedSubtitle;
  bool _isLoadingSubtitles = false;
  bool _initialPositionRestored = false;
  double? _pendingResumeSnackbarProgress;
  bool _isMediaOpening =
      true; // True from player.open() until first buffering/play event
  DateTime? _lastSaveTime;

  final _resolver = StreamResolver();
  final _mediaSession = FlutterMediaSession();
  StreamSubscription? _mediaActionSub;

  // Continuous gyro rotation — same approach as web_player_mobile.dart, so
  // the native player rotates to match how the phone is physically held
  // even when the OS's own auto-rotate lock is on (setPreferredOrientations
  // alone only picks between allowed orientations when the system rotate
  // lock is off).
  StreamSubscription? _accelSubscription;
  DeviceOrientation _currentOrientation = DeviceOrientation.landscapeLeft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the screen on for the whole time the player is open — without
    // this, the OS can lock the screen mid-playback (video keeps decoding
    // behind a black/locked screen) since Flutter doesn't request a wakelock
    // on its own.
    WakelockPlus.enable();
    _currentStream = widget.selectedStream;
    _torrentId = widget.torrentId;
    _streamId = widget.streamId;
    _streamUrl = widget.url;
    _currentEpisode = widget.episode;
    _currentSeason = widget.season;
    _browsingSeason = widget.season;
    _episodes = widget.episodes;

    // Enable auto-rotation for the player (landscape only)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initGyroRotation();

    // Initialize media_kit Player
    player = Player();
    controller = VideoController(player);

    _initPlayer();
    _subscribeToTorrent(_torrentId);
    _resetControlsTimer();
    _initMediaSession();
  }

  // Continuously monitor the accelerometer to auto-rotate between
  // landscapeLeft and landscapeRight even when the OS auto-rotate lock is
  // ON — matching web_player_mobile.dart's behavior. Without this, a user
  // with system rotation lock enabled gets stuck in whichever landscape
  // direction the player happened to open in.
  void _initGyroRotation() {
    _accelSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 500),
    ).listen((event) {
      if (!mounted) return;

      // Determine which landscape the phone is physically in:
      // x < -4 => phone top pointing right => landscapeRight
      // x >  4 => phone top pointing left  => landscapeLeft
      // |x| <= 4 => ambiguous / in-between, keep current
      DeviceOrientation? detected;
      if (event.x < -4.0) {
        detected = DeviceOrientation.landscapeRight;
      } else if (event.x > 4.0) {
        detected = DeviceOrientation.landscapeLeft;
      }

      if (detected != null && detected != _currentOrientation) {
        _currentOrientation = detected;
        SystemChrome.setPreferredOrientations([detected]);

        // After rotating, unlock both landscape directions so that
        // subsequent tilts are picked up naturally by the OS too.
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) {
            SystemChrome.setPreferredOrientations([
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
          }
        });
      }
    }, onError: (_) {
      // Sensors unavailable — just allow both landscape directions
      if (mounted) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    });
  }

  Future<void> _initPlayer() async {
    _loadSubtitles();
    // Configure MPV for torrent streaming — P2P data arrives in bursts,
    // so we tune the cache to fill a sensible buffer before starting playback
    // and to re-pause when the buffer drains rather than stalling mid-stream.
    final mpv = player.platform as NativePlayer;
    await mpv.setProperty('cache', 'yes');
    await mpv.setProperty(
        'cache-secs', '60'); // Keep up to 60s of video cached ahead
    await mpv.setProperty('demuxer-readahead-secs',
        '10'); // Fetch 10s ahead (not 30) to start sooner
    await mpv.setProperty('demuxer-max-bytes', '150M'); // 150MB demuxer cache
    await mpv.setProperty(
        'demuxer-max-back-bytes', '50M'); // 50MB back-buffer for seeking
    await mpv.setProperty('cache-pause-initial',
        'yes'); // Pause at startup until initial cache fills
    await mpv.setProperty(
        'cache-pause-wait', '5'); // Re-pause if buffer drops below 5s
    await _openMediaWithResume(_streamUrl);

    // Listen to video position
    _positionSub = player.stream.position.listen((pos) {
      if (mounted && !_isDragging) {
        // Not wrapped in setState — only the seek bar (via _positionNotifier)
        // needs to react to this, not the whole screen, since this fires
        // several times a second during playback.
        _currentPosition = pos;
        _positionNotifier.value = pos;
        // Save progress periodically (throttled) ONLY after initial position is restored
        if (_initialPositionRestored) {
          _saveProgress();
        }
      }
    });

    // Listen to total duration
    _durationSub = player.stream.duration.listen((dur) {
      if (mounted) {
        _duration = dur;
        _durationNotifier.value = dur;
        _updateMediaSessionMetadata();

        if (_pendingResumeSnackbarProgress != null && dur.inSeconds > 0) {
          final targetSeconds =
              (dur.inSeconds * _pendingResumeSnackbarProgress!).round();
          if (targetSeconds > 5) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                backgroundColor: Colors.black.withOpacity(0.85),
                duration: const Duration(seconds: 3),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                content: Row(
                  children: [
                    Icon(Icons.replay, color: AppTheme.primaryColor, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      "Resumed from ${_formatDuration(Duration(seconds: targetSeconds))}",
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
          }
          _pendingResumeSnackbarProgress = null;
        }
      }
    });

    // Listen to play/pause state for premium zoom effect and control bar visibility
    _playingSub = player.stream.playing.listen((val) {
      if (mounted) {
        setState(() {
          _isPlaying = val;
          if (val)
            _isMediaOpening = false; // playback started, hide initial spinner
        });
        // Sync play/pause to notification
        _syncMediaSessionPlaybackState();
        if (val) {
          _resetControlsTimer();
        } else {
          setState(() => _controlsVisible = true);
          _controlsTimer?.cancel();
        }
      }
    });

    // Clear _isMediaOpening as soon as buffering state is first observed
    _bufferingSub = player.stream.buffering.listen((isBuffering) {
      if (mounted && _isMediaOpening) {
        setState(() => _isMediaOpening = false);
      }
    });

    // Listen to video buffer duration (for YouTube-style grayed-out buffered bar).
    // Not wrapped in setState — only the seek bar's secondary track needs this.
    _bufferSub = player.stream.buffer.listen((buf) {
      if (mounted) {
        _bufferNotifier.value = buf;
      }
    });
  }

  // Fully pause playback when the app is backgrounded — otherwise mpv keeps
  // decoding and the torrent keeps downloading at full rate for a screen
  // nobody can see, burning battery and mobile data. Only auto-resumes
  // if we were the ones who paused it (not if the user had already paused).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_isPlaying) {
        _pausedForBackground = true;
        player.pause();
      }
      // Playback pauses, but keep the torrent buffering — a foreground
      // service protects it from Doze/App Standby while backgrounded.
      // Shrink the cache window first though: left at its normal size, the
      // engine keeps pre-fetching the rest of the file even though nobody's
      // watching, which can burn a lot of mobile data for content that
      // might never actually get resumed.
      TorrentEngineService.instance
          .setStreamCacheCapacity(_streamId, _backgroundCacheBytes());
      BackgroundDownloadService.instance.start();
    } else if (state == AppLifecycleState.resumed) {
      if (_pausedForBackground) {
        _pausedForBackground = false;
        player.play();
      }
      TorrentEngineService.instance.setStreamCacheCapacity(
          _streamId, TorrentEngineService.defaultStreamCacheBytes);
      BackgroundDownloadService.instance.stop();
    }
  }

  /// Roughly "2 minutes of this file" in bytes, estimated from its total
  /// size and duration (assumes near-constant bitrate — close enough for
  /// capping background pre-fetch, doesn't need to be exact). Falls back to
  /// a flat cap when size/duration aren't known yet (e.g. backgrounded
  /// right as playback starts, before the player has reported a duration).
  int _backgroundCacheBytes() {
    const flatFallback = 20 * 1024 * 1024; // 20 MB
    const twoMinutes = Duration(minutes: 2);
    final totalBytes = TorrentDownloadRegistry.parseSizeBytes(_currentStream.size);
    if (totalBytes == null || totalBytes <= 0 || _duration.inSeconds <= 0) {
      return flatFallback;
    }
    final bytesPerSecond = totalBytes / _duration.inSeconds;
    final bytes = (bytesPerSecond * twoMinutes.inSeconds).round();
    return bytes.clamp(flatFallback, TorrentEngineService.defaultStreamCacheBytes);
  }

  Future<void> _initMediaSession() async {
    // Only run on Android/iOS
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      await _mediaSession.requestNotificationPermission();
      await _mediaSession.activate();

      // Only show play/pause (no skip buttons)
      await _mediaSession.updateAvailableActions({
        MediaAction.play,
        MediaAction.pause,
        MediaAction.seekTo,
      });

      // Set initial metadata
      await _updateMediaSessionMetadata();

      // Listen for play/pause commands from the notification
      _mediaActionSub = _mediaSession.onMediaAction.listen((action) {
        switch (action) {
          case MediaAction.play:
            player.play();
            break;
          case MediaAction.pause:
            player.pause();
            break;
          case MediaAction.seekTo:
            if (action.seekPosition != null) {
              player.seek(action.seekPosition!);
              _syncMediaSessionPlaybackState();
            }
            break;
          default:
            break;
        }
      });
    } catch (_) {
      // Silently fail — media session is an enhancement, not critical
    }
  }

  void _syncMediaSessionPlaybackState() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _mediaSession.updatePlaybackState(PlaybackState(
      status: _isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused,
      position: _currentPosition,
      speed: 1.0,
    ));
  }

  Future<void> _updateMediaSessionMetadata() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      String title = widget.movie.title;
      String artist = 'Popcorn';

      if (widget.details.type == 'tv' && _currentEpisode != null) {
        final ep = _episodes.firstWhere(
          (e) => e.episodeNumber == _currentEpisode,
          orElse: () => Episode(
            id: 0,
            episodeNumber: _currentEpisode!,
            name: '',
            overview: '',
            voteAverage: 0.0,
          ),
        );
        if (ep.name.isNotEmpty) {
          artist = widget.movie.title;
          title = 'S${_currentSeason}E${_currentEpisode} · ${ep.name}';
        }
      }

      final artwork = widget.details.backdrop ??
          widget.movie.backdrop ??
          widget.details.posterUrl ??
          widget.movie.posterUrl ??
          '';

      await _mediaSession.updateMetadata(MediaMetadata(
        title: title,
        artist: artist,
        album: 'Popcorn',
        artworkUri: artwork,
        duration: _duration,
      ));
    } catch (_) {}
  }

  Future<void> _openMediaWithResume(
    String url, {
    Duration? precisePosition,
    int? overrideSeason,
    int? overrideEpisode,
  }) async {
    final mpv = player.platform as NativePlayer;

    if (precisePosition != null) {
      await mpv.setProperty('start', '${precisePosition.inSeconds}');
      if (mounted) {
        setState(() {
          _isMediaOpening = true;
          _initialPositionRestored = true;
        });
      }
    } else {
      double? progress;
      final s = overrideSeason ?? _currentSeason;
      final e = overrideEpisode ?? _currentEpisode;

      if (s != null && e != null) {
        progress = SavedMoviesService().getEpisodeProgress(
          widget.movie.id,
          s,
          e,
        );
      } else {
        final histMovie =
            SavedMoviesService().getMovieFromHistory(widget.movie.id);
        progress = histMovie?.progress;
      }

      if (progress != null && progress > 0.0 && progress < 0.95) {
        final startPercent = (progress * 100).toStringAsFixed(2);
        await mpv.setProperty('start', '$startPercent%');
        _pendingResumeSnackbarProgress = progress;
      } else {
        await mpv.setProperty('start', '0'); // reset globally persistent option
      }

      if (mounted) {
        setState(() {
          _isMediaOpening = true;
          _initialPositionRestored = true;
        });
      }
    }

    await player.open(Media(url));
    if (_selectedSubtitle != null && _selectedSubtitle!.url.isNotEmpty) {
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          _selectedSubtitle!.url,
          title: _getLanguageName(_selectedSubtitle!.lang),
          language: _selectedSubtitle!.lang,
        ),
      );
    }
  }

  void _subscribeToTorrent(int id) {
    _torrentSub?.cancel();
    _torrentSub = LibtorrentFlutter.instance.torrentUpdates.listen((torrents) {
      final t = torrents[id];
      if (t != null && mounted) {
        _peersNotifier.value = t.numPeers;
        _downloadSpeedNotifier.value = t.downloadRate / 1024 / 1024; // MB/s

        // Persist real download progress (totalDone/totalWanted) so the
        // Settings > Storage screen can show actual progress instead of
        // file size on disk — sparse-allocated files read as ~100% almost
        // immediately regardless of how much has really downloaded, so
        // that figure alone is meaningless for an in-progress download.
        // Throttled like _saveProgress() — this fires on every torrent
        // update (multiple times/sec), too often to persist unthrottled.
        final now = DateTime.now();
        if (_lastProgressPersist == null ||
            now.difference(_lastProgressPersist!) >=
                const Duration(seconds: 5)) {
          _lastProgressPersist = now;
          TorrentDownloadRegistry.updateProgress(
            _currentStream.infoHash,
            downloadedBytes: t.totalDone,
            totalBytes: t.totalWanted > 0 ? t.totalWanted : null,
          );
        }
      }
    });
  }

  void _saveProgress({bool force = false}) {
    if (_duration.inSeconds > 0) {
      final now = DateTime.now();
      // Throttle progress updates to SharedPreferences (every 5 seconds) to avoid CPU/disk churn, unless forced
      if (!force &&
          _lastSaveTime != null &&
          now.difference(_lastSaveTime!) < const Duration(seconds: 5)) {
        return;
      }
      _lastSaveTime = now;

      final double progress = _currentPosition.inSeconds / _duration.inSeconds;
      SavedMoviesService().addToHistory(
        widget.movie,
        season: _currentSeason,
        episode: _currentEpisode,
        progress: progress,
      );
    }
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (_isPlaying) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _isPlaying) {
          setState(() => _controlsVisible = false);
        }
      });
    }
  }

  void _toggleControls() {
    if (!_isPlaying) {
      // Pause screen is not dismissible! Keep controls visible.
      setState(() => _controlsVisible = true);
      return;
    }
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (_controlsVisible) _resetControlsTimer();
    });
  }

  void _playPause() {
    if (_isPlaying) {
      player.pause();
    } else {
      player.play();
    }
  }

  void _skipBackward() {
    final newPos = _currentPosition - const Duration(seconds: 10);
    player.seek(newPos < Duration.zero ? Duration.zero : newPos);
    _syncMediaSessionPlaybackState();
    _resetControlsTimer();
  }

  void _skipForward() {
    final newPos = _currentPosition + const Duration(seconds: 10);
    player.seek(newPos > _duration ? _duration : newPos);
    _syncMediaSessionPlaybackState();
    _resetControlsTimer();
  }

  /// Perform premium mid-playback quality switching keeping exact timestamp
  Future<void> _switchQuality(TorrentStream newStream) async {
    if (newStream.infoHash.toLowerCase() ==
        _currentStream.infoHash.toLowerCase()) return;

    final savedPos = _currentPosition;
    player.pause();

    setState(() {
      _switchingQuality = true;
      _switchingMessage =
          'Switching quality to ${newStream.quality ?? "HD"}...';
      _controlsVisible = false;
      _initialPositionRestored =
          false; // Prevent position listener from saving 0.0 during loading
    });

    try {
      // 1. Dispose old torrent FFI daemon to save resources
      _resolver.cleanup(_torrentId);

      // 2. Spin up new torrent, falling back to the next-best candidate if
      // the chosen quality fails or times out (stale seed counts mean the
      // top pick isn't always the one that actually connects).
      final resolved = await _resolver.resolveWithFallback(
        newStream,
        widget.availableStreams,
      );
      final resolvedStream = resolved.stream;
      final result = resolved.result;

      // 3. Save last played torrent infohash — the one that actually
      // resolved, not necessarily the one originally tapped.
      final prefs = await SharedPreferences.getInstance();
      final String imdbId = widget.details.imdbId ?? widget.details.id;
      final String key = _currentSeason != null && _currentEpisode != null
          ? 'last_played_torrent_${imdbId}_${_currentSeason}_${_currentEpisode}'
          : 'last_played_torrent_$imdbId';
      await prefs.setString(key, resolvedStream.infoHash);
      await TorrentDownloadRegistry.save(
        resolvedStream.infoHash,
        TorrentDownloadInfo(
          movieId: widget.movie.id,
          imdbId: imdbId,
          title: widget.movie.title,
          image: widget.movie.image,
          season: _currentSeason,
          episode: _currentEpisode,
          totalBytes: TorrentDownloadRegistry.parseSizeBytes(resolvedStream.size),
        ),
      );

      // 4. Open new media at exactly saved position natively
      await _openMediaWithResume(result.streamUrl, precisePosition: savedPos);
      player.play();

      if (mounted) {
        setState(() {
          _currentStream = resolvedStream;
          _torrentId = result.torrentId;
          _streamId = result.streamId;
          _streamUrl = result.streamUrl;
          _switchingQuality = false;
          _resetControlsTimer();
        });
        _subscribeToTorrent(_torrentId);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _switchingQuality = false;
          _initialPositionRestored =
              true; // Restore state so subsequent playback tracking works
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[900],
            content: Text('Failed to switch quality: $e'),
          ),
        );
      }
    }
  }

  Future<void> _openWebPlayer(String provider) async {
    await player.stop();

    final s = _currentSeason;
    final e = _currentEpisode;

    await SavedMoviesService().addToHistory(
      widget.movie,
      season: s,
      episode: e,
    );

    final url = ScraperService().getEmbedUrl(
      widget.details.id,
      season: s,
      episode: e,
      imdbId: widget.details.imdbId,
      provider: provider,
    );

    if (!mounted) return;

    Navigator.pop(context); // Close player

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebPlayer(
          url: url,
          onClose: () => Navigator.pop(context),
          movie: widget.movie,
          season: s,
          episode: e,
          episodes: widget.episodes,
          seasons: widget.details.seasons,
          details: widget.details,
        ),
      ),
    );
  }

  /// Same as [_openWebPlayer], but for a specific episode chosen from
  /// [EpisodeBrowser]'s source picker rather than the currently-playing one.
  Future<void> _openWebPlayerForEpisode(
    Episode targetEp,
    int seasonNumber,
    String provider,
  ) async {
    await player.stop();

    await SavedMoviesService().addToHistory(
      widget.movie,
      season: seasonNumber,
      episode: targetEp.episodeNumber,
    );

    final url = ScraperService().getEmbedUrl(
      widget.details.id,
      season: seasonNumber,
      episode: targetEp.episodeNumber,
      imdbId: widget.details.imdbId,
      provider: provider,
    );

    if (!mounted) return;

    Navigator.pop(context); // Close player

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebPlayer(
          url: url,
          onClose: () => Navigator.pop(context),
          movie: widget.movie,
          season: seasonNumber,
          episode: targetEp.episodeNumber,
          episodes: _episodes,
          seasons: widget.details.seasons,
          details: widget.details,
        ),
      ),
    );
  }

  /// Open the full-screen episode browser — pauses playback first (per the
  /// "hidden entirely while browsing" design) and remembers whether we're
  /// the one who paused it, so closing without picking anything can resume.
  void _openEpisodeBrowser() {
    if (_isPlaying) {
      _pausedForEpisodeBrowser = true;
      player.pause();
    }
    setState(() {
      _showEpisodeDrawer = true;
      _controlsVisible = false;
    });
  }

  /// Close the episode browser without having picked a new episode/source —
  /// resumes playback only if [_openEpisodeBrowser] was the one to pause it.
  void _closeEpisodeBrowser() {
    setState(() {
      _showEpisodeDrawer = false;
      if (_pausedForEpisodeBrowser) {
        _pausedForEpisodeBrowser = false;
        player.play();
      } else if (!player.state.playing) {
        _controlsVisible = true;
      }
    });
  }

  /// Generalized Play Episode Function
  Future<void> _playEpisode(Episode targetEp, int seasonNumber) async {
    if (targetEp.isUnreleased) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.black87,
          content: Text("This episode hasn't aired yet."),
        ),
      );
      return;
    }

    setState(() {
      _switchingQuality = true;
      _switchingMessage =
          'Loading Episode: S$seasonNumber E${targetEp.episodeNumber}...';
      _controlsVisible = false;
    });

    player.pause();

    try {
      // 1. Clean up old torrent
      _resolver.cleanup(_torrentId);

      // 2. Fetch streams for the episode — sorted by the same size/quality-
      // aware logic as the quality selector sheet (not seed count).
      final imdbId = widget.details.imdbId ?? widget.details.id;
      final streams = await _resolver.getAvailableStreams(
        imdbId: imdbId,
        type: 'tv',
        season: seasonNumber,
        episode: targetEp.episodeNumber,
      );

      if (streams.isEmpty) {
        throw Exception('No streams found for this episode.');
      }

      // 3. Resolve the best option, falling back to the next-best candidate
      // if it fails or times out.
      final resolved =
          await _resolver.resolveWithFallback(streams.first, streams);
      await _applyResolvedEpisode(
        targetEp,
        seasonNumber,
        resolved.stream,
        resolved.result,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _switchingQuality = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[900],
            content: Text('Failed to play episode: $e'),
          ),
        );
      }
    }
  }

  /// Play a specific episode with a torrent stream the user already chose
  /// (from [EpisodeBrowser]'s source picker) — skips fetching/sorting the
  /// stream list since a choice has already been made, but still resolves
  /// it (with fallback) and shows the same loading overlay as [_playEpisode].
  Future<void> _playEpisodeWithChosenStream(
    Episode targetEp,
    int seasonNumber,
    TorrentStream stream,
  ) async {
    if (targetEp.isUnreleased) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.black87,
          content: Text("This episode hasn't aired yet."),
        ),
      );
      return;
    }

    setState(() {
      _switchingQuality = true;
      _switchingMessage =
          'Loading Episode: S$seasonNumber E${targetEp.episodeNumber}...';
      _controlsVisible = false;
    });

    player.pause();

    try {
      _resolver.cleanup(_torrentId);
      final result = await _resolver.resolve(stream);
      await _applyResolvedEpisode(targetEp, seasonNumber, stream, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _switchingQuality = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[900],
            content: Text('Failed to play episode: $e'),
          ),
        );
      }
    }
  }

  /// Shared tail of [_playEpisode]/[_playEpisodeWithChosenStream]: once a
  /// stream is resolved, save history/last-played, open the media, and
  /// update all the player's episode/torrent state.
  Future<void> _applyResolvedEpisode(
    Episode targetEp,
    int seasonNumber,
    TorrentStream stream,
    StreamResult result,
  ) async {
    final imdbId = widget.details.imdbId ?? widget.details.id;

    await SavedMoviesService().addToHistory(
      widget.movie,
      season: seasonNumber,
      episode: targetEp.episodeNumber,
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      final String key =
          'last_played_torrent_${imdbId}_${seasonNumber}_${targetEp.episodeNumber}';
      await prefs.setString(key, stream.infoHash);
      await TorrentDownloadRegistry.save(
        stream.infoHash,
        TorrentDownloadInfo(
          movieId: widget.movie.id,
          imdbId: imdbId,
          title: widget.movie.title,
          image: widget.movie.image,
          season: seasonNumber,
          episode: targetEp.episodeNumber,
          totalBytes: TorrentDownloadRegistry.parseSizeBytes(stream.size),
        ),
      );
    } catch (e) {
      print('Error saving last played torrent: $e');
    }

    await _openMediaWithResume(
      result.streamUrl,
      overrideSeason: seasonNumber,
      overrideEpisode: targetEp.episodeNumber,
    );

    if (mounted) {
      setState(() {
        _currentStream = stream;
        _torrentId = result.torrentId;
        _streamId = result.streamId;
        _streamUrl = result.streamUrl;
        _currentEpisode = targetEp.episodeNumber;
        _currentSeason = seasonNumber;
        _switchingQuality = false;
        _currentPosition = Duration.zero;
        _duration = Duration.zero;
        _resetControlsTimer();
      });
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = Duration.zero;
      _bufferNotifier.value = Duration.zero;
      _subscribeToTorrent(_torrentId);
      _loadSubtitles();
      _updateMediaSessionMetadata();
    }
  }

  /// Netflix Auto Play Next Episode Feature
  Future<void> _playNextEpisode() async {
    if (_currentEpisode == null || _episodes.isEmpty) return;

    final currentIndex =
        _episodes.indexWhere((e) => e.episodeNumber == _currentEpisode);
    if (currentIndex == -1 || currentIndex >= _episodes.length - 1) return;

    final nextEp = _episodes[currentIndex + 1];
    _playEpisode(nextEp, _currentSeason ?? 1);
  }

  /// Browse and fetch details of a different season
  Future<void> _switchSeason(int seasonNumber) async {
    setState(() {
      _switchingQuality = true;
      _switchingMessage = 'Loading Season $seasonNumber...';
    });

    try {
      final eps = await TMDBService().getSeasonDetails(
        widget.details.id,
        seasonNumber,
      );

      if (mounted) {
        setState(() {
          _browsingSeason = seasonNumber;
          _episodes = eps;
          _switchingQuality = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _switchingQuality = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[900],
            content: Text('Failed to load season details: $e'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _accelSubscription?.cancel();
    // Safety net in case this screen is disposed while still backgrounded.
    BackgroundDownloadService.instance.stop();

    // 1. Reset system navigation and landscape orientation to app defaults
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // 2. Save final history position
    _saveProgress(force: true);

    // Save final torrent download progress too — the periodic update in
    // _subscribeToTorrent is throttled to every 5s, so without this a
    // player closed shortly after the last tick could leave a stale
    // progress figure in Settings > Storage.
    final finalTorrentInfo = LibtorrentFlutter.instance.torrents[_torrentId];
    if (finalTorrentInfo != null) {
      TorrentDownloadRegistry.updateProgress(
        _currentStream.infoHash,
        downloadedBytes: finalTorrentInfo.totalDone,
        totalBytes:
            finalTorrentInfo.totalWanted > 0 ? finalTorrentInfo.totalWanted : null,
      );
    }

    // 3. Cancel subscriptions & timers
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _bufferSub?.cancel();
    _bufferingSub?.cancel();
    _torrentSub?.cancel();
    _controlsTimer?.cancel();
    _mediaActionSub?.cancel();
    _mediaSession.deactivate();

    // 4. Dispose players and release (not delete) the active FFI torrent —
    // keeps whatever was downloaded so resuming this content later doesn't
    // re-fetch it, instead of the old delete-everything-on-close behavior.
    player.dispose();
    _resolver.release(_torrentId);

    // 5. Dispose seek bar / stats notifiers
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _bufferNotifier.dispose();
    _peersNotifier.dispose();
    _downloadSpeedNotifier.dispose();

    super.dispose();
  }

  String _getLanguageName(String code) {
    final cleanCode = code.toLowerCase().trim();
    switch (cleanCode) {
      case 'eng':
      case 'en':
        return 'English';
      case 'spa':
      case 'es':
        return 'Spanish';
      case 'fre':
      case 'fra':
      case 'fr':
        return 'French';
      case 'ger':
      case 'deu':
      case 'de':
        return 'German';
      case 'ita':
      case 'it':
        return 'Italian';
      case 'por':
      case 'pt':
        return 'Portuguese';
      case 'rus':
      case 'ru':
        return 'Russian';
      case 'chi':
      case 'zho':
      case 'zh':
        return 'Chinese';
      case 'jpn':
      case 'ja':
        return 'Japanese';
      case 'ara':
      case 'ar':
        return 'Arabic';
      case 'tur':
      case 'tr':
        return 'Turkish';
      case 'dut':
      case 'nld':
      case 'nl':
        return 'Dutch';
      case 'swe':
      case 'sv':
        return 'Swedish';
      case 'nor':
      case 'no':
        return 'Norwegian';
      case 'dan':
      case 'da':
        return 'Danish';
      case 'fin':
      case 'fi':
        return 'Finnish';
      case 'pol':
      case 'pl':
        return 'Polish';
      case 'ind':
      case 'id':
        return 'Indonesian';
      case 'vie':
      case 'vi':
        return 'Vietnamese';
      case 'hin':
      case 'hi':
        return 'Hindi';
      default:
        return code.toUpperCase();
    }
  }

  Future<void> _loadSubtitles() async {
    final imdbId = widget.details.imdbId ?? widget.movie.imdbId;
    if (imdbId == null || imdbId.isEmpty) {
      print('Subtitle load skipped: No IMDB ID available.');
      return;
    }

    if (mounted) {
      setState(() => _isLoadingSubtitles = true);
    }

    try {
      final isTv = widget.movie.type == 'tv';
      List<SubtitleTrackData> subs;
      if (isTv && _currentSeason != null && _currentEpisode != null) {
        subs = await SubtitleService().fetchSubtitles(
          imdbId,
          season: _currentSeason,
          episode: _currentEpisode,
        );
      } else {
        subs = await SubtitleService().fetchSubtitles(imdbId);
      }

      if (!mounted) return;

      setState(() {
        _availableSubtitles = subs;
        _isLoadingSubtitles = false;
      });

      // Auto-select English subtitle if available
      final engSub = subs.firstWhere(
        (s) => s.lang.toLowerCase() == 'eng' || s.lang.toLowerCase() == 'en',
        orElse: () => subs.isNotEmpty
            ? subs.first
            : SubtitleTrackData(id: '', url: '', lang: ''),
      );

      if (engSub.url.isNotEmpty) {
        _selectSubtitle(engSub);
      }
    } catch (e) {
      print('Error loading subtitles: $e');
      if (mounted) {
        setState(() => _isLoadingSubtitles = false);
      }
    }
  }

  Future<void> _selectSubtitle(SubtitleTrackData? track) async {
    setState(() {
      _selectedSubtitle = track;
    });

    if (track == null || track.url.isEmpty) {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else {
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          track.url,
          title: _getLanguageName(track.lang),
          language: track.lang,
        ),
      );
    }
  }

  void _showSubtitlePicker() {
    _controlsTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.35,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF0C0C0C),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  top: BorderSide(color: Colors.white12, width: 0.5),
                ),
              ),
              padding: const EdgeInsets.only(
                top: 8,
                left: 20,
                right: 20,
                bottom: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(Icons.subtitles_rounded,
                          color: AppTheme.primaryColor, size: 22),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Select Subtitles',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white38, size: 20),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _availableSubtitles.isEmpty
                        ? const Center(
                            child: Text(
                              'No subtitles found for this media',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 14),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: _availableSubtitles.length + 1,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                final isSelected = _selectedSubtitle == null;
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? AppTheme.primaryColor
                                            .withOpacity(0.12)
                                        : Colors.white.withOpacity(0.04),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isSelected
                                          ? AppTheme.primaryColor
                                          : Colors.transparent,
                                      width: 1,
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    title: const Text(
                                      'Subtitles Off',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    trailing: isSelected
                                        ? Icon(Icons.check_circle_rounded,
                                            color: AppTheme.primaryColor,
                                            size: 20)
                                        : null,
                                    onTap: () {
                                      _selectSubtitle(null);
                                      Navigator.pop(sheetContext);
                                    },
                                  ),
                                );
                              }

                              final track = _availableSubtitles[index - 1];
                              final isSelected =
                                  _selectedSubtitle?.id == track.id;
                              final langName = _getLanguageName(track.lang);

                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppTheme.primaryColor.withOpacity(0.12)
                                      : Colors.white.withOpacity(0.04),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected
                                        ? AppTheme.primaryColor
                                        : Colors.transparent,
                                    width: 1,
                                  ),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  title: Text(
                                    langName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  subtitle: Text(
                                    'Track $index',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.4),
                                      fontSize: 11,
                                    ),
                                  ),
                                  trailing: isSelected
                                      ? Icon(Icons.check_circle_rounded,
                                          color: AppTheme.primaryColor,
                                          size: 20)
                                      : null,
                                  onTap: () {
                                    _selectSubtitle(track);
                                    Navigator.pop(sheetContext);
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) => _resetControlsTimer());
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    bool nextEpisodePlayable = false;
    if (widget.details.type == 'tv' &&
        _currentEpisode != null &&
        _episodes.isNotEmpty) {
      final currentIndex =
          _episodes.indexWhere((e) => e.episodeNumber == _currentEpisode);
      if (currentIndex >= 0 && currentIndex < _episodes.length - 1) {
        final nextEp = _episodes[currentIndex + 1];
        nextEpisodePlayable = true;
        if (nextEp.airDate != null) {
          try {
            final date = DateTime.parse(nextEp.airDate!);
            if (date.isAfter(DateTime.now())) {
              nextEpisodePlayable = false;
            }
          } catch (_) {}
        }
      }
    }

    return PopScope(
      canPop: !_showEpisodeDrawer && !_showSettingsPanel,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_showEpisodeDrawer) {
          _closeEpisodeBrowser();
        } else if (_showSettingsPanel) {
          setState(() {
            _showSettingsPanel = false;
            if (!player.state.playing) {
              _controlsVisible = true;
            }
          });
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Layer 1: PlayerGestureOverlay + Video + Controls
            PlayerGestureOverlay(
              enabled: !_showEpisodeDrawer && !_showSettingsPanel,
              onTap: _toggleControls,
              onDoubleTapSeek: (isForward) {
                if (isForward) {
                  _skipForward();
                } else {
                  _skipBackward();
                }
              },
              onSwipeUp: widget.movie.type == 'tv' ? _openEpisodeBrowser : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Video Player (fills entire screen)
                  SizedBox.expand(
                    child: Hero(
                      tag: 'player_hero',
                      child: AnimatedScale(
                        scale: _isPlaying ? 1.0 : 1.04,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeInOutCubic,
                        child: Video(
                          controller: controller,
                          controls:
                              NoVideoControls, // Pure custom controls overlay
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                    ),
                  ),

                  // Switching Quality Spinner
                  if (_switchingQuality)
                    Container(
                      color: Colors.black87,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const ShimmerLoader(size: 90),
                            const SizedBox(height: 16),
                            Text(
                              _switchingMessage ?? 'Switching quality...',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Direct Torrent Initial Buffer Indicator (spins around the central play/pause button)
                  if (!_switchingQuality &&
                      (_isMediaOpening || player.state.buffering))
                    const Center(
                      child: SizedBox(
                        width: 86,
                        height: 86,
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                              AppTheme.primaryColor),
                          strokeWidth: 3.5,
                        ),
                      ),
                    ),

                  // Netflix-Style Interface Overlay
                  AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Cinematic gradient — heavier on bottom for the seek bar
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withOpacity(0.7),
                                  Colors.transparent,
                                  Colors.transparent,
                                  Colors.black
                                      .withOpacity(_isPlaying ? 0.8 : 0.92),
                                ],
                                stops: const [0.0, 0.18, 0.6, 1.0],
                              ),
                            ),
                          ),

                          // When paused: left-side cinematic gradient for metadata (animates in/out)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 350),
                                opacity: !_isPlaying ? 1.0 : 0.0,
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        Colors.black.withOpacity(0.85),
                                        Colors.black.withOpacity(0.4),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.0, 0.35, 0.65],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // ─── TOP BAR ───
                          Positioned(
                            top: 8 + MediaQuery.of(context).padding.top,
                            left: 16,
                            right: 16,
                            child: Row(
                              children: [
                                IconButton(
                                  icon: const Icon(
                                      Icons.arrow_back_ios_new_rounded,
                                      color: Colors.white,
                                      size: 22),
                                  onPressed: () => Navigator.pop(context),
                                ),
                                const SizedBox(width: 8),
                                // Title (visible when playing)
                                if (_isPlaying)
                                  Expanded(
                                    child: Text(
                                      widget.movie.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  )
                                else
                                  const Spacer(),
                                // Torrent stats pill — scoped to its own
                                // ListenableBuilder so the ~1/sec libtorrent
                                // update only rebuilds this pill, not the
                                // whole player screen.
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: ListenableBuilder(
                                    listenable: Listenable.merge([
                                      _downloadSpeedNotifier,
                                      _peersNotifier
                                    ]),
                                    builder: (context, _) => Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.arrow_downward_rounded,
                                            color: Colors.greenAccent.shade400,
                                            size: 12),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${_downloadSpeedNotifier.value.toStringAsFixed(1)} MB/s',
                                          style: TextStyle(
                                              color:
                                                  Colors.greenAccent.shade400,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 11),
                                        ),
                                        Container(
                                          width: 1,
                                          height: 12,
                                          margin: const EdgeInsets.symmetric(
                                              horizontal: 8),
                                          color: Colors.white12,
                                        ),
                                        const Icon(Icons.people_alt_outlined,
                                            color: Colors.white54, size: 12),
                                        const SizedBox(width: 4),
                                        Text('${_peersNotifier.value}',
                                            style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // ─── CENTER PLAY CONTROLS ───
                          Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Big play/pause — slightly elevated with a subtle glow
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.white.withOpacity(0.08),
                                        blurRadius: 30,
                                        spreadRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: _playPause,
                                      borderRadius: BorderRadius.circular(40),
                                      child: Icon(
                                        _isPlaying
                                            ? Icons.pause_circle_filled_rounded
                                            : Icons.play_circle_filled_rounded,
                                        color: Colors.white,
                                        size: 72,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // ─── LEFT METADATA PANEL ───
                          Positioned(
                            left: 32,
                            bottom: 100,
                            width: size.width * 0.38,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 350),
                              opacity:
                                  (!_isPlaying && _controlsVisible) ? 1.0 : 0.0,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // "NOW PLAYING" label
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryColor
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'NOW PLAYING',
                                      style: TextStyle(
                                        color: AppTheme.primaryColor,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 2.0,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  // Title or Logo
                                  if (widget.details.logoUrl != null &&
                                      widget.details.logoUrl!.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: CachedNetworkImage(
                                        imageUrl: widget.details.logoUrl!,
                                        height: 64,
                                        fit: BoxFit.contain,
                                        alignment: Alignment.centerLeft,
                                        errorWidget:
                                            (context, url, error) {
                                          return Text(
                                            widget.movie.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w800,
                                              height: 1.2,
                                            ),
                                          );
                                        },
                                      ),
                                    )
                                  else
                                    Text(
                                      widget.movie.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w800,
                                        height: 1.2,
                                      ),
                                    ),
                                  // TV episode info
                                  if (widget.details.type == 'tv' &&
                                      _currentEpisode != null) ...[
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.white.withOpacity(0.1),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'S$_currentSeason E$_currentEpisode',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: () {
                                            final currentEp =
                                                _episodes.firstWhere(
                                              (ep) =>
                                                  ep.episodeNumber ==
                                                  _currentEpisode,
                                              orElse: () => Episode(
                                                id: 0,
                                                episodeNumber: _currentEpisode!,
                                                name: '',
                                                overview: '',
                                                voteAverage: 0.0,
                                              ),
                                            );
                                            return Text(
                                              currentEp.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: Colors.white60,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500),
                                            );
                                          }(),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  // Description
                                  Text(
                                    () {
                                      if (widget.details.type == 'tv' &&
                                          _currentEpisode != null) {
                                        final currentEp = _episodes.firstWhere(
                                          (ep) =>
                                              ep.episodeNumber ==
                                              _currentEpisode,
                                          orElse: () => Episode(
                                            id: 0,
                                            episodeNumber: _currentEpisode!,
                                            name: '',
                                            overview: '',
                                            voteAverage: 0.0,
                                          ),
                                        );
                                        if (currentEp.overview.isNotEmpty) {
                                          return currentEp.overview;
                                        }
                                      }
                                      return widget.movie.description;
                                    }(),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 11,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ─── BOTTOM BAR ───
                          Positioned(
                            bottom: 16 + MediaQuery.of(context).padding.bottom,
                            left: 24,
                            right: 24,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Seek slider — scoped to a ListenableBuilder over the
                                // position/duration/buffer notifiers so playback ticks
                                // (several times/sec) only rebuild this, not the screen.
                                ListenableBuilder(
                                  listenable: Listenable.merge([
                                    _positionNotifier,
                                    _durationNotifier,
                                    _bufferNotifier
                                  ]),
                                  builder: (context, _) {
                                    final dur = _durationNotifier.value;
                                    return SliderTheme(
                                      data: SliderThemeData(
                                        trackHeight: 3,
                                        activeTrackColor: AppTheme.primaryColor,
                                        secondaryActiveTrackColor:
                                            Colors.white.withOpacity(0.3),
                                        inactiveTrackColor:
                                            Colors.white.withOpacity(0.12),
                                        thumbColor: AppTheme.primaryColor,
                                        thumbShape: const RoundSliderThumbShape(
                                            enabledThumbRadius: 7),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                                overlayRadius: 16),
                                        overlayColor: AppTheme.primaryColor
                                            .withOpacity(0.12),
                                      ),
                                      child: Slider(
                                        value: _positionNotifier.value.inSeconds
                                            .toDouble()
                                            .clamp(
                                                0.0, dur.inSeconds.toDouble()),
                                        secondaryTrackValue: _bufferNotifier
                                            .value.inSeconds
                                            .toDouble()
                                            .clamp(
                                                0.0, dur.inSeconds.toDouble()),
                                        min: 0.0,
                                        max: dur.inSeconds.toDouble() > 0
                                            ? dur.inSeconds.toDouble()
                                            : 1.0,
                                        onChangeStart: (val) {
                                          _isDragging = true;
                                        },
                                        onChanged: (val) {
                                          final d =
                                              Duration(seconds: val.toInt());
                                          _currentPosition = d;
                                          _positionNotifier.value = d;
                                        },
                                        onChangeEnd: (val) {
                                          _isDragging = false;
                                          player.seek(
                                              Duration(seconds: val.toInt()));
                                          _syncMediaSessionPlaybackState();
                                        },
                                      ),
                                    );
                                  },
                                ),
                                // Timestamps + next episode row
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Row(
                                    children: [
                                      ListenableBuilder(
                                        listenable: Listenable.merge([
                                          _positionNotifier,
                                          _durationNotifier
                                        ]),
                                        builder: (context, _) => Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _formatDuration(
                                                  _positionNotifier.value),
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '/ ${_formatDuration(_durationNotifier.value)}',
                                              style: TextStyle(
                                                  color: Colors.white
                                                      .withOpacity(0.35),
                                                  fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      // Quality Selector Button
                                      TextButton.icon(
                                        style: TextButton.styleFrom(
                                          backgroundColor:
                                              Colors.white.withOpacity(0.08),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(6)),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 6),
                                        ),
                                        icon: const Icon(Icons.hd_rounded,
                                            color: Colors.white, size: 18),
                                        label: Text(
                                          _currentStream.quality ?? '1080p',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 11),
                                        ),
                                        onPressed: () {
                                          _controlsTimer?.cancel();
                                          setState(() {
                                            _showSettingsPanel = true;
                                            _settingsPanelInitialView =
                                                'quality';
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 12),
                                      // Subtitle Selector Button
                                      TextButton.icon(
                                        style: TextButton.styleFrom(
                                          backgroundColor:
                                              Colors.white.withOpacity(0.08),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(6)),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 6),
                                        ),
                                        icon: Icon(Icons.subtitles_rounded,
                                            color: _selectedSubtitle != null
                                                ? AppTheme.primaryColor
                                                : Colors.white,
                                            size: 18),
                                        label: Text(
                                          _selectedSubtitle != null
                                              ? _getLanguageName(
                                                  _selectedSubtitle!.lang)
                                              : (_isLoadingSubtitles
                                                  ? 'Loading...'
                                                  : 'Subtitles'),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 11),
                                        ),
                                        onPressed: _isLoadingSubtitles
                                            ? null
                                            : () {
                                                _controlsTimer?.cancel();
                                                setState(() {
                                                  _showSettingsPanel = true;
                                                  _settingsPanelInitialView =
                                                      'subtitles';
                                                });
                                              },
                                      ),
                                      if (widget.details.type == 'tv') ...[
                                        const SizedBox(width: 12),
                                        TextButton.icon(
                                          style: TextButton.styleFrom(
                                            backgroundColor:
                                                Colors.white.withOpacity(0.08),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6)),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 6),
                                          ),
                                          icon: const Icon(
                                              Icons.grid_view_rounded,
                                              color: Colors.white,
                                              size: 16),
                                          label: const Text(
                                            'Episodes',
                                            style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 11),
                                          ),
                                          onPressed: _openEpisodeBrowser,
                                        ),
                                      ],
                                      if (widget.details.type == 'tv') ...[
                                        const SizedBox(width: 12),
                                        TextButton.icon(
                                          style: TextButton.styleFrom(
                                            backgroundColor:
                                                Colors.white.withOpacity(0.08),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6)),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 6),
                                          ),
                                          icon: Icon(Icons.skip_next_rounded,
                                              color: nextEpisodePlayable
                                                  ? Colors.white
                                                  : Colors.white38,
                                              size: 18),
                                          label: Text(
                                            'Next Episode',
                                            style: TextStyle(
                                                color: nextEpisodePlayable
                                                    ? Colors.white
                                                    : Colors.white38,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 11),
                                          ),
                                          onPressed: nextEpisodePlayable
                                              ? _playNextEpisode
                                              : null,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Layer 2: Episode Browser (outside overlay)
            if (_showEpisodeDrawer && widget.movie.type == 'tv')
              Positioned.fill(
                child: EpisodeBrowser(
                  episodes: _episodes,
                  seasons: widget.details.seasons,
                  movie: widget.movie,
                  details: widget.details,
                  imdbId: widget.details.imdbId ?? widget.details.id,
                  currentSeason: _browsingSeason ?? 1,
                  playingSeason: _currentSeason ?? 1,
                  playingEpisode: _currentEpisode ?? 1,
                  resolver: _resolver,
                  onSeasonChanged: _switchSeason,
                  onClose: _closeEpisodeBrowser,
                  onTorrentChosen: (ep, season, stream) {
                    _pausedForEpisodeBrowser = false;
                    setState(() => _showEpisodeDrawer = false);
                    _playEpisodeWithChosenStream(ep, season, stream);
                  },
                  onWebPlayerChosen: (ep, season, provider) {
                    _pausedForEpisodeBrowser = false;
                    setState(() => _showEpisodeDrawer = false);
                    _openWebPlayerForEpisode(ep, season, provider);
                  },
                ),
              ),

            // Layer 3: Unified Settings Panel (outside overlay)
            if (_showSettingsPanel)
              Positioned.fill(
                child: PlayerSettingsPanel(
                  availableSubtitles: _availableSubtitles,
                  selectedSubtitle: _selectedSubtitle,
                  isLoadingSubtitles: _isLoadingSubtitles,
                  onSubtitleSelected: (track) {
                    _selectSubtitle(track);
                  },
                  getLanguageName: _getLanguageName,
                  availableStreams: widget.availableStreams,
                  currentStream: _currentStream,
                  onStreamSelected: (stream) {
                    _switchQuality(stream);
                  },
                  initialView: _settingsPanelInitialView,
                  onClose: () => setState(() {
                    _showSettingsPanel = false;
                    if (!player.state.playing) {
                      _controlsVisible = true;
                    }
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
