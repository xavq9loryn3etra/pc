import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../widgets/player_route.dart';
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
import '../services/torrent/torrent_storage_service.dart';
import '../services/tmdb_service.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../widgets/player_gesture_overlay.dart';
import '../widgets/episode_browser.dart';
import '../widgets/player_settings_panel.dart';
import '../widgets/glass_blur.dart';
import '../widgets/glass_bubble_bar.dart';
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
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final Player player;
  late final VideoController controller;

  // True when we auto-paused for backgrounding, so we only auto-resume
  // playback that we paused ourselves (not a pause the user chose manually
  // right before backgrounding).
  bool _pausedForBackground = false;

  // Mutable Stream/Torrent State
  late TorrentStream _currentStream;
  // Every torrent found for what's playing now — replaced on an episode
  // switch, so the Quality menu offers the current episode's qualities.
  late List<TorrentStream> _availableStreams;
  late int _torrentId;
  late int _streamId;
  late String _streamUrl;
  late int? _currentEpisode;
  late int? _currentSeason;

  // Episode Drawer state
  // "Logically open" — drives back-button interception, controls-hiding,
  // etc. Flips false the instant a close is requested, before the slide-
  // down animation finishes.
  bool _showEpisodeDrawer = false;
  // "Still in the widget tree" — stays true through the slide-down
  // animation and only flips false once it's actually finished, so the
  // drawer has something to animate out from instead of just vanishing.
  bool _episodeDrawerMounted = false;
  late final AnimationController _episodeDrawerController;
  late final Animation<Offset> _episodeDrawerOffset;
  late int? _browsingSeason;
  // The playing season's episodes (Next Episode, the on-screen title and
  // description, the lock-screen info) vs. the season being looked at in
  // the episode browser — which can differ until an episode from it is
  // picked.
  late List<Episode> _episodes;
  late List<Episode> _browsingEpisodes;
  // True when we auto-paused because the episode browser opened, so we only
  // auto-resume if the user didn't pick a different episode/source while in
  // there (picking one starts its own playback and shouldn't also resume
  // whatever was playing before).
  bool _pausedForEpisodeBrowser = false;

  // Settings Panel state
  bool _showSettingsPanel = false;
  String _settingsPanelInitialView = 'main';

  // Download speed — libtorrent emits an update roughly once a second,
  // which isn't a "many times/sec" hot path like position ticks, but it's
  // still a stream-driven, continuous-during-playback update, so it gets
  // the same ValueNotifier treatment to avoid a whole-screen rebuild every
  // second for one small line of text.
  final ValueNotifier<double> _downloadSpeedNotifier = ValueNotifier(0.0);
  StreamSubscription? _torrentSub;
  DateTime? _lastProgressPersist;

  // UI Control State
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  Timer? _screenTapTimer;
  DateTime? _controlsPointerAt;
  bool _isBuffering = false;
  Timer? _bufferingRevealTimer;
  Timer? _seekRevealTimer;

  // Centre-screen play/pause flash shown on user play/pause. Starts at its
  // end (invisible).
  late final AnimationController _playPauseFlash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    value: 1,
  );
  IconData _flashIcon = Icons.pause_rounded;

  // Video scaling (Fit / Fill), set from the settings panel and
  // remembered across sessions.
  static const _videoFitPrefKey = 'player_video_fit';
  // The viewer's subtitle language ('' = off); English until they choose.
  static const _subtitleLangPrefKey = 'player_subtitle_lang';
  VideoFit _videoFit = VideoFit.fill;
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
  // "Resumed from …", shown for a moment at the top (see _showResumeBadge).
  String? _resumeBadge;
  String? _pendingResumeBadge;
  Timer? _resumeBadgeTimer;
  // True from player.open() until playback is actually progressing (see
  // _checkOpeningFinished) — drives the loading spinner along with
  // _isBuffering.
  bool _isMediaOpening = true;
  // Time since the media was handed to the player, for the "[timing]" log
  // of how long the video took to appear.
  final Stopwatch _openingStopwatch = Stopwatch();
  // Last position seen while opening, to tell real playback (small steady
  // steps) from the initial jump to the resume point.
  Duration? _openingLastPosition;
  // A seek in progress, for the loading ring around play/pause — mpv
  // doesn't report a seek waiting on torrent data as buffering, and its
  // own `seeking` flag proved unreliable for this on devices. So it's
  // tracked from what's visible: on the moment a seek is asked for (see
  // _seekTo), off once playback visibly moves on again (see
  // _checkSeekFinished).
  bool _seekPending = false;
  DateTime? _seekStartedAt;
  Duration? _seekLastPosition;
  DateTime? _lastSaveTime;

  // Stall watchdog — the local torrent HTTP server (serve_range in the
  // native libtorrent_flutter plugin) gives up and drops the connection if
  // a piece never arrives, which mpv doesn't always surface as a clean
  // error; playback just silently stops advancing. Reopening the app and
  // re-streaming the same torrent hits the same swarm/piece and reproduces
  // it, since nothing ever re-verifies or clears the cached save directory
  // on its own — previously the only fix was Settings > Storage > Delete.
  // This watches for position AND real download progress both freezing
  // while we're supposed to be playing, and if so, does that same
  // wipe-and-retry automatically.
  Timer? _stallWatchdogTimer;
  Duration _lastWatchdogPosition = Duration.zero;
  int? _lastWatchdogDownloadedBytes;
  int _stallTicks = 0;
  static const int _stallTicksThreshold = 4; // 4 * 5s = 20s of no progress
  // While the video is still opening: a slow swarm can need longer to find
  // peers, and wiping it would throw away the ones it has already found.
  static const int _openingStallTicksThreshold = 9; // 45s
  bool _recoveringStream = false;
  int _autoRecoverAttempts = 0;
  static const int _maxAutoRecoverAttempts = 2;
  // Copies (info hashes, lower case) that already got stuck while starting,
  // so recovery doesn't go back to them.
  final Set<String> _triedStartHashes = {};
  // The "keeps stalling" message is shown once, not on every later stall.
  bool _stallMessageShown = false;

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
    _availableStreams = widget.availableStreams;
    _torrentId = widget.torrentId;
    _streamId = widget.streamId;
    _streamUrl = widget.url;
    _currentEpisode = widget.episode;
    _currentSeason = widget.season;
    _browsingSeason = widget.season;
    _episodes = widget.episodes;
    _browsingEpisodes = widget.episodes;

    // Enable auto-rotation for the player (landscape only)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initGyroRotation();

    // Episode drawer slide up/down — starts "dismissed" (off the bottom of
    // the screen) since the drawer isn't open yet.
    _episodeDrawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _episodeDrawerOffset = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _episodeDrawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    // Initialize media_kit Player
    player = Player();
    controller = VideoController(player);

    _initPlayer();
    _subscribeToTorrent(_torrentId);
    _resetControlsTimer();
    _initMediaSession();
    _loadVideoFit();
  }

  Future<void> _loadVideoFit() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_videoFitPrefKey);
    for (final fit in VideoFit.values) {
      if (fit.name == saved) {
        if (mounted) setState(() => _videoFit = fit);
        return;
      }
    }
  }

  void _selectVideoFit(VideoFit fit) {
    setState(() => _videoFit = fit);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_videoFitPrefKey, fit.name));
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
    // Multi-language releases often make a dub their default audio track;
    // pick the English one when there is one (StreamResolver.languageRank
    // already prefers English-only releases).
    await mpv.setProperty('alang', 'eng,en,english');
    // Subscribe to playing/buffering *before* opening the media: events
    // fired while it opens (playback starting, buffering on/off) were
    // previously missed depending on timing, leaving the loading spinner
    // and play/pause state stuck wrong.
    // Listen to play/pause state for premium zoom effect and control bar visibility
    _playingSub = player.stream.playing.listen((val) {
      if (mounted) {
        // Not a signal that loading finished: mpv reports "playing" as soon
        // as it's told to play, before any video has arrived. See
        // _checkOpeningFinished for what ends the opening state.
        setState(() => _isPlaying = val);
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

    // Mid-playback stalls. Also not used to end the opening state — opening
    // emits a "not buffering" reset before the stream has even connected.
    _bufferingSub = player.stream.buffering.listen((isBuffering) {
      if (!mounted) return;
      setState(() => _isBuffering = isBuffering);
      // The loading spinner rings the play/pause button, which lives in the
      // controls — so bring them up for any stall long enough to notice
      // (not the momentary blip after every seek), and let them auto-hide
      // again once playback resumes.
      _bufferingRevealTimer?.cancel();
      if (isBuffering) {
        _bufferingRevealTimer = Timer(const Duration(milliseconds: 600), () {
          if (!mounted || !_isBuffering) return;
          _controlsTimer?.cancel();
          setState(() => _controlsVisible = true);
        });
      } else {
        _resetControlsTimer();
      }
    });

    await _openMediaWithResume(_streamUrl);

    // Listen to video position
    _positionSub = player.stream.position.listen((pos) {
      if (mounted && !_isDragging) {
        // Not wrapped in setState — only the seek bar (via _positionNotifier)
        // needs to react to this, not the whole screen, since this fires
        // several times a second during playback.
        _currentPosition = pos;
        _positionNotifier.value = pos;
        if (_isMediaOpening) _checkOpeningFinished(pos);
        if (_seekPending) _checkSeekFinished(pos);
        _maybeReadyNextEpisode(pos);
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
        _rememberEpisodeLength(dur);

        if (_pendingResumeSnackbarProgress != null && dur.inSeconds > 0) {
          final targetSeconds =
              (dur.inSeconds * _pendingResumeSnackbarProgress!).round();
          if (targetSeconds > 5) {
            // Shown once the video is actually playing (see
            // _checkOpeningFinished), not over the black loading screen.
            _pendingResumeBadge =
                'Resumed from ${_formatDuration(Duration(seconds: targetSeconds))}';
          }
          _pendingResumeSnackbarProgress = null;
        }
      }
    });

    // Listen to video buffer duration (for YouTube-style grayed-out buffered bar).
    // Not wrapped in setState — only the seek bar's secondary track needs this.
    _bufferSub = player.stream.buffer.listen((buf) {
      if (mounted) {
        _bufferNotifier.value = buf;
      }
    });

    // See the _stallWatchdogTimer field doc for why this exists.
    _stallWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkForStall();
    });
  }

  /// Ends the opening state once playback is genuinely under way: playing,
  /// not buffering, and the position moving forward in small steps. A
  /// single "playing"/"not buffering" event isn't enough (both fire before
  /// the stream connects), and the first position change is often the jump
  /// to the resume point rather than playback.
  void _checkOpeningFinished(Duration pos) {
    final last = _openingLastPosition;
    _openingLastPosition = pos;
    if (last == null || !_isPlaying || _isBuffering) return;
    final step = pos - last;
    if (step > Duration.zero && step < const Duration(seconds: 2)) {
      setState(() => _isMediaOpening = false);
      print('[timing] video playing ${_openingStopwatch.elapsedMilliseconds} '
          'ms after the player opened it');
      // Loaded: now the controls can start counting down to hide.
      _resetControlsTimer();
      final resumedFrom = _pendingResumeBadge;
      _pendingResumeBadge = null;
      if (resumedFrom != null) _showResumeBadge(resumedFrom);
    }
  }

  /// Seeks to [target], ringing play/pause with the loading spinner until
  /// playback carries on (see _seekPending) — and, like a stall, bringing
  /// the controls up to show it if that takes long enough to notice.
  void _seekTo(Duration target) {
    player.seek(target);
    setState(() {
      _seekPending = true;
      _seekStartedAt = DateTime.now();
      _seekLastPosition = null;
    });
    _seekRevealTimer?.cancel();
    _seekRevealTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || !_seekPending) return;
      _controlsTimer?.cancel();
      setState(() => _controlsVisible = true);
    });
  }

  /// Ends _seekPending once playback visibly moves on: two position ticks
  /// in a small forward step while playing — whatever spot it landed on.
  /// Ticks from just after the seek was asked for are skipped (they can
  /// still be the old position playing on); while paused, any later tick
  /// means it's arrived. Gives up after [_seekRingLimit] whatever happens
  /// — a seek that never gets going is the stall watchdog's business.
  static const _seekRingLimit = Duration(seconds: 20);

  void _checkSeekFinished(Duration pos) {
    final startedAt = _seekStartedAt;
    if (startedAt == null) return;
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed >= _seekRingLimit) {
      _finishSeek();
      return;
    }
    if (elapsed < const Duration(milliseconds: 300)) return;
    if (!_isPlaying) {
      _finishSeek();
      return;
    }
    final last = _seekLastPosition;
    _seekLastPosition = pos;
    if (last == null) return;
    final step = pos - last;
    if (step > Duration.zero && step < const Duration(seconds: 2)) {
      _finishSeek();
    }
  }

  void _finishSeek() {
    setState(() {
      _seekPending = false;
      _seekStartedAt = null;
    });
    // Playing again: the controls can hide as usual.
    _resetControlsTimer();
  }

  /// Ticks every 5s (see [_stallWatchdogTimer]). If both playback position
  /// and real torrent download bytes stay completely flat for
  /// [_stallTicksThreshold] consecutive ticks while we're supposed to be
  /// actively playing, treats it as a stuck stream and attempts recovery.
  /// Requiring *both* to be flat (not just position) avoids false-triggering
  /// on a decoder-side hiccup that has nothing to do with missing torrent
  /// data — wiping and re-downloading wouldn't fix that anyway.
  void _checkForStall() {
    // Deliberately runs while the media is still opening too: a stream that
    // never connects (no download progress for 20s) is exactly what this
    // should recover from.
    if (!mounted ||
        !_isPlaying ||
        _isDragging ||
        _switchingQuality ||
        _recoveringStream) {
      _stallTicks = 0;
      _lastWatchdogPosition = _currentPosition;
      _lastWatchdogDownloadedBytes =
          LibtorrentFlutter.instance.torrents[_torrentId]?.totalDone;
      return;
    }

    // Near the natural end of the content — that's completion, not a stall.
    if (_duration.inSeconds > 0 &&
        _currentPosition >= _duration - const Duration(seconds: 2)) {
      _stallTicks = 0;
      return;
    }

    final downloadedBytes =
        LibtorrentFlutter.instance.torrents[_torrentId]?.totalDone;
    final positionStuck = _currentPosition == _lastWatchdogPosition;
    final downloadStuck = _lastWatchdogDownloadedBytes == null ||
        downloadedBytes == null ||
        downloadedBytes <= _lastWatchdogDownloadedBytes!;

    _stallTicks = (positionStuck && downloadStuck) ? _stallTicks + 1 : 0;
    _lastWatchdogPosition = _currentPosition;
    _lastWatchdogDownloadedBytes = downloadedBytes;

    final threshold = _isMediaOpening
        ? _openingStallTicksThreshold
        : _stallTicksThreshold;
    if (_stallTicks >= threshold) {
      _stallTicks = 0;
      _attemptStreamRecovery(
        reason: 'No playback or download progress for ${threshold * 5}s',
      );
    }
  }

  /// Recovers from a stalled/stuck stream: wipes this torrent's cached save
  /// directory (the same operation Settings > Storage's manual "Delete"
  /// performs — see TorrentStorageService.deleteByInfoHash) and re-resolves
  /// a fresh stream, falling back to a different source if this exact one
  /// keeps failing. Previously this required the user to notice playback
  /// had died, back out to Settings, and delete the cached file by hand;
  /// this does the same thing automatically, in place.
  Future<void> _attemptStreamRecovery({String? reason}) async {
    if (_recoveringStream || _switchingQuality || !mounted) return;

    if (_autoRecoverAttempts >= _maxAutoRecoverAttempts) {
      // Already auto-retried enough times this session — if it's still
      // stuck, the torrent itself is likely the problem (e.g. no real
      // seeds for this piece range), and retrying forever would just
      // thrash. Surface it instead of silently looping.
      if (_stallMessageShown) return;
      _stallMessageShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red[900],
          duration: const Duration(seconds: 6),
          content: const Text(
            'Playback keeps stalling — this source may be unavailable. '
            'Try a different one from the quality menu.',
          ),
        ),
      );
      return;
    }

    print('Stream recovery triggered: $reason');
    _autoRecoverAttempts++;
    _recoveringStream = true;
    final resumeAt = _currentPosition;
    final staleInfoHash = _currentStream.infoHash;
    final stuckTorrentId = _torrentId;

    // Still starting: nothing's downloaded that could be damaged, so wiping
    // this copy and starting it over would only lose the peers it has
    // found. Move on to the next copy of the same quality instead.
    _triedStartHashes.add(staleInfoHash.toLowerCase());
    final otherCopies = _isMediaOpening
        ? StreamResolver.sameQuality(_currentStream, _availableStreams)
            .where((s) => !_triedStartHashes.contains(s.infoHash.toLowerCase()))
            .toList()
        : const <TorrentStream>[];

    if (mounted) {
      setState(() {
        _switchingQuality = true;
        _switchingMessage = 'Reconnecting…';
        // Kept up until the new video is playing (see
        // _resetControlsTimer).
        _controlsVisible = true;
        _initialPositionRestored = false;
      });
    }

    player.pause();

    try {
      final StreamResolveResult resolved;
      if (otherCopies.isNotEmpty) {
        // Starting one pauses the stuck copy (see
        // TorrentEngineService.startStream), so a failure can go back to
        // it.
        resolved = await _resolver.resolveWithFallback(
          otherCopies.first,
          otherCopies,
        );
        await _rememberPlayedTorrent(resolved.stream);
      } else {
        // Wipe the stuck torrent's cached data (also removes the live
        // handle if it's still registered) so the retry doesn't just reuse
        // whatever was stuck on disk.
        await TorrentStorageService.deleteByInfoHash(staleInfoHash);
        resolved = await _resolver.resolveWithFallback(
          _currentStream,
          _availableStreams,
        );
      }
      final resolvedStream = resolved.stream;
      final result = resolved.result;

      await _openMediaWithResume(result.streamUrl, precisePosition: resumeAt);
      player.play();
      if (otherCopies.isNotEmpty && stuckTorrentId != result.torrentId) {
        _resolver.cleanup(stuckTorrentId);
      }

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
      if (otherCopies.isNotEmpty) {
        // No other copy started either: carry on waiting for the first
        // one (the watchdog checks it again).
        _returnAfterFailedSwitch(resumePlayback: true);
      }
      if (mounted) {
        setState(() {
          _switchingQuality = false;
          _initialPositionRestored = true;
        });
        if (otherCopies.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.red[900],
              content: Text('Failed to recover playback: $e'),
            ),
          );
        }
      }
    } finally {
      _recoveringStream = false;
    }
  }

  /// Remembers [stream] as the torrent this title/episode plays from — for
  /// resuming with it later, and for Settings > Storage.
  Future<void> _rememberPlayedTorrent(TorrentStream stream) async {
    final prefs = await SharedPreferences.getInstance();
    final String imdbId = widget.details.imdbId ?? widget.details.id;
    final String key = _currentSeason != null && _currentEpisode != null
        ? 'last_played_torrent_${imdbId}_${_currentSeason}_${_currentEpisode}'
        : 'last_played_torrent_$imdbId';
    await prefs.setString(key, stream.infoHash);
    await TorrentDownloadRegistry.save(
      stream.infoHash,
      TorrentDownloadInfo(
        movieId: widget.movie.id,
        imdbId: imdbId,
        title: widget.movie.title,
        image: widget.movie.image,
        season: _currentSeason,
        episode: _currentEpisode,
        totalBytes: TorrentDownloadRegistry.parseSizeBytes(stream.size),
      ),
    );
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
            // No seeking until the video has loaded (see _loadingVideo).
            if (action.seekPosition != null && !_loadingVideo) {
              _seekTo(action.seekPosition!);
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
    _openingStopwatch
      ..reset()
      ..start();

    if (precisePosition != null) {
      await mpv.setProperty('start', '${precisePosition.inSeconds}');
      if (mounted) {
        setState(() {
          _isMediaOpening = true;
          _openingLastPosition = null;
          _seekPending = false;
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
          _openingLastPosition = null;
          _seekPending = false;
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

  // Returns a Future so callers that are about to tear down the current
  // episode/torrent (e.g. _playEpisode switching to the next one) can await
  // it — otherwise the SharedPreferences write can lose the race against
  // _applyResolvedEpisode's addToHistory() call for the *new* episode,
  // which overwrites the same 'continue watching' entry.
  Future<void> _saveProgress({bool force = false}) async {
    // Mid-switch (quality, episode, stall recovery) the position and
    // duration can briefly belong to a different video than the one
    // _currentSeason/_currentEpisode name — a periodic save then would
    // record the wrong episode. Forced saves are the deliberate ones made
    // just before a switch, while everything still matches.
    if (_switchingQuality && !force) return;
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
      await SavedMoviesService().addToHistory(
        widget.movie,
        season: _currentSeason,
        episode: _currentEpisode,
        progress: progress,
      );
    }
  }

  /// Hides the controls after 4s of playback — but not while a video is
  /// still loading (opening, or a quality / episode switch): mpv reports
  /// "playing" before any picture arrives, so they'd vanish mid-load.
  /// _checkOpeningFinished starts the countdown once it really plays.
  bool get _loadingVideo => _isMediaOpening || _switchingQuality;

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (_isPlaying && !_loadingVideo) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        // Not mid-seek either, while its ring is showing.
        if (mounted && _isPlaying && !_loadingVideo && !_seekPending) {
          setState(() => _controlsVisible = false);
        }
      });
    }
  }

  // A single tap in the middle third of the screen plays/pauses (pausing
  // also brings the controls up — see the playing listener); on either
  // side — the double-tap seek areas — it just shows/hides the controls.
  // Either way it waits out the gesture overlay's 320ms double-tap window
  // first, so a double-tap seek can cancel it.
  //
  // The overlay listens to raw pointers over the whole screen, controls
  // included, so taps on the top/bottom bars (back button, seek bar,
  // buttons) are marked and skipped here — they do their own thing.
  void _onScreenTap(Offset position) {
    final onControls = _controlsPointerAt != null &&
        DateTime.now().difference(_controlsPointerAt!) <
            const Duration(seconds: 1);
    _controlsPointerAt = null;
    if (onControls) return;

    final width = MediaQuery.of(context).size.width;
    final inMiddle =
        position.dx > width / 3 && position.dx < width * 2 / 3;
    _screenTapTimer?.cancel();
    _screenTapTimer = Timer(const Duration(milliseconds: 320),
        inMiddle ? _playPause : _toggleControls);
  }

  void _toggleControls() {
    // While paused, or still loading, the controls stay up (neither screen
    // is dismissible).
    if (!_isPlaying || _loadingVideo) {
      setState(() => _controlsVisible = true);
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _resetControlsTimer();
  }

  void _markControlsPointer(PointerDownEvent _) =>
      _controlsPointerAt = DateTime.now();

  /// Records how long this copy of the episode really is — TMDB's runtime
  /// can be well off (a 17-minute edit listed as 24m) — for its card and
  /// "time left" (see SavedMoviesService.saveEpisodeLength), here and in
  /// the episode browser.
  void _rememberEpisodeLength(Duration length) {
    final s = _currentSeason, e = _currentEpisode;
    if (s == null || e == null || length.inSeconds < 60) return;
    SavedMoviesService().saveEpisodeLength(widget.movie.id, s, e, length);
    final minutes = SavedMoviesService().getEpisodeMinutes(widget.movie.id, s, e);
    List<Episode> updated(List<Episode> eps) => [
          for (final ep in eps)
            ep.episodeNumber == e ? ep.withRuntime(minutes) : ep,
        ];
    setState(() {
      _episodes = updated(_episodes);
      if (_browsingSeason == s) _browsingEpisodes = updated(_browsingEpisodes);
    });
  }

  void _showResumeBadge(String text) {
    setState(() => _resumeBadge = text);
    _resumeBadgeTimer?.cancel();
    _resumeBadgeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _resumeBadge = null);
    });
  }

  static const _badgeTextStyle = TextStyle(
    color: Colors.white,
    fontSize: 13,
    fontWeight: FontWeight.w700,
  );

  /// A small frosted-glass pill centred at [top], fading in and out with
  /// [visible] — passing notes over the video, whether or not the controls
  /// are showing.
  Widget _glassBadge({
    required double top,
    required bool visible,
    required List<Widget> children,
  }) {
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: GlassBlur(
                reducedTint: Colors.black.withValues(alpha: 0.45),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: ShapeDecoration(
                    color: kGlassTint,
                    shape: StadiumBorder(side: BorderSide(color: kGlassEdge)),
                  ),
                  child:
                      Row(mainAxisSize: MainAxisSize.min, children: children),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Press-and-hold on the video plays at 2× until the finger lifts
  // (PlayerGestureOverlay.onHoldStart / onHoldEnd), with a badge saying so.
  bool _speedBoost = false;

  void _startSpeedBoost() {
    // Only over the video itself (a finger held on the controls, e.g. the
    // seek bar, landed there first — see _markControlsPointer), and only
    // while it's actually playing.
    final onControls = _controlsPointerAt != null &&
        DateTime.now().difference(_controlsPointerAt!) <
            const Duration(seconds: 2);
    if (onControls || !_isPlaying || _loadingVideo || _isDragging) return;
    player.setRate(2.0);
    HapticFeedback.lightImpact();
    setState(() => _speedBoost = true);
  }

  void _endSpeedBoost() {
    if (!_speedBoost) return;
    player.setRate(1.0);
    setState(() => _speedBoost = false);
  }

  void _playPause() {
    if (_isPlaying) {
      player.pause();
    } else {
      player.play();
    }
    // Flash what just happened in the middle of the screen, since the
    // play/pause button itself is tucked into the bottom bar.
    setState(() => _flashIcon =
        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded);
    _playPauseFlash.forward(from: 0);
  }

  void _skipBackward() => _skipBy(const Duration(seconds: -10));

  void _skipForward() => _skipBy(const Duration(seconds: 10));

  // Rapid skips (a double-tap seek streak taps every ~300ms) build on the
  // previous skip's target: the reported position can lag behind a seek,
  // especially on a torrent stream, so basing each on _currentPosition
  // would make some taps land on the same spot.
  Duration? _lastSkipTarget;
  DateTime? _lastSkipAt;

  void _skipBy(Duration delta) {
    final now = DateTime.now();
    final base = _lastSkipTarget != null &&
            _lastSkipAt != null &&
            now.difference(_lastSkipAt!) < const Duration(milliseconds: 1500)
        ? _lastSkipTarget!
        : _currentPosition;
    var target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    _lastSkipTarget = target;
    _lastSkipAt = now;
    _seekTo(target);
    _syncMediaSessionPlaybackState();
    _resetControlsTimer();
  }

  /// Perform premium mid-playback quality switching keeping exact timestamp
  Future<void> _switchQuality(TorrentStream newStream) async {
    if (newStream.infoHash.toLowerCase() ==
        _currentStream.infoHash.toLowerCase()) return;

    final savedPos = _currentPosition;
    final wasPlaying = _isPlaying;
    final oldTorrentId = _torrentId;
    player.pause();

    setState(() {
      _switchingQuality = true;
      _switchingMessage =
          'Switching to ${QualityOption(StreamResolver.tierOf(newStream), [newStream]).name}…';
      // Kept up until the new video is playing (see
      // _resetControlsTimer).
      _controlsVisible = true;
      _initialPositionRestored =
          false; // Prevent position listener from saving 0.0 during loading
    });

    try {
      // 1. The old torrent stays until the new one is up (just paused by
      // starting it — see TorrentEngineService.startStream), so a failed
      // switch can go back to it instead of leaving nothing to play.

      // 2. Spin up new torrent, falling back to the quality's other
      // torrents if it fails or times out (stale seed counts mean the top
      // pick isn't always the one that actually connects) — never to a
      // different quality than the one picked.
      final resolved = await _resolver.resolveWithFallback(
        newStream,
        StreamResolver.sameQuality(newStream, _availableStreams),
      );
      final resolvedStream = resolved.stream;
      final result = resolved.result;

      // 3. Save last played torrent infohash — the one that actually
      // resolved, not necessarily the one originally tapped.
      await _rememberPlayedTorrent(resolvedStream);

      // 4. Open new media at exactly saved position natively
      await _openMediaWithResume(result.streamUrl, precisePosition: savedPos);
      player.play();

      // 5. Now the new one plays, discard the old torrent and its data.
      if (oldTorrentId != result.torrentId) _resolver.cleanup(oldTorrentId);

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
      _returnAfterFailedSwitch(resumePlayback: wasPlaying);
      if (mounted) {
        setState(() {
          _switchingQuality = false;
          _initialPositionRestored =
              true; // Restore state so subsequent playback tracking works
        });
        // Back to the video that was already playing: the controls can
        // hide again as usual.
        _resetControlsTimer();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[900],
            content: Text('Couldn\'t switch quality, so it\'s staying on '
                '${_currentStream.quality ?? "the current one"}. ($e)'),
          ),
        );
      }
    }
  }

  /// After a quality or episode switch failed: carry on with what was
  /// playing. Its torrent was only paused by the attempt (see
  /// TorrentEngineService.startStream) and its media is still loaded.
  void _returnAfterFailedSwitch({required bool resumePlayback}) {
    _resolver.resume(_torrentId);
    if (resumePlayback) player.play();
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
      PlayerRoute(
        builder: (_) => WebPlayer(
          url: url,
          onClose: () => Navigator.pop(context),
          movie: widget.movie,
          season: s,
          episode: e,
          episodes: _episodes,
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
      PlayerRoute(
        builder: (_) => WebPlayer(
          url: url,
          onClose: () => Navigator.pop(context),
          movie: widget.movie,
          season: seasonNumber,
          episode: targetEp.episodeNumber,
          episodes:
              seasonNumber == _browsingSeason ? _browsingEpisodes : _episodes,
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
      _episodeDrawerMounted = true;
      _controlsVisible = false;
      // Always open on the season that's playing.
      _browsingSeason = _currentSeason;
      _browsingEpisodes = _episodes;
    });
    _episodeDrawerController.forward();
  }

  /// Slides the episode drawer down and unmounts it once that finishes.
  /// Doesn't touch playback state — callers decide that separately (resume
  /// after a cancelled browse vs. jumping straight into a newly chosen
  /// episode), this just handles the drawer's own exit animation.
  void _animateEpisodeDrawerClosed() {
    _episodeDrawerController.reverse().whenComplete(() {
      if (mounted) setState(() => _episodeDrawerMounted = false);
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
    _animateEpisodeDrawerClosed();
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
          'Loading S$seasonNumber · E${targetEp.episodeNumber}…';
      // Kept up until the new video is playing (see
      // _resetControlsTimer).
      _controlsVisible = true;
    });

    player.pause();

    // Persist the outgoing episode's final position before tearing it down
    // — without this, pressing "Next Episode" (or picking another episode)
    // could lose up to the last 5s of progress on the one just finished,
    // since the periodic save in the position listener is throttled and
    // nothing else force-saves before a switch (see _saveProgress's doc).
    await _saveProgress(force: true);

    // 1. The old episode's torrent stays until the new one is up, so a
    // failed switch can fall back to it (see _returnAfterFailedSwitch).
    final oldTorrentId = _torrentId;
    try {
      // 2. Fetch streams for the episode — sorted by the same size/quality-
      // aware logic as the quality selector sheet (not seed count).
      final imdbId = widget.details.imdbId ?? widget.details.id;
      // Already looked up when it was readied (_maybeReadyNextEpisode).
      final readied = _readiedNext;
      final prefetched = readied != null &&
              readied.season == seasonNumber &&
              readied.episode == targetEp.episodeNumber
          ? await readied.streams
          : const <TorrentStream>[];
      final streams = prefetched.isNotEmpty
          ? prefetched
          : await _resolver.getAvailableStreams(
              imdbId: imdbId,
              type: 'tv',
              season: seasonNumber,
              episode: targetEp.episodeNumber,
              title: widget.details,
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
        streams,
      );
      if (oldTorrentId != resolved.result.torrentId) {
        _resolver.cleanup(oldTorrentId);
      }
    } catch (e) {
      _showFailedEpisodeSwitch(targetEp, seasonNumber, e);
    }
  }

  /// A switch to [targetEp] failed before it took over: stay on the
  /// episode that was playing (left paused) and say so.
  void _showFailedEpisodeSwitch(Episode targetEp, int seasonNumber, Object e) {
    _returnAfterFailedSwitch(resumePlayback: false);
    if (!mounted) return;
    setState(() {
      _switchingQuality = false;
      _controlsVisible = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red[900],
        content: Text('Couldn\'t play S$seasonNumber E${targetEp.episodeNumber}'
            ' — you\'re still on the episode you were watching. ($e)'),
      ),
    );
  }

  /// Play a specific episode in the quality the user already chose (from
  /// [EpisodeBrowser]'s source picker; [stream] is that quality's best
  /// torrent, out of the episode's [allStreams]) — skips fetching/sorting
  /// the stream list since a choice has already been made, but still
  /// resolves it (falling back within the same quality) and shows the same
  /// loading overlay as [_playEpisode].
  Future<void> _playEpisodeWithChosenStream(
    Episode targetEp,
    int seasonNumber,
    TorrentStream stream,
    List<TorrentStream> allStreams,
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
          'Loading S$seasonNumber · E${targetEp.episodeNumber}…';
      // Kept up until the new video is playing (see
      // _resetControlsTimer).
      _controlsVisible = true;
    });

    player.pause();

    // See the matching comments in _playEpisode — same reasoning.
    await _saveProgress(force: true);

    final oldTorrentId = _torrentId;
    try {
      final resolved = await _resolver.resolveWithFallback(
        stream,
        StreamResolver.sameQuality(stream, allStreams),
      );
      await _applyResolvedEpisode(
        targetEp,
        seasonNumber,
        resolved.stream,
        resolved.result,
        allStreams,
      );
      if (oldTorrentId != resolved.result.torrentId) {
        _resolver.cleanup(oldTorrentId);
      }
    } catch (e) {
      _showFailedEpisodeSwitch(targetEp, seasonNumber, e);
    }
  }

  /// Shared tail of [_playEpisode]/[_playEpisodeWithChosenStream]: once a
  /// stream is resolved, save history/last-played, open the media, and
  /// update all the player's episode/torrent state — including [streams],
  /// the new episode's torrents, for the Quality menu.
  Future<void> _applyResolvedEpisode(
    Episode targetEp,
    int seasonNumber,
    TorrentStream stream,
    StreamResult result,
    List<TorrentStream> streams,
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

    // Switch to the new episode's clock *before* opening it: its duration
    // can arrive while it opens, and zeroing it afterwards (as this used
    // to) wiped it — and with no duration, _saveProgress never saved the
    // new episode's progress at all.
    if (mounted) {
      setState(() {
        // Picked from another season in the browser: that season's
        // episodes are now the playing ones.
        if (seasonNumber == _browsingSeason) _episodes = _browsingEpisodes;
        _currentEpisode = targetEp.episodeNumber;
        _currentSeason = seasonNumber;
        // The old episode's subtitles don't fit the new one, and opening
        // it re-applies whatever's selected — _loadSubtitles picks anew.
        _selectedSubtitle = null;
        _availableSubtitles = [];
        _currentPosition = Duration.zero;
        _duration = Duration.zero;
      });
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = Duration.zero;
      _bufferNotifier.value = Duration.zero;
    }

    await _openMediaWithResume(
      result.streamUrl,
      overrideSeason: seasonNumber,
      overrideEpisode: targetEp.episodeNumber,
    );

    if (mounted) {
      setState(() {
        _currentStream = stream;
        _availableStreams = streams;
        // A new episode gets its own stall recovery attempts.
        _autoRecoverAttempts = 0;
        _triedStartHashes.clear();
        _stallMessageShown = false;
        _torrentId = result.torrentId;
        _streamId = result.streamId;
        _streamUrl = result.streamUrl;
        _switchingQuality = false;
        _resetControlsTimer();
      });
      _subscribeToTorrent(_torrentId);
      _loadSubtitles();
      _updateMediaSessionMetadata();
    }
  }

  /// The episode after the playing one this season, if any.
  Episode? get _nextEpisode {
    if (_currentEpisode == null || _episodes.isEmpty) return null;
    final currentIndex =
        _episodes.indexWhere((e) => e.episodeNumber == _currentEpisode);
    if (currentIndex == -1 || currentIndex >= _episodes.length - 1) {
      return null;
    }
    return _episodes[currentIndex + 1];
  }

  /// Netflix Auto Play Next Episode Feature
  Future<void> _playNextEpisode() async {
    final nextEp = _nextEpisode;
    if (nextEp == null) return;
    _playEpisode(nextEp, _currentSeason ?? 1);
  }

  // The next episode, readied near the end of this one (see
  // _maybeReadyNextEpisode): which one, its torrents (_playEpisode uses
  // them rather than looking them up again), and its head start's.
  ({int season, int episode, Future<List<TorrentStream>> streams})?
      _readiedNext;
  List<TorrentStream> _nextHeadStart = const [];
  // The episode ("season:episode") the next one was readied from, so it's
  // done once per episode.
  String? _readiedFrom;

  /// Near the end of an episode — its last 3 minutes, or past 85% — gets
  /// the next one ready: finds its torrents and gives the likely pick a
  /// head start (StreamResolver.warmUp: on Wi-Fi, downloading its start),
  /// so Next Episode starts it at once.
  void _maybeReadyNextEpisode(Duration pos) {
    if (widget.details.type != 'tv' || _duration <= Duration.zero) return;
    final from = '$_currentSeason:$_currentEpisode';
    if (_readiedFrom == from) return;
    final left = _duration - pos;
    if (left > const Duration(minutes: 3) &&
        pos < _duration * 0.85) {
      return;
    }
    _readiedFrom = from;
    final next = _nextEpisode;
    if (next == null || next.isUnreleased) return;
    final season = _currentSeason ?? 1;
    final imdbId = widget.details.imdbId ?? widget.details.id;
    final streams = _resolver.getAvailableStreams(
      imdbId: imdbId,
      type: 'tv',
      season: season,
      episode: next.episodeNumber,
      title: widget.details,
    );
    _readiedNext =
        (season: season, episode: next.episodeNumber, streams: streams);
    () async {
      final list = await streams;
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || list.isEmpty) return;
      final candidates = StreamResolver.headStartCandidates(
        list,
        lastPlayedHash: prefs.getString(
            'last_played_torrent_${imdbId}_${season}_${next.episodeNumber}'),
      );
      _nextHeadStart = [..._nextHeadStart, ...candidates];
      _resolver.warmUp(
        candidates,
        resumeAt: SavedMoviesService()
            .getEpisodeProgress(widget.movie.id, season, next.episodeNumber),
      );
    }();
  }

  /// Browse and fetch details of a different season
  Future<void> _switchSeason(int seasonNumber) async {
    setState(() {
      _switchingQuality = true;
      _switchingMessage = 'Loading season $seasonNumber…';
    });

    try {
      final eps = await TMDBService().getSeasonDetails(
        widget.details.id,
        seasonNumber,
      );

      if (mounted) {
        setState(() {
          _browsingSeason = seasonNumber;
          _browsingEpisodes = eps;
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
    _screenTapTimer?.cancel();
    _bufferingRevealTimer?.cancel();
    _seekRevealTimer?.cancel();
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
    _stallWatchdogTimer?.cancel();
    _resumeBadgeTimer?.cancel();
    _mediaActionSub?.cancel();
    _mediaSession.deactivate();
    _episodeDrawerController.dispose();
    _playPauseFlash.dispose();

    // 4. Dispose players and pause (not delete) the active FFI torrent —
    // stops it downloading the rest of a file nobody's watching, but keeps
    // what was downloaded so resuming this content later only fetches the
    // remainder.
    player.dispose();
    _resolver.pause(_torrentId);
    // A readied next episode not played: what it got ahead goes (one
    // that was played is now a download of its own, and stays).
    _resolver.coolDown(_nextHeadStart);

    // 5. Dispose seek bar / stats notifiers
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _bufferNotifier.dispose();
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
      case 'sin':
      case 'si':
        return 'Sinhala';
      case 'tam':
      case 'ta':
        return 'Tamil';
      case 'tel':
      case 'te':
        return 'Telugu';
      case 'mal':
      case 'ml':
        return 'Malayalam';
      case 'kan':
      case 'kn':
        return 'Kannada';
      case 'ben':
      case 'bn':
        return 'Bengali';
      case 'urd':
      case 'ur':
        return 'Urdu';
      case 'may':
      case 'msa':
      case 'ms':
        return 'Malay';
      case 'tha':
      case 'th':
        return 'Thai';
      case 'kor':
      case 'ko':
        return 'Korean';
      case 'per':
      case 'fas':
      case 'fa':
        return 'Persian';
      case 'heb':
      case 'he':
        return 'Hebrew';
      case 'ell':
      case 'gre':
      case 'el':
        return 'Greek';
      case 'pob':
        return 'Portuguese (Brazil)';
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

      // Turn on the viewer's subtitle language — English unless they've
      // picked another one, or turned subtitles off (see _selectSubtitle)
      // — if this video has it. Otherwise off: never some other language
      // just because it's first in the list, and never the previous
      // episode's track left showing over this one.
      final prefs = await SharedPreferences.getInstance();
      final preferred = prefs.getString(_subtitleLangPrefKey) ?? 'eng';
      final match = preferred.isEmpty
          ? null
          : subs
              .where((s) =>
                  s.url.isNotEmpty &&
                  _getLanguageName(s.lang) == _getLanguageName(preferred))
              .firstOrNull;
      if (mounted) _selectSubtitle(match, remember: false);
    } catch (e) {
      print('Error loading subtitles: $e');
      if (mounted) {
        setState(() => _isLoadingSubtitles = false);
      }
    }
  }

  /// Shows [track] (null = subtitles off). A choice the viewer made
  /// ([remember]) becomes their preference for every video after this
  /// one — see _loadSubtitles.
  Future<void> _selectSubtitle(
    SubtitleTrackData? track, {
    bool remember = true,
  }) async {
    setState(() {
      _selectedSubtitle = track;
    });
    if (remember) {
      SharedPreferences.getInstance().then(
          (prefs) => prefs.setString(_subtitleLangPrefKey, track?.lang ?? ''));
    }

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
                        icon: const Icon(Icons.close_rounded,
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

  /// The playing episode's details, when it's in [_episodes] (TV only).
  Episode? get _playingEpisode => _currentEpisode == null
      ? null
      : _episodes
          .where((e) => e.episodeNumber == _currentEpisode)
          .firstOrNull;

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Camera cutout (punch hole / notch) — the video draws under it (see
    // MainActivity), but the controls stay clear of it.
    final safe = MediaQuery.of(context).padding;
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
              onTapAt: _onScreenTap,
              // No seeking until the video has loaded (see _loadingVideo).
              onDoubleTapSeek: _loadingVideo
                  ? null
                  : (isForward) {
                      // The double tap's first tap already scheduled a
                      // pause.
                      _screenTapTimer?.cancel();
                      if (isForward) {
                        _skipForward();
                      } else {
                        _skipBackward();
                      }
                    },
              onSwipeUp: widget.movie.type == 'tv' ? _openEpisodeBrowser : null,
              onHoldStart: _startSpeedBoost,
              onHoldEnd: _endSpeedBoost,
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
                          fit: _videoFit.boxFit,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                    ),
                  ),

                  // Play/pause flash: pops in, then fades as it grows
                  IgnorePointer(
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _playPauseFlash,
                        builder: (context, child) {
                          final t = _playPauseFlash.value;
                          final fade =
                              t < 0.3 ? 1.0 : 1 - (t - 0.3) / 0.7;
                          return Opacity(
                            opacity: fade.clamp(0.0, 1.0),
                            child: Transform.scale(
                              scale: 0.85 +
                                  0.3 * Curves.easeOut.transform(t),
                              child: child,
                            ),
                          );
                        },
                        child: Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_flashIcon,
                              color: Colors.white, size: 48),
                        ),
                      ),
                    ),
                  ),

                  // Switching (quality, episode, season, recovery): the
                  // video stays visible, softly darkened, under a small
                  // spinner and one quiet line.
                  if (_switchingQuality)
                    ColoredBox(
                      color: Colors.black.withValues(alpha: 0.6),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              _switchingMessage ?? 'Loading…',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
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
                            left: 16 + safe.left,
                            right: 16 + safe.right,
                            child: Listener(
                              onPointerDown: _markControlsPointer,
                              child: Row(
                                children: [
                                  // The details screen's back button with
                                  // the title's logo in a bubble grown out
                                  // of it (GlassBubbleBar) — out while
                                  // playing, back in when paused, where the
                                  // left panel shows the big logo instead.
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: TweenAnimationBuilder<double>(
                                        tween: Tween<double>(
                                            end: _isPlaying ? 1.0 : 0.0),
                                        duration:
                                            const Duration(milliseconds: 300),
                                        builder: (context, reveal, _) =>
                                            GlassBubbleBar(
                                          reveal: reveal,
                                          leading: const CircleAvatar(
                                            backgroundColor: Colors.transparent,
                                            child:
                                                BackButton(color: Colors.white),
                                          ),
                                          title: MovieTitleLogo(
                                              movie: widget.details),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Download speed — a quiet line of meta
                                  // text, in its own ValueListenableBuilder
                                  // so the ~1/sec libtorrent update only
                                  // rebuilds this, not the whole screen.
                                  Padding(
                                    padding: const EdgeInsets.only(right: 12),
                                    child: ValueListenableBuilder<double>(
                                      valueListenable: _downloadSpeedNotifier,
                                      builder: (context, speed, _) => Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                              Icons.arrow_downward_rounded,
                                              color: Colors.white38,
                                              size: 12),
                                          const SizedBox(width: 3),
                                          Text(
                                            '${speed.toStringAsFixed(1)} MB/s',
                                            style: const TextStyle(
                                                color: Colors.white54,
                                                fontWeight: FontWeight.w500,
                                                fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ─── LEFT METADATA PANEL ───
                          Positioned(
                            left: 32 + safe.left,
                            bottom: 100,
                            width: size.width * 0.38,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 350),
                              opacity:
                                  (!_isPlaying && _controlsVisible) ? 1.0 : 0.0,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
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
                                  // TV episode info, in the episode cards'
                                  // style: a small "S1 · E3" label over the
                                  // episode's name.
                                  if (widget.details.type == 'tv' &&
                                      _currentEpisode != null) ...[
                                    const SizedBox(height: 10),
                                    Text(
                                      'S$_currentSeason · E$_currentEpisode',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                        height: 1.2,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                    if (_playingEpisode?.name
                                        case final name?
                                        when name.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          height: 1.25,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ],
                                  const SizedBox(height: 10),
                                  // Description
                                  Text(
                                    (_playingEpisode?.overview ?? '')
                                            .isNotEmpty
                                        ? _playingEpisode!.overview
                                        : widget.movie.description,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 13,
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ─── BOTTOM BAR ───
                          Positioned(
                            bottom: 16 + MediaQuery.of(context).padding.bottom,
                            left: 24 + safe.left,
                            right: 24 + safe.right,
                            child: Listener(
                              onPointerDown: _markControlsPointer,
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
                                        // The cards' progress bar: a thin
                                        // cream line, with a small white dot
                                        // to drag.
                                        data: SliderThemeData(
                                          trackHeight: 3,
                                          activeTrackColor: AppTheme.primaryColor,
                                          secondaryActiveTrackColor:
                                              Colors.white.withValues(alpha: 0.3),
                                          inactiveTrackColor:
                                              Colors.white.withValues(alpha: 0.15),
                                          thumbColor: Colors.white,
                                          thumbShape: const RoundSliderThumbShape(
                                              enabledThumbRadius: 6,
                                              elevation: 0,
                                              pressedElevation: 0),
                                          overlayShape:
                                              const RoundSliderOverlayShape(
                                                  overlayRadius: 14),
                                          overlayColor:
                                              Colors.white.withValues(alpha: 0.12),
                                        ),
                                        // No seeking until the video has
                                        // loaded (see _loadingVideo).
                                        child: IgnorePointer(
                                          ignoring: _loadingVideo,
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
                                            _seekTo(
                                                Duration(seconds: val.toInt()));
                                            _syncMediaSessionPlaybackState();
                                          },
                                        ),
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
                                        // Play / pause, ringed by the loading
                                        // spinner while opening, buffering or
                                        // seeking
                                        SizedBox(
                                          width: 40,
                                          height: 40,
                                          child: Stack(
                                            alignment: Alignment.center,
                                            children: [
                                              if (!_switchingQuality &&
                                                  (_isMediaOpening ||
                                                      _isBuffering ||
                                                      _seekPending))
                                                const Positioned.fill(
                                                  child:
                                                      CircularProgressIndicator(
                                                    color: Colors.white70,
                                                    strokeWidth: 2,
                                                  ),
                                                ),
                                              IconButton(
                                                onPressed: _playPause,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                icon: Icon(
                                                  _isPlaying
                                                      ? Icons.pause_rounded
                                                      : Icons
                                                          .play_arrow_rounded,
                                                  color: Colors.white,
                                                  size: 24,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 4),
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
                                                style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight.w500),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const Spacer(),
                                        // Settings — quality, subtitles and
                                        // video size
                                        GlassPillButton(
                                          icon: Icons.tune_rounded,
                                          label: 'Settings',
                                          onPressed: () {
                                            _controlsTimer?.cancel();
                                            setState(() {
                                              _showSettingsPanel = true;
                                              _settingsPanelInitialView = 'main';
                                            });
                                          },
                                        ),
                                        if (widget.details.type == 'tv') ...[
                                          const SizedBox(width: 10),
                                          GlassPillButton(
                                            icon: Icons.grid_view_rounded,
                                            label: 'Episodes',
                                            onPressed: _openEpisodeBrowser,
                                          ),
                                          const SizedBox(width: 10),
                                          GlassPillButton(
                                            icon: Icons.skip_next_rounded,
                                            label: 'Next',
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
                          ),
                        ],
                      ),
                    ),
                  ),

                  // "Resumed from 12:34" for a moment after picking up
                  // where the viewer left off (see _showResumeBadge).
                  _glassBadge(
                    top: 16 + safe.top,
                    visible: _resumeBadge != null && !_speedBoost,
                    children: [
                      const Icon(Icons.replay_rounded,
                          color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(_resumeBadge ?? '', style: _badgeTextStyle),
                    ],
                  ),

                  // "2× ⏩" while a press-and-hold speeds playback up
                  // (see _startSpeedBoost) — shown whether or not the
                  // controls are.
                  _glassBadge(
                    top: 16 + safe.top,
                    visible: _speedBoost,
                    children: const [
                      Text('2×', style: _badgeTextStyle),
                      SizedBox(width: 6),
                      Icon(Icons.fast_forward_rounded,
                          color: Colors.white, size: 16),
                    ],
                  ),
                ],
              ),
            ),

            // Layer 2: Episode Browser (outside overlay) — stays mounted
            // through the slide-down animation (see _episodeDrawerMounted's
            // doc), rather than disappearing the instant a close is
            // requested.
            if (_episodeDrawerMounted && widget.movie.type == 'tv')
              Positioned.fill(
                child: SlideTransition(
                  position: _episodeDrawerOffset,
                  child: EpisodeBrowser(
                    episodes: _browsingEpisodes,
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
                    onTorrentChosen: (ep, season, stream, allStreams) {
                      _pausedForEpisodeBrowser = false;
                      setState(() => _showEpisodeDrawer = false);
                      _animateEpisodeDrawerClosed();
                      _playEpisodeWithChosenStream(
                          ep, season, stream, allStreams);
                    },
                    onWebPlayerChosen: (ep, season, provider) {
                      _pausedForEpisodeBrowser = false;
                      setState(() => _showEpisodeDrawer = false);
                      _animateEpisodeDrawerClosed();
                      _openWebPlayerForEpisode(ep, season, provider);
                    },
                  ),
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
                  availableStreams: _availableStreams,
                  currentStream: _currentStream,
                  onStreamSelected: (stream) {
                    _switchQuality(stream);
                  },
                  videoFit: _videoFit,
                  onVideoFitSelected: _selectVideoFit,
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

