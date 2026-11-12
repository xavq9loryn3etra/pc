import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../widgets/app_message.dart';
import '../widgets/player_route.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart' hide WebPlayer;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/audio_language_service.dart';
import '../services/torrent/last_played_torrents.dart';
import '../services/background_download_service.dart';
import '../services/saved_movies_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/torrent_engine_service.dart';
import '../services/torrent/free_space.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/torrent/torrent_download_registry.dart';
import '../services/torrent/torrent_storage_service.dart';
import '../services/torrent/trim_point.dart';
import '../services/tmdb_service.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../widgets/player_gesture_overlay.dart';
import '../widgets/episode_browser.dart';
import '../widgets/floating_bottom_nav_bar.dart'
    show isComputer, kSideColumnGap, kSideColumnWidth, playerIsWide;
import '../widgets/player_settings_panel.dart';
import '../widgets/glass_blur.dart';
import '../widgets/glass_bubble_bar.dart';
import 'web_player/web_player.dart';
import '../services/scraper_service.dart';
import '../services/skip_segments_service.dart';
import '../services/subtitle_service.dart';
import '../services/subtitle_retime.dart';
import '../services/subtitle_sync.dart';
import '../services/window_full_screen.dart';

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
  // The same, as a side panel on a computer's wide window: in from the
  // right instead (see _episodeBrowserLayer).
  late final Animation<Offset> _episodePanelOffset;
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
  double? _settingsPanelAnchorX;
  final GlobalKey _qualityButtonKey = GlobalKey();
  final GlobalKey _subtitlesButtonKey = GlobalKey();
  final GlobalKey _videoSizeButtonKey = GlobalKey();
  final GlobalKey _audioButtonKey = GlobalKey();
  final GlobalKey _settingsButtonKey = GlobalKey();

  // Download speed — libtorrent emits an update roughly once a second,
  // which isn't a "many times/sec" hot path like position ticks, but it's
  // still a stream-driven, continuous-during-playback update, so it gets
  // the same ValueNotifier treatment to avoid a whole-screen rebuild every
  // second for one small line of text.
  final ValueNotifier<double> _downloadSpeedNotifier = ValueNotifier(0.0);
  StreamSubscription? _torrentSub;
  DateTime? _lastProgressPersist;

  // UI Control State
  bool _controlsShown = true;

  /// Whether the controls are up. While they're hidden the seek bar's
  /// position and buffer aren't pushed on every tick (nothing's showing
  /// them); on coming back up they're brought up to date at once.
  bool get _controlsVisible => _controlsShown;
  set _controlsVisible(bool visible) {
    if (visible && !_controlsShown) {
      _positionNotifier.value = _currentPosition;
      _bufferNotifier.value = player.state.buffer;
    }
    _controlsShown = visible;
  }

  Timer? _controlsTimer;
  Timer? _screenTapTimer;
  DateTime? _controlsPointerAt;
  bool _isBuffering = false;
  Timer? _bufferingRevealTimer;
  Timer? _seekRevealTimer;

  // Centre-screen play/pause flash shown on user play/pause. Starts at its
  // end (invisible).
  late final AnimationController _playPauseFlash;

  // ─── Up next, at an episode's end (see _updateUpNext) ───
  /// Next Episode's fill: 0 to 1 over [_upNextCountdown], then it plays.
  late final AnimationController _upNextFill;
  static const _upNextCountdown = Duration(seconds: 10);

  /// Whether Watch Credits and Next Episode are up.
  final ValueNotifier<bool> _upNextShown = ValueNotifier(false);

  /// The episode ("season:episode") whose credits the viewer chose to
  /// watch: no countdown for it again.
  String? _upNextDismissedFor;
  IconData _flashIcon = Icons.pause_rounded;

  // Video scaling (Fit / Fill), set from the settings panel and
  // remembered across sessions.
  static const _videoFitPrefKey = 'player_video_fit';
  static const _volumePrefKey = 'player_volume';
  // The viewer's subtitle language ('' = off); English until they choose.
  static const _subtitleLangPrefKey = 'player_subtitle_lang';
  VideoFit _videoFit = VideoFit.fill;
  final ValueNotifier<double> _volumeNotifier = ValueNotifier(100.0);
  double _volumeBeforeMute = 100.0;
  bool _volumeHover = false;
  bool _volumeDragging = false;
  bool _volumeRecentlyAdjusted = false;
  Timer? _volumeCollapseTimer;
  bool _switchingQuality = false;
  // Loading another season's episode list in the browser: not a video
  // switch, so it doesn't block playing, pausing or switching.
  bool _loadingSeason = false;
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
  final ValueNotifier<double?> _seekHoverFractionNotifier =
      ValueNotifier<double?>(null);
  // Skippable segments (Intro, Recap, Credits, Preview) from embedded MKV
  // chapters and fallback APIs (TheIntroDB / IntroDB).
  String _lastRawChapterList = '';
  List<VideoChapter> _mkvChapters = const [];
  List<SkipSegment> _mkvSkipSegments = const [];
  List<SkipSegment> _apiSkipSegments = const [];
  List<SkipSegment> _skipSegments = const [];
  final ValueNotifier<int> _timelinePartitionRevision = ValueNotifier<int>(0);
  final ValueNotifier<SkipSegment?> _activeSkipSegmentNotifier =
      ValueNotifier<SkipSegment?>(null);
  bool _isPlaying = false;
  bool _isDragging = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _bufferingSub;
  StreamSubscription? _tracksSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _completedSub;
  // A player error being checked on (see _onPlayerError).
  Timer? _errorCheck;
  List<SubtitleTrackData> _embeddedSubtitles = [];
  List<SubtitleTrackData> _externalSubtitles = [];
  List<SubtitleTrackData> _availableSubtitles = [];
  SubtitleTrackData? _selectedSubtitle;
  bool _userPickedSubtitleForThisVideo = false;
  double _subtitleDelaySeconds = 0.0;
  double _subtitleSpeed = 1.0;

  // Auto Sync (see _maybeAutoSync): at work; the subtitles' cues already
  // downloaded, by their url; the subtitles done with (synced, given up
  // on, or timed by the viewer) and those tried, by id; where watching
  // carried on from without a jump, and the position last seen.
  bool _autoSyncing = false;
  final Map<String, List<SubtitleCue>> _subtitleCues = {};
  final Set<String> _autoSyncDone = {};
  // Subtitles synced at least once: checked again now and then (see
  // _autoSyncRecheck).
  final Set<String> _autoSynced = {};
  // The sound Auto Sync last heard of this video, kept so another subtitle
  // picked meanwhile is lined up at once (see _maybeAutoSync), and the
  // subtitles already tried against it.
  ({String url, double start, Int16List pcm})? _heard;
  final Set<String> _heardTried = {};
  // What each listen found, for each subtitle (see _autoSync: two
  // stretches agreeing is enough), and where the next listen starts.
  final Map<String,
          List<({double delay, double speed, double start, double end})>>
      _autoSyncSeen = {};
  final Map<String, Duration> _autoSyncFrom = {};

  // Retiming against reference subtitles (see _retimeFromReferences): each
  // subtitle's corrected file; those tried, and those timed so (Auto Sync's
  // listening leaves them be); subtitles' downloaded text, by url.
  final Map<String, String> _retimedPaths = {};
  final Set<String> _retimeTried = {};
  final Set<String> _referenceTimed = {};
  final Map<String, String> _subtitleTexts = {};
  final Map<String, ({int tries, Duration next})> _autoSyncTries = {};
  Duration? _watchedFrom;
  Duration _autoSyncLastPos = Duration.zero;

  // Each subtitle's own timing, by its id, for going back to it: one
  // file's offset (Auto Sync's or the viewer's) doesn't fit another.
  final Map<String, ({double delay, double speed})> _subtitleTimings = {};
  bool _isLoadingSubtitles = false;
  bool _initialPositionRestored = false;
  double? _pendingResumeSnackbarProgress;
  // "Resumed from …", shown for a moment at the top (see _showResumeBadge).
  String? _resumeBadge;

  // "Subtitles synced", for a moment, when syncing moved the subtitles
  // being watched (see _showSyncedBadge).
  bool _syncedBadge = false;
  Timer? _syncedBadgeTimer;
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

  // Lets the screen sleep once paused for a minute (see _playingSub).
  Timer? _wakelockTimer;
  Duration _lastWatchdogPosition = Duration.zero;
  int? _lastWatchdogDownloadedBytes;
  int _stallTicks = 0;
  static const int _stallTicksThreshold = 4; // 4 * 5s = 20s of no progress
  // While the video is still opening: a slow swarm can need longer to find
  // peers, and wiping it would throw away the ones it has already found.
  static const int _openingStallTicksThreshold = 9; // 45s
  // While opening, a copy that has still delivered less than
  // [_openingMinBytes] after [_openingDataWait] is given up for another of
  // its quality — even if it trickles in now and then, which keeps the
  // rule above from ever firing. (The Mentalist's "328 sharers" pick had
  // no one for 27s, then 20 KB/s: two minutes before it was left.) A
  // healthy one has several MB by then.
  static const Duration _openingDataWait = Duration(seconds: 20);
  static const int _openingMinBytes = 2 * 1024 * 1024;
  // The torrent being opened, how much it had when that was first seen,
  // and when — the baseline for the rule above.
  ({int torrentId, int bytes, DateTime at})? _openingBaseline;
  bool _recoveringStream = false;

  /// True while playback is paused because the device ran low on storage
  /// (see TorrentEngineService.lowDiskSpace), so it only resumes what it
  /// paused itself.
  bool _pausedForLowDisk = false;
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

  // Landscape: the phone really turns for the player, so the system's own
  // bars and pull-down panel turn with it. Only once the player has faded
  // in over the page, and back to portrait before it closes (see _close),
  // so the page behind is never seen sideways.
  static final _canTurn = Platform.isAndroid || Platform.isIOS;
  bool _turnStarted = false;
  // Followed with the accelerometer, so the picture turns to whichever
  // side the phone is held even with the system's rotation lock on — with
  // it, the system keeps whichever landscape side the player opened in.
  StreamSubscription<AccelerometerEvent>? _tilt;
  DeviceOrientation? _landscapeSide;
  // Set once the player has passed the screen's orientation on — turned it
  // back to portrait itself (_close), or to the web player — so dispose
  // leaves it be.
  bool _orientationHandedOn = false;
  // Turning back to portrait before closing: the player shows black.
  bool _closing = false;
  // The progress has had its last save (closing, or off to the web
  // player): nothing after may change it — stopping reports position 0.
  bool _progressFinal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the screen on for the whole time the player is open — without
    // this, the OS can lock the screen mid-playback (video keeps decoding
    // behind a black/locked screen) since Flutter doesn't request a wakelock
    // on its own. (Released a minute after a pause, kept up again on play:
    // see _playingSub.)
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

    // Landscape follows in didChangeDependencies, once it has faded in.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // On Windows, the window goes full screen instead (F11, Esc or a
    // double-click to change it; back as it was on close).
    WindowFullScreen.enter();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);

    // Episode drawer slide up/down — starts "dismissed" (off the bottom of
    // the screen) since the drawer isn't open yet.
    _episodeDrawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    final drawerCurve = CurvedAnimation(
      parent: _episodeDrawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _episodeDrawerOffset = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(drawerCurve);
    _episodePanelOffset = Tween<Offset>(
      // Its own width and its margin further: fully off the right edge.
      begin: const Offset(1.1, 0),
      end: Offset.zero,
    ).animate(drawerCurve);
    _upNextFill = AnimationController(vsync: this, duration: _upNextCountdown)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _playNextFromUpNext();
      });
    _playPauseFlash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      value: 1,
    );

    // Initialize media_kit Player
    player = Player();
    controller = VideoController(player);

    _initPlayer();
    _subscribeToTorrent(_torrentId);
    _resetControlsTimer();
    _initMediaSession();
    _loadVideoFit();
    _loadVolume();
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

  /// Whether the settings popup is open from [view]'s button — shown
  /// selected (GlassPillButton.selected) while it is.
  bool _menuOpen(String view) =>
      _showSettingsPanel && _settingsPanelInitialView == view;

  /// Closes the settings popup, animated (PlayerSettingsPanel.
  /// closeRequests): bumped by its button pressed again, or Esc.
  final ValueNotifier<int> _settingsCloseRequests = ValueNotifier(0);

  /// A menu button: closes its menu when that's the one open, otherwise
  /// opens it — in place of another that's open, in one click. (The
  /// buttons are in the popup's TapRegion group, so pressing one doesn't
  /// count as a click outside it that would close it first.)
  void _toggleSettingsPanel(String view, GlobalKey buttonKey) {
    if (_menuOpen(view)) {
      _settingsCloseRequests.value++;
    } else {
      _openSettingsPanelAt(view, buttonKey);
    }
  }

  /// [button] as one of the popup's own (see _toggleSettingsPanel).
  Widget _menuButton(Widget button) =>
      TapRegion(groupId: PlayerSettingsPanel.tapGroup, child: button);

  void _openSettingsPanelAt(String view, GlobalKey buttonKey) {
    _controlsTimer?.cancel();
    double? anchorX;
    final ctx = buttonKey.currentContext;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final topLeft = box.localToGlobal(Offset.zero);
        anchorX = topLeft.dx + box.size.width / 2;
      }
    }
    setState(() {
      _showSettingsPanel = true;
      _settingsPanelInitialView = view;
      _settingsPanelAnchorX = anchorX;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_turnStarted || !_canTurn) return;
    _turnStarted = true;
    // Turns once the player covers the page: turning while it fades in
    // showed the page behind turn too.
    final opening = ModalRoute.of(context)?.animation;
    if (opening == null || opening.status == AnimationStatus.completed) {
      _turnLandscape();
      return;
    }
    void opened(AnimationStatus status) {
      if (status == AnimationStatus.forward) return;
      opening.removeStatusListener(opened);
      if (status == AnimationStatus.completed && mounted && !_closing) {
        _turnLandscape();
      }
    }

    opening.addStatusListener(opened);
  }

  void _turnLandscape() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _tilt = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 300),
    ).listen((event) {
      // Gravity along the phone's width: positive with its left edge down
      // (top tilted left), negative with its right edge down. In between —
      // held upright, or lying flat — stays on the current side.
      final side = event.x > 4.0
          ? DeviceOrientation.landscapeLeft
          : event.x < -4.0
              ? DeviceOrientation.landscapeRight
              : null;
      if (side == null || side == _landscapeSide || _closing) return;
      _landscapeSide = side;
      SystemChrome.setPreferredOrientations([side]);
    }, onError: (_) {}); // No sensor: the system picks the side.
  }

  /// Closes the player: first turning the phone back to portrait over
  /// black, so the page it goes back to is never seen sideways.
  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    _orientationHandedOn = true;
    _tilt?.cancel();
    // Where they'd got to, saved before stopping: stop() reports the
    // position as 0, which would otherwise be saved as the progress (the
    // position listener ignores it too, now _closing is set).
    _saveProgress(force: true);
    _progressFinal = true;
    // Whatever goes wrong below, the player still closes: the screen is
    // already black (_closing), so skipping the pop would leave it that way.
    try {
      if (isComputer) {
        // The desktop app stops the video outright, so it's gone before the
        // window leaves full screen.
        await player.stop();
      } else {
        // A phone just pauses, without waiting, so turning back upright
        // starts at once; dispose() stops it once the player's closed.
        player.pause();
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await WindowFullScreen.exit();
      if (_canTurn && mounted) {
        await SystemChrome.setPreferredOrientations(
            [DeviceOrientation.portraitUp]);
        if (!mounted) return;
        // Until the screen is portrait, and drawn so; or a moment, where it
        // won't turn (a tablet that ignores the app's portrait lock).
        final view = View.of(context);
        final giveUp = DateTime.now().add(const Duration(milliseconds: 1200));
        while (mounted &&
            view.physicalSize.width > view.physicalSize.height &&
            DateTime.now().isBefore(giveUp)) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (_) {
      // Fall through to the pop.
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  /// The player is closing to open the web player, which turns the screen
  /// itself.
  void _handOrientationToWebPlayer() {
    _orientationHandedOn = true;
    _tilt?.cancel();
  }

  /// Sets the player up and opens the video. If any of that fails, the
  /// spinner stops and the viewer's told, rather than it spinning forever.
  Future<void> _initPlayer() async {
    try {
      await _setUpPlayer();
    } catch (e) {
      // Closed meanwhile: the player's gone, nothing to say.
      if (!mounted) return;
      debugPrint('Player setup failed: $e');
      setState(() => _isMediaOpening = false);
      showAppMessage(
        context,
        "Couldn't start playback. Try another quality.",
        error: true,
      );
    }
  }

  Future<void> _setUpPlayer() async {
    _loadSubtitles();
    _loadApiSkipSegments();
    // Configure MPV for torrent streaming — P2P data arrives in bursts,
    // so we tune the cache to fill a sensible buffer before starting playback
    // and to re-pause when the buffer drains rather than stalling mid-stream.
    // Each step stops if the player's been closed meanwhile.
    final mpv = player.platform as NativePlayer;
    // A phone's memory is tighter: a smaller demuxer cache there.
    final phone = Platform.isAndroid || Platform.isIOS;
    await mpv.observeProperty('chapter-list', _onMpvChapterList);
    for (final p in {
      'cache': 'yes',
      'cache-secs': '60', // Keep up to 60s of video cached ahead
      'demuxer-readahead-secs': '10', // Fetch 10s ahead (not 30) to start sooner
      // Demuxer cache ahead, and back-buffer for seeking.
      'demuxer-max-bytes': phone ? '64M' : '150M',
      'demuxer-max-back-bytes': phone ? '16M' : '50M',
      'cache-pause-initial': 'yes', // Pause at startup until initial cache fills
      'cache-pause-wait': '5', // Re-pause if buffer drops below 5s
      // Seeks land on the nearest keyframe rather than the exact second: an
      // exact seek first downloads and decodes everything from the keyframe
      // before it — up to ~10s of video in x265 releases, and slow to decode
      // — which kept a seek spinning long after its data had arrived.
      'hr-seek': 'no',
      // The torrent server can go quiet for well over media_kit's 5 s while
      // a piece arrives; at 5 s the read was dropped and mpv took it for the
      // end of the file — playback just stopped. Wait longer, and reconnect
      // (at the same spot) if the connection does drop.
      'network-timeout': '60',
      'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
    }.entries) {
      if (!mounted) return;
      await mpv.setProperty(p.key, p.value);
    }
    await _configureCinemaSound(mpv);
    // Multi-language releases often make a dub their default audio track;
    // pick the one in the title's audio language when there is one —
    // English, or the original for a title not made in English if that's
    // what's chosen (AudioLanguageService; StreamResolver.languageRank
    // already prefers copies in it).
    if (!mounted) return;
    await AudioLanguageService().ensureLoaded();
    if (!mounted) return;
    await mpv.setProperty('alang',
        AudioLanguageService().trackOrderFor(widget.details).join(','));
    if (!mounted) return;
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
        if (_isMediaOpening) {
          print('[timing] opening: ${val ? 'playing' : 'paused'} at '
              '${_openingStopwatch.elapsedMilliseconds} ms');
        }
        // Sync play/pause to notification
        _syncMediaSessionPlaybackState();
        // Screen kept on while playing; a paused player (left that way)
        // lets it sleep after a minute — not while a switch has it held
        // paused on purpose.
        _wakelockTimer?.cancel();
        if (val) {
          WakelockPlus.enable();
        } else {
          _wakelockTimer = Timer(const Duration(minutes: 1), () {
            if (mounted && !_isPlaying && !_loadingVideo) {
              WakelockPlus.disable();
            }
          });
        }
        // Up next's countdown runs only while the video plays.
        if (_upNextShown.value) {
          val ? _upNextFill.forward() : _upNextFill.stop();
        }
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
      // Where a slow start's time goes (with the position lines in
      // _checkOpeningFinished).
      if (_isMediaOpening) {
        print('[timing] opening: ' + (isBuffering ? 'waiting for data' : 'has enough data') +
            ' at ${_openingStopwatch.elapsedMilliseconds} ms');
      }
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

    void applyDuration(Duration dur) {
      if (!mounted || dur <= Duration.zero) return;
      _duration = dur;
      _durationNotifier.value = dur;
      _updateMediaSessionMetadata();
      _rememberEpisodeLength(dur);
      _reparseMkvChaptersForDuration(dur);
      _updateActiveSkipSegment(_currentPosition);

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

    // Subscribe to position, duration, and buffer *before* opening the media
    // so fast opens (e.g. cached/prebuffered streams) never miss the single
    // duration event emitted during player.open().
    _durationSub = player.stream.duration.listen(applyDuration);

    // Listen to video position
    _positionSub = player.stream.position.listen((pos) {
      // Closing stops the player, which reports 0 — not where they were.
      if (_closing || _progressFinal) return;
      if (mounted && !_isDragging) {
        if (_duration <= Duration.zero &&
            player.state.duration > Duration.zero) {
          applyDuration(player.state.duration);
        }
        final inInitialSeekWindow = _seekPending &&
            _seekStartedAt != null &&
            DateTime.now().difference(_seekStartedAt!) <
                const Duration(milliseconds: 300);
        if (!inInitialSeekWindow) {
          // Not wrapped in setState — only the seek bar (via _positionNotifier)
          // needs to react to this, not the whole screen, since this fires
          // several times a second during playback.
          _currentPosition = pos;
          // The seek bar and the clock show whole seconds, and hidden
          // controls show nothing (they catch up when shown again: see
          // _controlsVisible) — so no rebuild for anything finer.
          if (_controlsVisible &&
              pos.inSeconds != _positionNotifier.value.inSeconds) {
            _positionNotifier.value = pos;
          }
        }
        if (_isMediaOpening) _checkOpeningFinished(pos);
        if (_seekPending) _checkSeekFinished(pos);
        _updateActiveSkipSegment(pos);
        _maybeReadyNextEpisode(pos);
        _updateUpNext(pos);
        _maybeAutoSync(pos);
        // Save progress periodically (throttled) ONLY after initial position is restored
        if (_initialPositionRestored) {
          _saveProgress();
        }
      }
    });

    // Listen to video buffer duration (for YouTube-style grayed-out buffered bar).
    // Not wrapped in setState — only the seek bar's secondary track needs this.
    _bufferSub = player.stream.buffer.listen((buf) {
      if (mounted && _controlsVisible) {
        _bufferNotifier.value = buf;
      }
    });

    // Listen to internal video/audio/subtitle tracks reported by mpv so
    // embedded MKV/MP4 subtitles (which are already perfectly timed to the
    // video stream) are discovered and preferred over generic external SRTs.
    _tracksSub = player.stream.tracks.listen(_onMpvTracksChanged);

    // A failed open or a lost stream: mpv says so only here — the stall
    // watchdog acts only while playing, so the spinner would stay forever.
    _errorSub = player.stream.error.listen(_onPlayerError);
    // The end of the file: the next episode, or the controls.
    _completedSub = player.stream.completed.listen(_onPlaybackCompleted);
    TorrentEngineService.instance.lowDiskSpace.addListener(_onLowDiskSpace);

    await _openMediaWithResume(_streamUrl);
    // Closed while it opened: no watchdog left running for good, holding
    // on to this screen (dispose has been and gone).
    if (!mounted) return;
    if (_duration <= Duration.zero && player.state.duration > Duration.zero) {
      applyDuration(player.state.duration);
    }

    // See the _stallWatchdogTimer field doc for why this exists.
    _stallWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkForStall();
    });
  }

  /// The engine paused the download because storage is nearly full (or
  /// resumed it after space was freed). Playback pauses too, rather than
  /// sitting on a spinner, and resumes only if this paused it.
  void _onLowDiskSpace() {
    if (!mounted) return;
    if (TorrentEngineService.instance.lowDiskSpace.value) {
      if (_isPlaying) {
        _pausedForLowDisk = true;
        player.pause();
      }
      showAppMessage(
        context,
        'Your device is nearly out of storage, so the download is paused. '
        'Free up some space to carry on.',
        error: true,
        duration: const Duration(seconds: 6),
      );
    } else if (_pausedForLowDisk) {
      _pausedForLowDisk = false;
      player.play();
    }
  }

  /// An error from mpv (see _errorSub). Some are passing decoder complaints
  /// that playback carries on through, so it's taken for a dead stream only
  /// if, a few seconds on, the video is still opening or stuck in place.
  void _onPlayerError(String error) {
    if (!mounted || _closing) return;
    print('[player] error: $error');
    if (_switchingQuality || _recoveringStream || _errorCheck != null) return;
    final at = _currentPosition;
    _errorCheck = Timer(const Duration(seconds: 5), () {
      _errorCheck = null;
      if (!mounted || _closing || _switchingQuality || _recoveringStream) {
        return;
      }
      final stuck = _isMediaOpening || (_isPlaying && _currentPosition == at);
      if (!stuck) return;
      if (_autoRecoverAttempts >= _maxAutoRecoverAttempts) {
        // Nothing left to try: no endless spinner — recovery's message
        // says to try another quality.
        setState(() => _isMediaOpening = false);
      }
      _attemptStreamRecovery(reason: 'mpv error: $error');
    });
  }

  /// The file played to its end (see _completedSub): the next episode,
  /// unless Up Next is already offering it; otherwise the controls.
  void _onPlaybackCompleted(bool done) {
    if (!done ||
        !mounted ||
        _closing ||
        _switchingQuality ||
        _recoveringStream) {
      return;
    }
    // Well before the end: mpv takes a dropped stream for the end of the
    // file. That's a stall, not the end.
    final nearEnd = _duration > Duration.zero &&
        _currentPosition >= _duration - const Duration(seconds: 60);
    if (!nearEnd) {
      _attemptStreamRecovery(reason: 'Ended early at $_currentPosition');
      return;
    }
    _saveProgress(force: true);
    final next = _nextEpisode;
    if (widget.details.type == 'tv' &&
        next != null &&
        !next.isUnreleased &&
        !_upNextShown.value) {
      _playNextEpisode();
    } else {
      _controlsTimer?.cancel();
      setState(() => _controlsVisible = true);
    }
  }

  /// Ends the opening state once playback is genuinely under way: playing,
  /// not buffering, and the position moving forward in small steps. A
  /// single "playing"/"not buffering" event isn't enough (both fire before
  /// the stream connects), and the first position change is often the jump
  /// to the resume point rather than playback.
  void _checkOpeningFinished(Duration pos) {
    final last = _openingLastPosition;
    _openingLastPosition = pos;
    if (last == null) {
      print('[timing] opening: first position $pos at '
          '${_openingStopwatch.elapsedMilliseconds} ms'
          '${_isBuffering ? ', waiting for data' : ''}'
          '${_isPlaying ? '' : ', paused'}');
    }
    if (last == null || !_isPlaying || _isBuffering) return;
    final step = pos - last;
    if (step.abs() >= const Duration(seconds: 2)) {
      print('[timing] opening: jumped to $pos at '
          '${_openingStopwatch.elapsedMilliseconds} ms');
    }
    if (step > Duration.zero && step < const Duration(seconds: 2)) {
      setState(() => _isMediaOpening = false);
      print('[timing] video playing ${_openingStopwatch.elapsedMilliseconds} '
          'ms after the player opened it');
      _fingerprintSubtitles();
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
    _pendingSkipSeek = null; // A newer seek replaces a waiting skip.
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

    // Still opening, on a copy that's barely delivering: on to another of
    // its quality, if there's one not tried yet (see _openingDataWait).
    if (!_isMediaOpening) {
      _openingBaseline = null;
    } else if (downloadedBytes != null) {
      final baseline = _openingBaseline;
      if (baseline == null || baseline.torrentId != _torrentId) {
        _openingBaseline = (
          torrentId: _torrentId,
          bytes: downloadedBytes,
          at: DateTime.now(),
        );
      } else if (DateTime.now().difference(baseline.at) >= _openingDataWait &&
          downloadedBytes - baseline.bytes < _openingMinBytes &&
          StreamResolver.sameQuality(_currentStream, _availableStreams).any(
              (s) => !_triedStartHashes.contains(s.infoHash.toLowerCase()) &&
                  s.infoHash.toLowerCase() !=
                      _currentStream.infoHash.toLowerCase())) {
        _openingBaseline = null;
        _stallTicks = 0;
        _attemptStreamRecovery(
          reason: 'Under 2 MB after ${_openingDataWait.inSeconds}s of opening',
        );
        return;
      }
    }

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
      showAppMessage(
        context,
        'Playback keeps stalling — this copy may not be available. '
        'Try a different one from the quality menu.',
        error: true,
        duration: const Duration(seconds: 6),
      );
      return;
    }

    print('Stream recovery triggered: $reason');
    _autoRecoverAttempts++;
    _recoveringStream = true;
    final resumeAt = _resumePointForSwitch();
    final staleInfoHash = _currentStream.infoHash;
    final stuckTorrentId = _torrentId;
    // Fully downloaded: the stall can't be missing data (download bytes are
    // always flat once it's done), so wiping would only throw away a good
    // copy — it's just reopened at the current position.
    final stuckTorrent = LibtorrentFlutter.instance.torrents[stuckTorrentId];
    final alreadyComplete = stuckTorrent != null &&
        stuckTorrent.totalWanted > 0 &&
        stuckTorrent.totalDone >= stuckTorrent.totalWanted;

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
        _forgetFileSubtitles();
      });
    }

    player.pause();

    StreamResult? started;
    try {
      final StreamResolveResult resolved;
      if (otherCopies.isNotEmpty) {
        // Starting one pauses the stuck copy (see
        // TorrentEngineService.startStream), so a failure can go back to
        // it.
        resolved = await _resolver.resolveWithFallback(
          otherCopies.first,
          otherCopies,
          isCancelled: () => !mounted,
        );
        started = resolved.result;
        if (_closedDuringSwitch(started)) return;
        await _rememberPlayedTorrent(resolved.stream);
      } else {
        // Wipe the stuck torrent's cached data (also removes the live
        // handle if it's still registered) so the retry doesn't just reuse
        // whatever was stuck on disk — unless it's all there already.
        if (!alreadyComplete) {
          await TorrentStorageService.deleteByInfoHash(staleInfoHash);
        }
        if (!mounted) return;
        resolved = await _resolver.resolveWithFallback(
          _currentStream,
          _availableStreams,
          isCancelled: () => !mounted,
        );
        started = resolved.result;
        if (_closedDuringSwitch(started)) return;
        // Re-downloaded copy: register it so it isn't deleted as an
        // unregistered torrent when the details page closes.
        await _rememberPlayedTorrent(resolved.stream);
      }
      if (_closedDuringSwitch(started)) return;
      final resolvedStream = resolved.stream;
      final result = resolved.result;

      await _openMediaWithResume(result.streamUrl, precisePosition: resumeAt);
      if (_closedDuringSwitch(result)) return;
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
        // Another copy: downloaded subtitles matched to its name and size.
        if (otherCopies.isNotEmpty) _loadSubtitles();
      }
    } on ResolveCancelledException {
      // The player closed meanwhile: nothing more to do.
      return;
    } catch (e) {
      if (_closedDuringSwitch(started)) return;
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
          debugPrint('Failed to recover playback: $e');
          showAppMessage(
            context,
            e is NotEnoughSpaceException
                ? e.toString()
                : "Couldn't get playback going again. Try another quality.",
            error: true,
          );
        }
      }
    } finally {
      _recoveringStream = false;
    }
  }

  /// Where another copy of this video should start: the spot being watched,
  /// or null — the saved progress (see _openMediaWithResume) — while it's
  /// still opening or near the start, when the position is still 0 and not
  /// where the viewer had got to.
  Duration? _resumePointForSwitch() =>
      (_isMediaOpening || _currentPosition < const Duration(seconds: 5))
          ? null
          : _currentPosition;

  /// Remembers [stream] as the torrent this title/episode plays from — for
  /// resuming with it later, and for Settings > Storage.
  Future<void> _rememberPlayedTorrent(TorrentStream stream) async {
    final prefs = await SharedPreferences.getInstance();
    final String imdbId = widget.details.imdbId ?? widget.details.id;
    final String key = _currentSeason != null && _currentEpisode != null
        ? 'last_played_torrent_${imdbId}_${_currentSeason}_${_currentEpisode}'
        : 'last_played_torrent_$imdbId';
    await prefs.setString(key, stream.infoHash);
    await LastPlayedTorrents.rememberLanguage(prefs, key, widget.details);
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
      // Where they'd got to, in case the app's closed while away — not
      // mid-switch, when the position may be another video's.
      if (!_switchingQuality) _saveProgress(force: true);
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
      // After each step: if the player closed meanwhile, its dispose has
      // already deactivated the session — so undo this one's activation.
      await _mediaSession.requestNotificationPermission();
      if (!mounted) return;
      await _mediaSession.activate();
      if (!mounted) {
        await _mediaSession.deactivate();
        return;
      }

      // Only show play/pause (no skip buttons)
      await _mediaSession.updateAvailableActions({
        MediaAction.play,
        MediaAction.pause,
        MediaAction.seekTo,
      });
      if (!mounted) {
        await _mediaSession.deactivate();
        return;
      }

      // Set initial metadata
      await _updateMediaSessionMetadata();
      if (!mounted) {
        await _mediaSession.deactivate();
        return;
      }

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
      speed: _speedBoost ? 2.0 : 1.0,
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
    // A soundtrack picked in the last file (see _setAudioLanguage) would
    // otherwise carry over by its number — the wrong one in another file.
    // Each file picks its own, by language ('alang') — the one saved now,
    // which a quality picked in another language may just have changed.
    await mpv.setProperty('aid', 'auto');
    await mpv.setProperty('alang',
        AudioLanguageService().trackOrderFor(widget.details).join(','));

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
            SavedMoviesService().getMovieFromHistory(widget.movie.id, type: widget.movie.type);
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
    await _applySubtitleTimingToMpv();
    if (_selectedSubtitle != null) {
      await _applySubtitleTrackToPlayer(_selectedSubtitle);
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
      // Throttled, unless forced: each save writes out the whole watch
      // history and rebuilds every poster on the pages under the player.
      // Every 15 seconds, not 5 — leaving the app forces one (see
      // didChangeAppLifecycleState), so little's lost if it's closed.
      if (!force &&
          _lastSaveTime != null &&
          now.difference(_lastSaveTime!) < const Duration(seconds: 15)) {
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

  /// Keyboard shortcuts for playback and window controls:
  /// - Space / K: play or pause
  /// - Left / J: seek backward 10s
  /// - Right / L: seek forward 10s
  /// - F11 / F: toggle full screen
  /// - Esc: close open overlay or exit full screen
  ///
  /// They work with the settings popup open too (it floats over the
  /// video, which keeps playing); not in the episode browser, which covers
  /// the video, paused.
  /// Whether the episode browser covers the video (the whole screen): not
  /// as a computer's side panel, beside which the video's still in view —
  /// its keys then still work.
  bool get _episodeCoversVideo =>
      _showEpisodeDrawer && !playerIsWide(context);

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    final key = event.logicalKey;

    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
        if (WindowFullScreen.supported) {
          WindowFullScreen.toggle();
          return true;
        }
      }
      if (key == LogicalKeyboardKey.escape) {
        if (_showSettingsPanel) {
          // Closed as its button closes it: animated, its onClose then
          // restarting the controls timer.
          _settingsCloseRequests.value++;
          return true;
        }
        if (_showEpisodeDrawer) {
          _closeEpisodeBrowser();
          return true;
        }
        if (WindowFullScreen.supported && WindowFullScreen.isOn) {
          WindowFullScreen.exit();
          return true;
        }
      }
      if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
        if (!_loadingVideo && !_episodeCoversVideo) {
          _playPause();
          return true;
        }
      }
    }

    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      if (!_loadingVideo && !_episodeCoversVideo) {
        _skipBackward(flash: true);
        return true;
      }
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyL) {
      if (!_loadingVideo && !_episodeCoversVideo) {
        _skipForward(flash: true);
        return true;
      }
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!_episodeCoversVideo) {
        _setVolume(_volumeNotifier.value + 5, showSlider: true, flash: true);
        return true;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (!_episodeCoversVideo) {
        _setVolume(_volumeNotifier.value - 5, showSlider: true, flash: true);
        return true;
      }
    }
    if (event is KeyDownEvent && key == LogicalKeyboardKey.keyM) {
      if (!_episodeCoversVideo) {
        _toggleMute(flash: true);
        return true;
      }
    }

    return false;
  }

  // On a computer, clicking anywhere on the video plays/pauses, and
  // moving the cursor reveals the controls. On a phone or tablet (however
  // wide — a big phone on its side is over 800 wide), a single tap in the
  // middle third plays/pauses while either side shows/hides the controls.
  // Either way it waits out the gesture overlay's 320ms double-tap window
  // first, so a double-tap seek or double-click fullscreen can cancel it.
  //
  // The overlay listens to raw pointers over the whole screen, controls
  // included, so taps on the top/bottom bars (back button, seek bar,
  // buttons) are marked and skipped here — they do their own thing.
  /// The bottom bar (seek bar, buttons, times), for [_inBottomBand].
  final GlobalKey _bottomBarKey = GlobalKey();

  /// Whether the last click landed in [_inBottomBand] (so a double-click
  /// there doesn't toggle full screen either).
  bool _lastTapInBottomBand = false;

  /// On a computer: whether [position] is at or below the seek bar's top,
  /// anywhere across the window — the controls' strip, whose empty space
  /// (between and around the buttons, and under them to the window's
  /// edge) a click on does nothing, rather than play or pause. Clicking
  /// there to bring the window to the front shouldn't pause the video.
  bool _inBottomBand(Offset position) {
    if (!isComputer) return false;
    final box = _bottomBarKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    // A little above, for the seek bar's thumb and hover grow.
    final top = box.localToGlobal(Offset.zero).dy - 8;
    return position.dy >= top;
  }

  void _onScreenTap(Offset position) {
    final onControls = _controlsPointerAt != null &&
        DateTime.now().difference(_controlsPointerAt!) <
            const Duration(seconds: 1);
    _controlsPointerAt = null;
    _lastTapInBottomBand = _inBottomBand(position);
    if (onControls || _lastTapInBottomBand) return;
    // The episode panel open beside the video: a click on the video
    // closes it (on press — see _dismissEpisodePanel) and carries on
    // watching — playing it if it was paused, never pausing it.
    final dismissed = _episodePanelDismissedAt;
    if (_showEpisodeDrawer ||
        (dismissed != null &&
            DateTime.now().difference(dismissed) <
                const Duration(milliseconds: 800))) {
      _episodePanelDismissedAt = null;
      _screenTapTimer?.cancel();
      _dismissEpisodePanel();
      // Play, not toggle: closing the panel may have just set it playing
      // (see _closeEpisodeBrowser), before _isPlaying caught up.
      if (!_isPlaying && !_loadingVideo) {
        player.play();
        setState(() => _flashIcon = Icons.play_arrow_rounded);
        _playPauseFlash.forward(from: 0);
      }
      return;
    }

    final width = MediaQuery.of(context).size.width;
    final inMiddle =
        position.dx > width / 3 && position.dx < width * 2 / 3;
    _screenTapTimer?.cancel();
    _screenTapTimer = Timer(
      const Duration(milliseconds: 320),
      (isComputer || inMiddle) ? _playPause : _toggleControls,
    );
  }

  void _onMouseHover(PointerHoverEvent event) {
    if (event.delta.dx.abs() < 0.5 && event.delta.dy.abs() < 0.5) return;
    if (_episodeCoversVideo || _showSettingsPanel) return;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _resetControlsTimer();
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

  /// Whether the press that's just ended landed on a control (see
  /// _markControlsPointer): a double tap on a button mustn't also seek.
  bool get _pointerWasOnControls =>
      _controlsPointerAt != null &&
      DateTime.now().difference(_controlsPointerAt!) <
          const Duration(seconds: 1);

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

  /// "Subtitles synced", for a moment — when syncing has just moved the
  /// subtitles on screen by [moved] seconds, enough to see, while they're
  /// being watched: says why they jumped. Not for a change no one would
  /// notice, nor while the video's still starting.
  void _showSyncedBadge(double moved) {
    if (moved.abs() < 0.3 ||
        _isMediaOpening ||
        _currentPosition < const Duration(seconds: 5) ||
        !mounted) {
      return;
    }
    setState(() => _syncedBadge = true);
    _syncedBadgeTimer?.cancel();
    _syncedBadgeTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _syncedBadge = false);
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
    _syncMediaSessionPlaybackState(); // Its position now moves at 2x.
  }

  void _endSpeedBoost() {
    if (!_speedBoost) return;
    player.setRate(1.0);
    setState(() => _speedBoost = false);
    _syncMediaSessionPlaybackState();
  }

  void _playPause() {
    // Mid-switch the player is held paused: playing would start the old
    // video again under the loading overlay.
    if (_switchingQuality) return;
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

  IconData _volumeIconFor(double volume) {
    if (volume <= 0) return Icons.volume_off_rounded;
    if (volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  Future<void> _loadVolume() async {
    // Only the desktop app has a volume control of its own; a phone's
    // player stays at full, its volume set by the phone's own buttons.
    if (!isComputer) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_volumePrefKey);
    if (saved == null || !mounted) return;
    final clamped = saved.clamp(0.0, 100.0);
    _volumeNotifier.value = clamped;
    if (clamped > 0) _volumeBeforeMute = clamped;
    player.setVolume(clamped);
  }

  void _keepVolumeSliderOpenTemporarily() {
    _volumeCollapseTimer?.cancel();
    if (!_volumeRecentlyAdjusted) {
      setState(() => _volumeRecentlyAdjusted = true);
    }
    _volumeCollapseTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _volumeRecentlyAdjusted = false);
    });
  }

  void _setVolume(
    double volume, {
    bool showSlider = false,
    bool flash = false,
    bool persist = true,
  }) {
    final clamped = volume.clamp(0.0, 100.0);
    _volumeNotifier.value = clamped;
    if (clamped > 0) _volumeBeforeMute = clamped;
    player.setVolume(clamped);
    if (persist) {
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setDouble(_volumePrefKey, clamped));
    }
    if (showSlider) {
      setState(() => _controlsVisible = true);
      _keepVolumeSliderOpenTemporarily();
    }
    if (flash) {
      setState(() => _flashIcon = _volumeIconFor(clamped));
      _playPauseFlash.forward(from: 0);
    }
    _resetControlsTimer();
  }

  void _toggleMute({bool flash = false}) {
    final current = _volumeNotifier.value;
    final next = current > 0
        ? 0.0
        : (_volumeBeforeMute > 0 ? _volumeBeforeMute : 100.0);
    _setVolume(next, showSlider: true, flash: flash);
  }

  void _skipBackward({bool flash = false}) =>
      _skipBy(const Duration(seconds: -10), flash: flash);

  void _skipForward({bool flash = false}) =>
      _skipBy(const Duration(seconds: 10), flash: flash);

  // Rapid skips (a double-tap seek streak taps every ~300ms) build on the
  // previous skip's target: the reported position can lag behind a seek,
  // especially on a torrent stream, so basing each on _currentPosition
  // would make some taps land on the same spot.
  Duration? _lastSkipTarget;
  DateTime? _lastSkipAt;

  // A held arrow key repeats ~30 times a second: the target keeps building
  // (above), but the real seek goes out at most every 150 ms — the first at
  // once, the last of a burst when the gap ends — so mpv isn't flooded with
  // seeks on a torrent stream.
  Timer? _skipSeekTimer;
  Duration? _pendingSkipSeek;
  static const _skipSeekGap = Duration(milliseconds: 150);

  void _seekThrottled(Duration target) {
    if (_skipSeekTimer?.isActive ?? false) {
      _pendingSkipSeek = target;
      return;
    }
    _seekTo(target);
    _skipSeekTimer = Timer(_skipSeekGap, _flushSkipSeek);
  }

  void _flushSkipSeek() {
    final target = _pendingSkipSeek;
    if (target == null || !mounted) return;
    _seekTo(target);
    _skipSeekTimer = Timer(_skipSeekGap, _flushSkipSeek);
  }

  void _skipBy(Duration delta, {bool flash = false}) {
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
    _currentPosition = target;
    _positionNotifier.value = target;
    if (flash) {
      setState(() {
        _controlsVisible = true;
        _flashIcon = delta.isNegative
            ? Icons.replay_10_rounded
            : Icons.forward_10_rounded;
      });
      _playPauseFlash.forward(from: 0);
    }
    _seekThrottled(target);
    _syncMediaSessionPlaybackState();
    _resetControlsTimer();
  }

  /// Perform premium mid-playback quality switching keeping exact timestamp
  /// Moves playback to [newStream], at the same spot. [fallbacks] are the
  /// copies to try if it won't start (by default, the rest of its
  /// quality), [message] what's shown meanwhile, and [failedMessage] what
  /// if none of them starts.
  Future<void> _switchQuality(
    TorrentStream newStream, {
    List<TorrentStream>? fallbacks,
    String? message,
    String? failedMessage,
  }) async {
    // One switch at a time (a second tap would race the first).
    if (_switchingQuality) return;
    if (newStream.infoHash.toLowerCase() ==
        _currentStream.infoHash.toLowerCase()) return;

    final savedPos = _resumePointForSwitch();
    final wasPlaying = _isPlaying;
    final oldTorrentId = _torrentId;
    player.pause();

    setState(() {
      _switchingQuality = true;
      _switchingMessage = message ??
          'Switching to ${QualityOption(StreamResolver.tierOf(newStream), [newStream]).name}…';
      // Kept up until the new video is playing (see
      // _resetControlsTimer).
      _controlsVisible = true;
      _initialPositionRestored =
          false; // Prevent position listener from saving 0.0 during loading
      _forgetFileSubtitles();
    });

    StreamResult? started;
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
        fallbacks ?? StreamResolver.sameQuality(newStream, _availableStreams),
        isCancelled: () => !mounted,
      );
      final resolvedStream = resolved.stream;
      final result = started = resolved.result;
      if (_closedDuringSwitch(result)) return;

      // 3. Save last played torrent infohash — the one that actually
      // resolved, not necessarily the one originally tapped.
      await _rememberPlayedTorrent(resolvedStream);
      if (_closedDuringSwitch(result)) return;

      // 4. Open new media at exactly saved position natively
      await _openMediaWithResume(result.streamUrl, precisePosition: savedPos);
      if (_closedDuringSwitch(result)) return;
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
        // Downloaded subtitles matched to this file's name and size.
        _loadSubtitles();
      }
    } on ResolveCancelledException {
      // The player closed meanwhile: nothing more to do.
      return;
    } catch (e) {
      if (_closedDuringSwitch(started)) return;
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
        debugPrint('Quality switch failed: $e');
        showAppMessage(
          context,
          e is NotEnoughSpaceException
              ? e.toString()
              : failedMessage ??
                  "Couldn't switch quality, so it's staying on "
                      '${_currentStream.quality ?? "the current one"}.',
          error: true,
        );
      }
    }
  }

  /// After a quality or episode switch failed: carry on with what was
  /// playing. Its torrent was only paused by the attempt (see
  /// TorrentEngineService.startStream) and its media is still loaded.
  void _returnAfterFailedSwitch({required bool resumePlayback}) {
    // Closed meanwhile: dispose() paused that torrent, and the player's gone.
    if (!mounted) return;
    _resolver.resume(_torrentId);
    if (resumePlayback) player.play();
  }

  /// Whether the player was closed while a switch awaited something. If so
  /// the torrent the switch [started] is paused — dispose() only paused the
  /// one playing then — and the switch should stop there.
  bool _closedDuringSwitch(StreamResult? started) {
    if (mounted) return false;
    if (started != null) _resolver.pause(started.torrentId);
    return true;
  }

  /// Cinema sound. A film's surround soundtrack (5.1/7.1) goes to the
  /// device as it is, so the phone's own surround — Dolby Atmos, Android's
  /// spatial audio with head tracking on supported earbuds — can place it
  /// around the viewer, rather than mpv first folding it to plain stereo,
  /// which is all Android's default lets through. Where it still has to be
  /// folded to stereo (stereo-only outputs; Windows' own layout is used
  /// there already), the bass channel is mixed in at half level instead of
  /// being dropped, which is most of a film's weight. Each option is tried
  /// on its own: a libmpv without one just keeps its default.
  Future<void> _configureCinemaSound(NativePlayer mpv) async {
    final options = {
      if (Platform.isAndroid) 'audio-channels': 'auto',
      'audio-swresample-o': 'lfe_mix_level=0.5',
    };
    for (final o in options.entries) {
      if (!mounted) return;
      try {
        await mpv.setProperty(o.key, o.value);
      } catch (e) {
        print('Cinema sound: ${o.key} not applied: $e');
      }
    }
  }

  /// Whether a change of audio language is being carried out (finding a
  /// copy with it): the choice can't be changed again meanwhile.
  bool _changingAudio = false;

  /// The audio language picked in the player's settings, mid-play: saved
  /// for the whole series (the next episode is found and played in it),
  /// then heard at once — this copy's soundtrack in it if it has one,
  /// otherwise another copy that has, from the same spot.
  Future<void> _setAudioLanguage(AudioLanguage choice) async {
    if (_changingAudio) return;
    final languages = AudioLanguageService();
    if (languages.of(widget.details) == choice) return;
    await languages.set(widget.details, choice);
    await _applyAudioLanguage();
  }

  /// Makes what's playing follow the audio language just saved (by
  /// [_setAudioLanguage], or the episode panel's picker).
  Future<void> _applyAudioLanguage() async {
    if (_changingAudio || !mounted) return;
    final title = widget.details;
    final languages = AudioLanguageService();
    setState(() => _changingAudio = true);
    try {
      final mpv = player.platform as NativePlayer;
      await mpv.setProperty('alang', languages.trackOrderFor(title).join(','));
      // The next episode was readied in the old language: ready it again.
      _readiedNext = null;
      _readiedFrom = null;

      final language = languages.languageFor(title);
      final kind = title.type == 'tv' ? 'episode' : 'movie';

      // 1. This copy has it: just switch soundtracks.
      final track = _audioTrackIn(language);
      if (track != null) {
        await player.setAudioTrack(track);
        // Now "Last watched" in this language (see LastPlayedTorrents).
        await _rememberPlayedTorrent(_currentStream);
        if (mounted) showAppMessage(context, 'Playing in ${language.name}.');
        return;
      }

      // 2. Another copy marked as having it — the quality being watched,
      // if there's one in it.
      final imdbId = widget.details.imdbId ?? widget.details.id;
      List<TorrentStream> streams;
      try {
        streams = await _resolver.getAvailableStreams(
          imdbId: imdbId,
          type: title.type,
          season: title.type == 'tv' ? _currentSeason : null,
          episode: title.type == 'tv' ? _currentEpisode : null,
          title: title,
        );
      } catch (_) {
        streams = const [];
      }
      if (!mounted) return;
      if (streams.isNotEmpty) setState(() => _availableStreams = streams);
      // Not this copy: if it has it, its soundtracks don't say which is
      // which, and playing it again wouldn't change anything.
      final withIt = streams
          .where((s) =>
              StreamResolver.hasMarkedAudio(s, language.flags) &&
              s.infoHash.toLowerCase() != _currentStream.infoHash.toLowerCase())
          .toList();
      if (withIt.isEmpty) {
        showAppMessage(
          context,
          "This $kind has no copy with ${language.name} audio. "
          '${title.type == 'tv' ? 'The next episodes will play in it where they have it.' : "It'll play in it when one turns up."}',
        );
        return;
      }
      final tier = StreamResolver.tierOf(_currentStream);
      final sameTier =
          withIt.where((s) => StreamResolver.tierOf(s) == tier).toList();
      final pick = (sameTier.isNotEmpty ? sameTier : withIt).first;
      await _switchQuality(
        pick,
        fallbacks: StreamResolver.sameQuality(pick, withIt),
        message: 'Switching to ${language.name} audio…',
        failedMessage: "Couldn't start a copy with ${language.name} audio, "
            "so it's staying as it was.",
      );
    } finally {
      if (mounted) setState(() => _changingAudio = false);
    }
  }

  /// This file's soundtrack in [language], if it says which one that is.
  AudioTrack? _audioTrackIn(SpokenLanguage language) {
    for (final t in player.state.tracks.audio) {
      if (t.id == 'auto' || t.id == 'no') continue;
      final code = t.language?.toLowerCase().trim();
      if (code != null && language.trackCodes.contains(code)) return t;
    }
    return null;
  }

  /// Opens the web player for an episode chosen from [EpisodeBrowser]'s
  /// source picker, closing this one.
  Future<void> _openWebPlayerForEpisode(
    Episode targetEp,
    int seasonNumber,
    String provider,
  ) async {
    // Where they'd got to in the episode playing, saved for good before
    // stopping: stop() reports 0, which would otherwise end up saved (by
    // dispose) over it — after the new episode's put in the history.
    await _saveProgress(force: true);
    _progressFinal = true;
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

    _handOrientationToWebPlayer();
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
  /// The episode browser: the whole screen, sliding up — or, on a
  /// computer's wide window, a panel down the right side, the home's side
  /// column's width, sliding in from the right. There the paused screen
  /// stays as it was beside it — the title, the episode's info and the
  /// controls — the panel fitting between the top bar and the bottom one,
  /// whose buttons all still work. A click on the video closes it (see
  /// _onScreenTap), as Episodes pressed again does.
  List<Widget> _episodeBrowserLayer(BuildContext context) {
    final asPanel = playerIsWide(context);
    final Widget browser = EpisodeBrowser(
      asPanel: asPanel,
      episodes: _browsingEpisodes,
      seasons: widget.details.seasons,
      movie: widget.movie,
      details: widget.details,
      imdbId: widget.details.imdbId ?? widget.details.id,
      currentSeason: _browsingSeason ?? 1,
      playingSeason: _currentSeason ?? 1,
      playingEpisode: _currentEpisode ?? 1,
      resolver: _resolver,
      playingStream: _currentStream,
      // The copy playing picked in another language: its soundtrack
      // switched (or another copy's, if it hasn't that one).
      onAudioLanguageChanged: () {
        _closeEpisodeBrowser();
        _applyAudioLanguage();
      },
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
    );
    if (!asPanel) {
      return [
        Positioned.fill(
          key: const ValueKey('episode-browser-layer'),
          child: SlideTransition(position: _episodeDrawerOffset, child: browser),
        ),
      ];
    }
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    // Below the top bar's row, as the home's side column is.
    final top = safe.top + 80;
    final bottom = _bottomBarClearance(size);
    final panelSize = Size(
      kSideColumnWidth,
      math.max(0.0, size.height - top - bottom),
    );
    const radius = BorderRadius.all(Radius.circular(24));
    return [
      Positioned(
        key: const ValueKey('episode-browser-layer'),
        top: top,
        bottom: bottom,
        right: kSideColumnGap + safe.right,
        width: kSideColumnWidth,
        child: TapRegion(
          groupId: EpisodeBrowser.panelTapGroup,
          onTapOutside: (_) => _dismissEpisodePanel(),
          child: SlideTransition(
          position: _episodePanelOffset,
          // Painted once, then just moved as it slides — not the episodes
          // and their pictures drawn again every frame of it.
          child: RepaintBoundary(
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: kGlassEdge),
            ),
            child: ClipRRect(
              borderRadius: radius,
              // The settings popup's glass (PlayerSettingsPanel): the
              // video frosted under a dark tint. Resting while the panel
              // slides in or out (GlassBlur.paused) — re-blurring a whole
              // panel's worth of moving video every frame of the slide
              // stuttered — darker meanwhile to make up for it.
              child: AnimatedBuilder(
                animation: _episodeDrawerController,
                builder: (context, child) => GlassBlur(
                  sigma: 16,
                  paused: _episodeDrawerController.isAnimating,
                  reducedTint: Colors.black.withValues(alpha: 0.35),
                  child: child!,
                ),
                child: ColoredBox(
                  color: kGlassSheetTint,
                  // A phone-sized screen of its own, as the home's side
                  // column.
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: panelSize,
                      padding: EdgeInsets.zero,
                      viewPadding: EdgeInsets.zero,
                    ),
                    child: browser,
                  ),
                ),
              ),
            ),
          ),
          ),
          ),
        ),
      ),
    ];
  }

  /// How far up from the window's bottom the bottom bar reaches (and a
  /// gap): where the side panel stops, so the bar's buttons stay in view.
  double _bottomBarClearance(Size size) {
    final box = _bottomBarKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      final top = box.localToGlobal(Offset.zero).dy;
      return math.max(0.0, size.height - top) + kSideColumnGap;
    }
    return 140;
  }

  /// Episodes: opens the browser, or, as a side panel already open,
  /// closes it — the button lit up meanwhile, as the menus' are.
  void _toggleEpisodeBrowser() {
    if (_showEpisodeDrawer) {
      _closeEpisodeBrowser();
    } else {
      _openEpisodeBrowser();
    }
  }

  void _openEpisodeBrowser() {
    // Covering the video, it pauses it; beside it, as a side panel, the
    // video plays on (and its controls hide again in a moment, as ever).
    final asPanel = playerIsWide(context);
    if (_isPlaying && !asPanel) {
      _pausedForEpisodeBrowser = true;
      player.pause();
    }
    setState(() {
      // An open settings popup goes at once: it's drawn above the episode
      // browser, so its own fade-out (started by the click on Episodes,
      // outside it) left it over the browser as that slid in.
      _showSettingsPanel = false;
      _showEpisodeDrawer = true;
      _episodeDrawerMounted = true;
      // Covering the screen: nothing of the player's shows. As a side
      // panel: the paused screen stays beside it, controls and all.
      _controlsVisible = asPanel;
      // Always open on the season that's playing.
      _browsingSeason = _currentSeason;
      _browsingEpisodes = _episodes;
    });
    _episodeDrawerController.forward();
    if (asPanel) _resetControlsTimer();
  }

  // When a click outside the side panel last closed it (see
  // _dismissEpisodePanel): that click, let go of on the video, mustn't
  // also play or pause it (_onScreenTap).
  DateTime? _episodePanelDismissedAt;

  /// A click outside the side panel — on the video, a control, another
  /// button — closes it, as one outside a menu closes that; the click
  /// still does what it's on.
  void _dismissEpisodePanel() {
    if (!_showEpisodeDrawer) return;
    _episodePanelDismissedAt = DateTime.now();
    _closeEpisodeBrowser();
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
    // One switch at a time (a double tap on Next would start two).
    if (_switchingQuality) return;
    if (targetEp.isUnreleased) {
      showAppMessage(context, "This episode hasn't aired yet.");
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
    // Saved while the next one's being found, not before: it's done by
    // the time the new episode's added to the history (below).
    final saved = _saveProgress(force: true);
    final pressed = Stopwatch()..start();

    // 1. The old episode's torrent stays until the new one is up, so a
    // failed switch can fall back to it (see _returnAfterFailedSwitch).
    final oldTorrentId = _torrentId;
    StreamResult? started;
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
      if (!mounted) return;
      final streams = prefetched.isNotEmpty
          ? prefetched
          : await _resolver.getAvailableStreams(
              imdbId: imdbId,
              type: 'tv',
              season: seasonNumber,
              episode: targetEp.episodeNumber,
              title: widget.details,
            );
      if (!mounted) return;

      if (streams.isEmpty) {
        throw Exception('No streams found for this episode.');
      }

      // 3. Resolve the likely pick — the copy played of this episode
      // before, or else the quality being watched now (as the head start
      // readied: see _maybeReadyNextEpisode) — falling back to its other
      // copies of that quality, then the rest, if it fails or times out.
      final prefs = await SharedPreferences.getInstance();
      final lastPlayed = await LastPlayedTorrents.lastPlayed(
          prefs,
          'last_played_torrent_${imdbId}_${seasonNumber}_${targetEp.episodeNumber}',
          widget.details);
      if (!mounted) return;
      final pick = StreamResolver.likelyPick(
            streams,
            lastPlayedHash: lastPlayed,
            preferTier: StreamResolver.tierOf(_currentStream),
          ) ??
          streams.first;
      final sameTier = StreamResolver.sameQuality(pick, streams);
      final resolved = await _resolver.resolveWithFallback(
        pick,
        [
          ...sameTier,
          ...streams.where((s) => !sameTier.contains(s)),
        ],
        isCancelled: () => !mounted,
      );
      started = resolved.result;
      // Closed meanwhile: before the new episode goes in the history.
      if (_closedDuringSwitch(started)) return;
      print('[timing] S${seasonNumber}E${targetEp.episodeNumber}: '
          '${prefetched.isNotEmpty ? 'readied near the end of the last one' : 'not readied'}'
          ', a copy ready ${pressed.elapsedMilliseconds} ms after it was '
          'asked for');
      await saved;
      if (_closedDuringSwitch(started)) return;
      await _applyResolvedEpisode(
        targetEp,
        seasonNumber,
        resolved.stream,
        resolved.result,
        streams,
      );
      if (_closedDuringSwitch(started)) return;
      if (oldTorrentId != resolved.result.torrentId) {
        _resolver.cleanup(oldTorrentId);
      }
    } on ResolveCancelledException {
      // The player closed meanwhile: nothing more to do.
      return;
    } catch (e) {
      if (_closedDuringSwitch(started)) return;
      _showFailedEpisodeSwitch(targetEp, seasonNumber, e);
    }
  }

  /// A switch to [targetEp] failed before it took over: stay on the
  /// episode that was playing (left paused) and say so.
  void _showFailedEpisodeSwitch(Episode targetEp, int seasonNumber, Object e) {
    if (!mounted) return;
    _returnAfterFailedSwitch(resumePlayback: false);
    setState(() {
      _switchingQuality = false;
      _controlsVisible = true;
    });
    debugPrint('Episode switch failed: $e');
    showAppMessage(
      context,
      e is NotEnoughSpaceException
          ? e.toString()
          : "Couldn't play S$seasonNumber E${targetEp.episodeNumber}, so "
              "you're still on the episode you were watching.",
      error: true,
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
    if (_switchingQuality) return;
    if (targetEp.isUnreleased) {
      showAppMessage(context, "This episode hasn't aired yet.");
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
    if (!mounted) return;

    final oldTorrentId = _torrentId;
    StreamResult? started;
    try {
      final resolved = await _resolver.resolveWithFallback(
        stream,
        StreamResolver.sameQuality(stream, allStreams),
        isCancelled: () => !mounted,
      );
      started = resolved.result;
      if (_closedDuringSwitch(started)) return;
      await _applyResolvedEpisode(
        targetEp,
        seasonNumber,
        resolved.stream,
        resolved.result,
        allStreams,
      );
      if (_closedDuringSwitch(started)) return;
      if (oldTorrentId != resolved.result.torrentId) {
        _resolver.cleanup(oldTorrentId);
      }
    } on ResolveCancelledException {
      // The player closed meanwhile: nothing more to do.
      return;
    } catch (e) {
      if (_closedDuringSwitch(started)) return;
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

    // What the episode switch changes before the media opens; put back if
    // the open fails, so the old episode that stays on screen isn't saved
    // as the new one.
    final oldEpisodes = _episodes;
    final oldEpisode = _currentEpisode;
    final oldSeason = _currentSeason;
    final oldPosition = _currentPosition;
    final oldDuration = _duration;

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
        _embeddedSubtitles = [];
        _externalSubtitles = [];
        _availableSubtitles = [];
        _userPickedSubtitleForThisVideo = false;
        _subtitleDelaySeconds = 0.0;
        _subtitleSpeed = 1.0;
        _subtitleTimings.clear();
        _autoSyncDone.clear();
        _autoSynced.clear();
        _autoSyncTries.clear();
        _heard = null;
        _heardTried.clear();
        _autoSyncSeen.clear();
        _autoSyncFrom.clear();
        _discardRetimedFiles();
        _retimeTried.clear();
        _referenceTimed.clear();
        _currentPosition = Duration.zero;
        _duration = Duration.zero;
      });
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = Duration.zero;
      _bufferNotifier.value = Duration.zero;
      _lastRawChapterList = '';
      _mkvChapters = const [];
      _mkvSkipSegments = const [];
      _apiSkipSegments = const [];
      _skipSegments = const [];
      _updateTimelineShapes();
      _timelinePartitionRevision.value++;
      _activeSkipSegmentNotifier.value = null;
    }

    try {
      await _openMediaWithResume(
        result.streamUrl,
        overrideSeason: seasonNumber,
        overrideEpisode: targetEp.episodeNumber,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _episodes = oldEpisodes;
          _currentEpisode = oldEpisode;
          _currentSeason = oldSeason;
          _currentPosition = oldPosition;
          _duration = oldDuration;
        });
        _positionNotifier.value = oldPosition;
        _durationNotifier.value = oldDuration;
        _updateTimelineShapes();
        _timelinePartitionRevision.value++;
        _loadSubtitles();
      }
      rethrow;
    }
    if (_closedDuringSwitch(result)) return;

    // Playing now, so the episode counts as watched: history (Continue
    // Watching) and the copy it plays from, saved only after the open
    // succeeded.
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
      await LastPlayedTorrents.rememberLanguage(prefs, key, widget.details);
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
      _loadApiSkipSegments();
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

  /// Up next, at an episode's end: Watch Credits, and Next Episode filling
  /// from left to right over [_upNextCountdown] — the next episode plays
  /// when it's full, or at once when it's pressed. From where the end
  /// credits start (the skip data's credits running to the end, as Skip
  /// Credits plays the next episode for), or, with no credits data, the
  /// last 25 seconds. Only when the next episode is out. The fill waits
  /// while the video's paused; seeking back before then puts it away.
  void _updateUpNext(Duration pos) {
    final key = '$_currentSeason:$_currentEpisode';
    final next = _nextEpisode;
    final show = widget.details.type == 'tv' &&
        next != null &&
        !next.isUnreleased &&
        !_loadingVideo &&
        !_switchingQuality &&
        _duration > const Duration(minutes: 2) &&
        _upNextDismissedFor != key &&
        pos >= _upNextStart();
    if (show == _upNextShown.value) return;
    _upNextShown.value = show;
    _upNextFill
      ..stop()
      ..value = 0;
    if (show && _isPlaying) _upNextFill.forward();
  }

  /// Where up next begins: the end credits' start, or 25 s from the end.
  Duration _upNextStart() {
    for (final s in _skipSegments) {
      if (s.type != SkipSegmentType.credits) continue;
      final end = s.end;
      if (end == null || _duration - end <= const Duration(seconds: 15)) {
        return s.start;
      }
    }
    return _duration - const Duration(seconds: 25);
  }

  /// Next Episode pressed, or its fill full: the next episode, now.
  void _playNextFromUpNext() {
    if (!_upNextShown.value) return;
    _upNextShown.value = false;
    _upNextFill
      ..stop()
      ..value = 0;
    _playNextEpisode();
  }

  /// Watch Credits: up next goes, for this episode, and the credits play.
  void _watchCredits() {
    _upNextDismissedFor = '$_currentSeason:$_currentEpisode';
    _upNextShown.value = false;
    _upNextFill
      ..stop()
      ..value = 0;
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

  /// Near the end of an episode — its last 3 minutes, past 85%, or a
  /// minute before its credits (so Skip Credits, which plays the next one,
  /// finds it ready even when the credits are long) — gets the next one
  /// ready: finds its torrents and gives the likely pick, in the quality
  /// being watched, a head start (StreamResolver.warmUp: on Wi-Fi,
  /// downloading its start), so Next Episode starts it at once.
  void _maybeReadyNextEpisode(Duration pos) {
    if (widget.details.type != 'tv' || _duration <= Duration.zero) return;
    final from = '$_currentSeason:$_currentEpisode';
    if (_readiedFrom == from) return;
    final left = _duration - pos;
    final creditsSoon = _skipSegments.any((s) =>
        (s.type == SkipSegmentType.credits ||
            s.type == SkipSegmentType.preview) &&
        s.start - pos <= const Duration(minutes: 1));
    if (left > const Duration(minutes: 3) &&
        pos < _duration * 0.85 &&
        !creditsSoon) {
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
    // The quality being watched now, for the next episode too.
    final tier = StreamResolver.tierOf(_currentStream);
    () async {
      final list = await streams;
      final prefs = await SharedPreferences.getInstance();
      final lastPlayed = await LastPlayedTorrents.lastPlayed(
          prefs,
          'last_played_torrent_${imdbId}_${season}_${next.episodeNumber}',
          widget.details);
      if (!mounted || list.isEmpty) return;
      final candidates = StreamResolver.headStartCandidates(
        list,
        lastPlayedHash: lastPlayed,
        preferTier: tier,
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
      _loadingSeason = true;
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
          _loadingSeason = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingSeason = false;
        });
        debugPrint('Failed to load season details: $e');
        showAppMessage(
          context,
          "Couldn't load this season's episodes.",
          error: true,
        );
      }
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _wakelockTimer?.cancel();
    _discardRetimedFiles();
    WakelockPlus.disable();
    _screenTapTimer?.cancel();
    _bufferingRevealTimer?.cancel();
    _seekRevealTimer?.cancel();
    _skipSeekTimer?.cancel();
    // Safety net in case this screen is disposed while still backgrounded.
    BackgroundDownloadService.instance.stop();

    // 1. Reset system navigation and landscape orientation to app defaults,
    // unless that's been done already, or is now the web player's.
    _tilt?.cancel();
    if (!_orientationHandedOn) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // The window's full screen is this player's alone (the web player
    // doesn't use it), so it ends here even when handing over to that.
    // Does nothing off Windows, or when it's already off.
    WindowFullScreen.exit();

    // 2. Save final history position — unless that's been done already
    // (_progressFinal), and the position since is stop()'s 0.
    // History writes are batched to every 15 s, so flush right after: a
    // kill just after closing must not lose the position.
    if (!_progressFinal) {
      _saveProgress(force: true).whenComplete(SavedMoviesService().flush);
    } else {
      SavedMoviesService().flush();
    }

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
    _tracksSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    TorrentEngineService.instance.lowDiskSpace.removeListener(_onLowDiskSpace);
    _errorCheck?.cancel();
    _torrentSub?.cancel();
    _controlsTimer?.cancel();
    _volumeCollapseTimer?.cancel();
    _stallWatchdogTimer?.cancel();
    _resumeBadgeTimer?.cancel();
    _syncedBadgeTimer?.cancel();
    _mediaActionSub?.cancel();
    _mediaSession.deactivate();
    _episodeDrawerController.dispose();
    _playPauseFlash.dispose();
    _upNextFill.dispose();
    _upNextShown.dispose();
    _settingsCloseRequests.dispose();

    // 4. Dispose players and pause (not delete) the active FFI torrent —
    // stops it downloading the rest of a file nobody's watching, but keeps
    // what was downloaded so resuming this content later only fetches the
    // remainder.
    // Wait for media_kit to stop & dispose its HTTP connection first so
    // the C++ HTTP stream server's client thread isn't blocked in send()
    // to a paused mpv socket when lt_stop_stream joins it on the UI thread.
    final torrentId = _torrentId;
    final headStart = _nextHeadStart;
    // Where the viewer stopped and which file it was, taken now: stop()
    // resets the position. The download keeps ~5 minutes before that point
    // and everything after it; unknown (or mid-switch, when the position
    // may belong to another video) means no trimming.
    final streamInfo = LibtorrentFlutter.instance.getStreamInfo(_streamId);
    final playedFileIndex =
        streamInfo != null && streamInfo.torrentId == torrentId
            ? streamInfo.fileIndex
            : -1;
    final keepFrom = streamInfo == null ||
            streamInfo.torrentId != torrentId ||
            _switchingQuality
        ? -1
        : trimKeepFrom(
            fileSize: streamInfo.fileSize,
            position: _currentPosition,
            duration: _duration,
          );
    player.stop().whenComplete(() => player.dispose()).whenComplete(() async {
      // A readied next episode not played: what it got ahead goes (one
      // that was played is now a download of its own, and stays).
      try {
        await _resolver.coolDown(headStart);
      } catch (_) {}
      // Then the torrent is released and trimmed (or just paused, where
      // that isn't possible or the torrent is wanted elsewhere), and the
      // downloads are trimmed to their size limit, if this took them over.
      try {
        await _resolver.releaseAndTrim(torrentId,
            fileIndex: playedFileIndex, keepFrom: keepFrom);
      } catch (_) {
        _resolver.pause(torrentId);
      }
      await TorrentStorageService.enforceLimit();
    });

    // 5. Dispose seek bar / stats notifiers
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _bufferNotifier.dispose();
    _seekHoverFractionNotifier.dispose();
    _timelinePartitionRevision.dispose();
    _activeSkipSegmentNotifier.dispose();
    _downloadSpeedNotifier.dispose();
    _volumeNotifier.dispose();

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

  /// Deletes the retimed subtitle files written to the temp folder (see
  /// _retimeFromReferences) and forgets them: they were for one file.
  void _discardRetimedFiles() {
    for (final path in _retimedPaths.values) {
      File(path).delete().ignore();
    }
    _retimedPaths.clear();
  }

  /// Before opening another copy of the same video (a quality switch, a
  /// reconnect): the old file's built-in tracks, and one picked from them,
  /// don't belong to the new file — each file's tracks are numbered afresh,
  /// so the old number could be another language there, or nothing. The
  /// viewer's language is kept (saved when they picked it), so the new
  /// file's track in it is picked once its tracks are read; a downloaded
  /// track stays on meanwhile. Called inside setState.
  void _forgetFileSubtitles() {
    _discardRetimedFiles();
    _subtitleTimings.clear();
    _autoSyncDone.clear();
    _autoSynced.clear();
    _autoSyncTries.clear();
    _heard = null;
    _heardTried.clear();
    _autoSyncSeen.clear();
    _autoSyncFrom.clear();
    _retimeTried.clear();
    _referenceTimed.clear();
    _embeddedSubtitles = [];
    _userPickedSubtitleForThisVideo = false;
    if (_selectedSubtitle?.isEmbedded ?? false) _selectedSubtitle = null;
    _availableSubtitles = [..._externalSubtitles];
  }

  static bool _isPictureSubtitle(String? codec) {
    final c = (codec ?? '').toLowerCase();
    return c.contains('pgs') ||
        c.contains('dvd_sub') ||
        c.contains('dvdsub') ||
        c.contains('vobsub') ||
        c.contains('dvb_sub') ||
        c.contains('dvbsub') ||
        c.contains('xsub');
  }

  /// The subtitle tracks the player was given from a download (sub-add:
  /// see _applySubtitleTrackToPlayer) — its id → the file's url. They're
  /// in its track list with the video's own, and media_kit doesn't tell
  /// them apart; mpv's own list does.
  Future<Map<String, String>> _addedSubtitleTracks() async {
    try {
      final raw =
          await (player.platform as NativePlayer).getProperty('track-list');
      final list = jsonDecode(raw);
      if (list is! List) return const {};
      return {
        for (final t in list)
          if (t is Map && t['type'] == 'sub' && t['external'] == true)
            '${t['id']}': '${t['external-filename'] ?? ''}',
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _onMpvTracksChanged(Tracks tracks) async {
    if (!mounted) return;
    // Downloaded subtitles given to the player aren't the video's own:
    // they'd be listed twice, the second time as "Embedded in video" —
    // and picked first, as if made for it.
    final added = await _addedSubtitleTracks();
    if (!mounted) return;
    final embedded = <SubtitleTrackData>[];
    for (final s in tracks.subtitle) {
      if (s.id == 'no' || s.id == 'auto' || s.uri) continue;
      if (added.containsKey(s.id)) continue;
      // Picture subtitles (Blu-ray PGS, DVD VobSub, DVB) can't be shown:
      // the subtitles are drawn from mpv's text, and these have none.
      // Left out, so a text track or a downloaded one is picked instead.
      if (_isPictureSubtitle(s.codec)) continue;
      final lang = (s.language ?? '').trim();
      final title = (s.title ?? '').trim();
      if (lang.isEmpty && title.isEmpty) continue;
      embedded.add(SubtitleTrackData(
        id: 'embedded:${s.id}',
        url: s.id,
        lang: lang.isNotEmpty ? lang : title,
        label: title.isNotEmpty ? title : null,
        isEmbedded: true,
      ));
    }

    // Sort non-forced / full dialogue tracks ahead of forced / signs / SDH
    // tracks so auto-selection picks full dialogue first.
    int trackRank(SubtitleTrackData t) {
      final l = (t.label ?? '').toLowerCase();
      if (l.contains('forced') || l.contains('sign')) return 2;
      if (l.contains('sdh') || l.contains('cc')) return 1;
      return 0;
    }

    embedded.sort((a, b) => trackRank(a).compareTo(trackRank(b)));
    _embeddedSubtitles = embedded;
    _rebuildAvailableSubtitles();
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
      // (Subtitles made for this very file are looked for once the video
      // plays: see _fingerprintSubtitles.)
      final stream = _currentStream;
      final videoSizeBytes =
          TorrentDownloadRegistry.parseSizeBytes(stream.size);
      List<SubtitleTrackData> subs;
      if (isTv && _currentSeason != null && _currentEpisode != null) {
        subs = await SubtitleService().fetchSubtitles(
          imdbId,
          season: _currentSeason,
          episode: _currentEpisode,
          videoSizeBytes: videoSizeBytes,
          filename: stream.name,
        );
      } else {
        subs = await SubtitleService().fetchSubtitles(
          imdbId,
          videoSizeBytes: videoSizeBytes,
          filename: stream.name,
        );
      }

      if (!mounted) return;
      // Made for the same release first (see rank): the language's first
      // is the one picked.
      subs = SubtitleService.rank(subs, '${stream.title}\n${stream.name}');
      print('[subtitles] ${subs.length} found');

      _externalSubtitles = subs;
      setState(() => _isLoadingSubtitles = false);
      await _rebuildAvailableSubtitles();
    } catch (e) {
      print('Error loading subtitles: $e');
      if (mounted) {
        setState(() => _isLoadingSubtitles = false);
      }
    }
  }

  // The stream fingerprinted for subtitles already (see
  // _fingerprintSubtitles): once per video.
  String? _fingerprinted;

  /// Subtitles made for this very file — found by its fingerprint (its size
  /// and first and last 64 KB) — added to the list, first: they're in time
  /// with it from the start. Looked for a little after the video starts
  /// playing, not before: on a torrent, reading the file's end has the
  /// engine fetch it first, which slowed starting (the subtitle list
  /// waited on it, and the reads ran on after giving up).
  Future<void> _fingerprintSubtitles() async {
    final url = _streamUrl;
    final imdbId = widget.details.imdbId ?? widget.movie.imdbId;
    if (url.isEmpty || imdbId == null || _fingerprinted == url) return;
    _fingerprinted = url;
    await Future<void>.delayed(const Duration(seconds: 15));
    if (!mounted || _streamUrl != url) return;
    final fingerprint = await SubtitleService().videoFingerprint(url);
    if (!mounted || _streamUrl != url) return;
    if (fingerprint == null) {
      print('[subtitles] no fingerprint');
      return;
    }
    final isTv = widget.movie.type == 'tv';
    final found = await SubtitleService().fetchSubtitles(
      imdbId,
      season: isTv ? _currentSeason : null,
      episode: isTv ? _currentEpisode : null,
      videoSizeBytes: fingerprint.size,
      filename: _currentStream.name,
      videoHash: fingerprint.hash,
    );
    final exact = found.where((s) => s.matchesFile).toList();
    print('[subtitles] fingerprint ${fingerprint.hash}: '
        '${exact.length} made for this file');
    if (!mounted || _streamUrl != url || exact.isEmpty) return;
    final ids = {for (final s in exact) s.id};
    _externalSubtitles = [
      ...exact,
      ..._externalSubtitles.where((s) => !ids.contains(s.id)),
    ];
    // Picked again (unless the viewer chose): one made for this file now
    // comes first in its language.
    await _rebuildAvailableSubtitles();
  }

  Future<void> _rebuildAvailableSubtitles() async {
    // After this, whatever stays selected: retimed if it can be now.
    Future<void>.delayed(Duration.zero, _retimeSelected);
    final combined = <SubtitleTrackData>[
      ..._embeddedSubtitles,
      ..._externalSubtitles,
    ];
    if (mounted) {
      setState(() {
        _availableSubtitles = combined;
      });
    }

    // If the viewer hasn't manually picked a track for this video yet,
    // pick the best match for their preferred language — always preferring
    // an embedded MKV track (which is muxed directly with this exact video
    // stream and has zero framerate/cut drift) over an external SRT.
    if (_userPickedSubtitleForThisVideo) {
      // Even if an external track was auto-selected moments before mpv
      // finished parsing the MKV's embedded tracks, upgrade to the embedded
      // track in the same language automatically.
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _userPickedSubtitleForThisVideo) return;
    final preferred = prefs.getString(_subtitleLangPrefKey) ?? 'eng';
    if (preferred.isEmpty) {
      if (_selectedSubtitle != null) {
        await _selectSubtitle(null, remember: false);
      }
      return;
    }

    final targetLangName = _getLanguageName(preferred);
    final embeddedMatch = _embeddedSubtitles
        .where((s) => _getLanguageName(s.lang) == targetLangName)
        .firstOrNull;
    final externalMatch = _externalSubtitles
        .where((s) =>
            s.url.isNotEmpty && _getLanguageName(s.lang) == targetLangName)
        .firstOrNull;
    final bestMatch = embeddedMatch ?? externalMatch;

    if (bestMatch?.id != _selectedSubtitle?.id) {
      await _selectSubtitle(bestMatch, remember: false);
    }
  }

  /// The list changed (subtitles found, or found by the file's
  /// fingerprint): the subtitle shown retimed against references, if it
  /// couldn't be before for want of them (see _retimeFromReferences).
  void _retimeSelected() {
    final track = _selectedSubtitle;
    if (track != null && !track.isEmbedded) _retimeFromReferences(track);
  }

  Future<void> _applySubtitleTrackToPlayer(SubtitleTrackData? track) async {
    if (track == null || track.url.isEmpty) {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else if (track.isEmbedded) {
      await player.setSubtitleTrack(
        SubtitleTrack(track.url, track.label, track.lang),
      );
    } else {
      // Its retimed copy, when there is one (see _retimeFromReferences).
      final url = _retimedPaths[track.id] ?? track.url;
      // Given to the player before (this video): pick that track again,
      // rather than adding the file another time.
      final added = await _addedSubtitleTracks();
      final id = added.entries
          .where((e) => e.value == url)
          .map((e) => e.key)
          .firstOrNull;
      if (id != null) {
        await player.setSubtitleTrack(
          SubtitleTrack(id, _getLanguageName(track.lang), track.lang),
        );
      } else {
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            url,
            title: _getLanguageName(track.lang),
            language: track.lang,
          ),
        );
      }
    }
  }

  Future<void> _applySubtitleTimingToMpv() async {
    final mpv = player.platform as NativePlayer;
    await mpv.setProperty(
        'sub-delay', _subtitleDelaySeconds.toStringAsFixed(2));
    await mpv.setProperty('sub-speed', _subtitleSpeed.toStringAsFixed(6));
  }

  Future<void> _setSubtitleDelay(double seconds) async {
    // To a hundredth: the ±0.5 s buttons step from an Auto Sync's 2.43 s.
    final clamped = (seconds * 100).round() / 100.0;
    final track = _selectedSubtitle;
    if (track != null) _autoSyncDone.add(track.id);
    setState(() => _subtitleDelaySeconds = clamped.clamp(-60.0, 60.0));
    if (track != null) _rememberTiming(track, byViewer: true);
    final mpv = player.platform as NativePlayer;
    await mpv.setProperty(
        'sub-delay', _subtitleDelaySeconds.toStringAsFixed(2));
  }

  Future<void> _setSubtitleSpeed(double speed) async {
    final track = _selectedSubtitle;
    if (track != null) _autoSyncDone.add(track.id);
    setState(() => _subtitleSpeed = speed.clamp(0.5, 2.0));
    if (track != null) _rememberTiming(track, byViewer: true);
    final mpv = player.platform as NativePlayer;
    await mpv.setProperty('sub-speed', _subtitleSpeed.toStringAsFixed(6));
  }

  // How long the video plays (without a jump) before Auto Sync listens;
  // how much sound it takes, at least — less can be confidently wrong
  // where talk hardly stops (Ghosts S1E7's first 75 s: 30 s out; see
  // SubtitleSync.find) — and at most; how long it waits to try again when
  // it couldn't tell, and how many times it tries.
  static const _autoSyncFirst = Duration(seconds: 15);
  static const _autoSyncShortest = Duration(seconds: 160);
  static const _autoSyncLongest = Duration(minutes: 6);
  static const _autoSyncRetry = Duration(seconds: 45);
  static const _autoSyncMaxTries = 6;

  // Once synced, how often (in watching) it's checked again — with more
  // sound, and a copy can drift from the subtitles' partway (His Girl
  // Friday's 25 fps DVD subtitles, on its web copy: 0.3 s early for an
  // hour, then 3.6 s) — and by how much a new answer must differ to be
  // taken.
  static const _autoSyncRecheck = Duration(minutes: 8);
  static const _autoSyncMinChange = 0.4;

  // A shift bigger than this (seconds) is taken only when another stretch
  // of the video, apart from the first, finds it too. Copies of a show
  // mostly differ by a few seconds; Ghosts S1E7's opening (a loud cold
  // open, then a music gap) twice gave a sure-looking 30.5 s too early,
  // where its Blu-ray subtitles in three languages all say 3.2 s late.
  static const _autoSyncBigShift = 8.0;

  /// Auto Sync, by itself: a downloaded subtitle's timing is set by when
  /// people talk (see _autoSync) — from the sound already heard of this
  /// video when there is some (another subtitle picked: lined up at once),
  /// otherwise from the next few minutes from where the video began
  /// playing here, soon after it starts; tried again a little later when
  /// that wasn't clear, up to [_autoSyncMaxTries] times, and checked again
  /// now and then once synced. Never over the viewer's own timing (see
  /// _setSubtitleDelay), nor for subtitles in the video file, which are
  /// made for it.
  void _maybeAutoSync(Duration pos) {
    // Watching carried on from where it last jumped (a seek, a new video).
    final step = pos - _autoSyncLastPos;
    _autoSyncLastPos = pos;
    if (_watchedFrom == null ||
        step < Duration.zero ||
        step > const Duration(seconds: 3)) {
      _watchedFrom = pos;
    }
    final track = _selectedSubtitle;
    if (track == null ||
        track.isEmbedded ||
        _referenceTimed.contains(track.id) ||
        _autoSyncing ||
        _autoSyncDone.contains(track.id) ||
        _isMediaOpening ||
        _switchingQuality ||
        _duration <= Duration.zero) {
      return;
    }
    // The sound's been heard already: this subtitle against it, now.
    final heard = _heard;
    if (heard != null &&
        heard.url == _streamUrl &&
        !_autoSynced.contains(track.id) &&
        _heardTried.add(track.id)) {
      _autoSync(track, heard: heard);
      return;
    }
    if (!_isPlaying || _isBuffering) return;
    if (pos - _watchedFrom! < _autoSyncFirst) return;
    final tried = _autoSyncTries[track.id];
    if (tried != null && pos < tried.next) return;
    // From where watching began here: what's been watched, and enough of
    // what's next (the player's fetching it anyway) to have a long enough
    // stretch.
    var from = _watchedFrom!;
    var to = pos + const Duration(seconds: 10);
    if (to - from < _autoSyncShortest) to = from + _autoSyncShortest;
    if (to - from > _autoSyncLongest) from = to - _autoSyncLongest;
    // Not clear yet: the next stretch after the last one heard.
    final after = _autoSyncFrom.remove(track.id);
    if (after != null && after + _autoSyncShortest <= _duration) {
      from = after;
      to = after + _autoSyncShortest;
    }
    // Listening reads the stream as fast as it can: only once the player
    // has a good lead on the video, so it never competes with playback
    // for a slow stream. (Tried again on the next tick.)
    if (player.state.buffer - pos < _autoSyncMinLead) return;
    _autoSync(track, from: from, to: to > _duration ? _duration : to);
  }

  /// The buffered video ahead of the position that auto sync waits for
  /// before starting its second player (see _maybeAutoSync).
  static const Duration _autoSyncMinLead = Duration(seconds: 30);

  /// Sets [track]'s timing by when people talk — in the sound from [from]
  /// to [to], heard by a second, silent player, or the sound [heard]
  /// already — matched against the subtitles' (SubtitleSync); any
  /// language. Only when the match is clear; otherwise left as it is, to
  /// try again.
  Future<void> _autoSync(
    SubtitleTrackData track, {
    Duration? from,
    Duration? to,
    ({String url, double start, Int16List pcm})? heard,
  }) async {
    final url = _streamUrl;
    _autoSyncing = true;
    final took = Stopwatch()..start();
    var clear = false;
    Duration? checkFrom;
    print('[sync] ${heard != null ? 'matching what was heard' : 'listening'}'
        ': ${track.lang} subtitles (${track.id})'
        '${heard != null ? '' : ', ${from!.inSeconds}–${to!.inSeconds} s of the video'}'
        ', try ${(_autoSyncTries[track.id]?.tries ?? 0) + 1}');
    try {
      var cues = _subtitleCues[track.url];
      if (cues == null) {
        cues = SubtitleSync.parseCues(await _subtitleText(track));
        _subtitleCues[track.url] = cues;
      }
      final double start;
      final Int16List? pcm;
      if (heard != null) {
        start = heard.start;
        pcm = heard.pcm;
      } else {
        start = from!.inMilliseconds / 1000;
        final audio = player.state.track.audio.id;
        pcm = await SubtitleSync.decodeSound(
          url,
          start: start,
          end: to!.inMilliseconds / 1000,
          audioTrack: audio == 'auto' || audio == 'no' ? null : audio,
          // The second player reads the same stream as fast as it can:
          // stop it as soon as the player closes or the video changes.
          isCancelled: () => !mounted || _streamUrl != url,
        );
      }
      // Another episode or copy meanwhile: not this one's sound.
      if (!mounted || _streamUrl != url) return;
      if (pcm == null ||
          pcm.length <
              SubtitleSync.minSure.inMilliseconds *
                  SubtitleSync.sampleRate ~/
                  1000) {
        print("[sync] couldn't get the sound "
            '(${took.elapsedMilliseconds} ms)');
        return;
      }
      if (heard == null) {
        // Kept for another subtitle picked meanwhile; one already tried
        // against less sound is tried again with this.
        _heard = (url: url, start: start, pcm: pcm);
        _heardTried
          ..clear()
          ..add(track.id);
      }
      final result = await _findSubtitleTiming(pcm, start, cues);
      final end = start + pcm.length / SubtitleSync.sampleRate;
      print('[sync] ${track.lang} ${start.round()}–${end.round()} s: $result '
          '(${took.elapsedMilliseconds} ms)');
      // The viewer set it meanwhile, references retimed it, or another
      // copy's playing.
      if (!mounted ||
          _streamUrl != url ||
          _autoSyncDone.contains(track.id) ||
          _referenceTimed.contains(track.id)) {
        return;
      }
      if (result == null) return;
      final delay = (result.delay * 100).round() / 100;
      // Taken when sure and a small shift — or when another stretch of the
      // video, apart from this one, found the same (sure or not: two
      // stretches agreeing by chance is unlikely). A big shift sure on its
      // own isn't enough (see _autoSyncBigShift).
      final seen = _autoSyncSeen.putIfAbsent(track.id, () => []);
      final agreed = seen.any((o) =>
          (o.delay - delay).abs() <= 0.4 &&
          (o.speed - result.speed).abs() < 0.001 &&
          (start >= o.end || end <= o.start));
      if (result.score >= 0.12 && result.margin >= 0.03) {
        seen.add((
          delay: delay,
          speed: result.speed,
          start: start,
          end: end,
        ));
      }
      final take = agreed ||
          (result.sure && delay.abs() <= _autoSyncBigShift);
      if (!take) {
        checkFrom = Duration(milliseconds: (end * 1000).round());
        print(result.sure
            ? '[sync] a big shift: checking it against the next stretch'
            : '[sync] not clear: listening to the next stretch');
        return;
      }
      if (agreed) print('[sync] two stretches agree');
      clear = true;
      final selected = _selectedSubtitle?.id == track.id;
      final now = selected
          ? (delay: _subtitleDelaySeconds, speed: _subtitleSpeed)
          : _subtitleTimings[track.id];
      if (_autoSynced.contains(track.id) &&
          now != null &&
          (now.delay - delay).abs() < _autoSyncMinChange &&
          (now.speed - result.speed).abs() < 0.001) {
        print('[sync] still in time');
        return;
      }
      print('[sync] applied: ${result.delay.toStringAsFixed(2)} s, '
          'speed ${result.speed.toStringAsFixed(4)}');
      if (selected) {
        final moved = delay - _subtitleDelaySeconds;
        setState(() {
          _subtitleDelaySeconds = delay;
          _subtitleSpeed = result.speed;
        });
        await _applySubtitleTimingToMpv();
        _showSyncedBadge(moved);
      } else {
        // Switched from meanwhile: for when it's back.
        _subtitleTimings[track.id] = (delay: delay, speed: result.speed);
      }
      _rememberTiming(track,
          timing: (delay: delay, speed: result.speed), byViewer: false);
    } catch (e) {
      print('[sync] failed: $e');
    } finally {
      _autoSyncing = false;
      if (_autoSyncDone.contains(track.id)) {
        // The viewer's timing: left alone.
      } else if (clear || _autoSynced.contains(track.id)) {
        // In time: checked again a while on.
        if (clear) _autoSynced.add(track.id);
        _autoSyncTries[track.id] =
            (tries: 0, next: _currentPosition + _autoSyncRecheck);
      } else {
        final tries = (_autoSyncTries[track.id]?.tries ?? 0) + 1;
        if (tries >= _autoSyncMaxTries) {
          print('[sync] not applied; giving up on these subtitles');
          _autoSyncDone.add(track.id);
        } else if (checkFrom != null) {
          // More to go by: at once, the stretch after.
          _autoSyncFrom[track.id] = checkFrom;
          _autoSyncTries[track.id] = (tries: tries, next: _currentPosition);
        } else {
          print('[sync] not applied; trying again in '
              '${_autoSyncRetry.inSeconds} s of watching');
          _autoSyncTries[track.id] =
              (tries: tries, next: _currentPosition + _autoSyncRetry);
        }
      }
      // The subtitle menu's note (see _subtitleSyncNote).
      if (mounted) setState(() {});
    }
  }

  /// The subtitles shown being synced, not yet in time: the Subtitles
  /// button (Settings, on a phone) glows, as smart features do.
  bool get _subtitlesSyncing => _subtitleSyncNote == 'Syncing…';

  // One client for every subtitle download, with timeouts: a new one per
  // call had none, so a dead server hung the sync.
  static final Dio _subtitleDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  /// [track]'s text (an SRT, VTT or ASS file), downloaded once.
  Future<String> _subtitleText(SubtitleTrackData track) async {
    final cached = _subtitleTexts[track.url];
    if (cached != null) return cached;
    final response = await _subtitleDio.get<String>(
      track.url,
      options: Options(responseType: ResponseType.plain),
    );
    return _subtitleTexts[track.url] = response.data ?? '';
  }

  /// [track] retimed against reference subtitles — others in the list made
  /// for a copy like the one playing (its kind of source: Blu-ray, web,
  /// TV), in any language, as when lines are on screen is what's compared
  /// — piece by piece along the video (SubtitleRetime). Two references
  /// from different release groups have to agree (or one made for this
  /// very file). Instant beside listening (Auto Sync), which needs minutes
  /// of sound — and right where a subtitle drifts from the copy: Ghosts
  /// S1E8's web-rip English one is 2.6 s off its Blu-ray copy at the start
  /// and 5.6 s by the end, in steps at the ad breaks, which no one delay
  /// fits. Without references, Auto Sync's listening goes on.
  Future<void> _retimeFromReferences(SubtitleTrackData track) async {
    if (track.isEmbedded ||
        _retimedPaths.containsKey(track.id) ||
        _autoSyncDone.contains(track.id) || // the viewer's own timing
        _retimeTried.contains(track.id)) {
      return;
    }
    final stream = _currentStream;
    final video = '${stream.title}\n${stream.name}';
    if (SubtitleService.sourceOf(video) == null) return;
    // Made for this release (its group's, or this file): in time already.
    if (SubtitleService.likeness(track, video) >= 4) return;
    final refs = [
      for (final s in _externalSubtitles)
        if (s.id != track.id &&
            s.url.isNotEmpty &&
            SubtitleService.likeness(s, video) >= 2)
          s,
    ]..sort((a, b) => SubtitleService.likeness(b, video)
        .compareTo(SubtitleService.likeness(a, video)));
    // (Not yet, maybe: tried again when the list grows.)
    if (refs.length < 2 && !refs.any((r) => r.matchesFile)) return;
    _retimeTried.add(track.id);
    final url = _streamUrl;
    final took = Stopwatch()..start();
    try {
      final picked = refs.take(4).toList();
      final text = await _subtitleText(track);
      final refTexts = await Future.wait(picked.map(_subtitleText));
      final map = await _retimeMapInBackground(
        text,
        refTexts,
        [
          for (final r in picked)
            (r.releaseGroup ?? r.releaseName ?? r.id).toLowerCase(),
        ],
        [for (final r in picked) r.matchesFile],
      );
      if (!mounted || _streamUrl != url) return;
      if (map == null) {
        print('[sync] references (${picked.map((r) => r.lang).join(', ')}) '
            "don't agree; listening instead");
        return;
      }
      final ext = text.contains('[Events]')
          ? 'ass'
          : text.trimLeft().startsWith('WEBVTT')
              ? 'vtt'
              : 'srt';
      final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
          'popcorn_sub_${track.id}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await file.writeAsString(SubtitleRetime.retime(text, map));
      if (!mounted || _streamUrl != url) return;
      _retimedPaths[track.id] = file.path;
      _referenceTimed.add(track.id);
      print('[sync] retimed by references '
          '(${picked.map((r) => r.lang).join(', ')}) in '
          '${took.elapsedMilliseconds} ms: $map');
      // A timing kept from listening was for the file as it came.
      SharedPreferences.getInstance()
          .then((prefs) => prefs.remove(_timingKey(track)));
      if (_selectedSubtitle?.id == track.id) {
        // How far the lines on screen move: the map's delay here, less the
        // delay they had.
        final here = _currentPosition.inMilliseconds / 1000;
        final moved = map.delayAt(here) - _subtitleDelaySeconds;
        setState(() {
          _subtitleDelaySeconds = 0;
          _subtitleSpeed = 1;
        });
        await _applySubtitleTimingToMpv();
        await _applySubtitleTrackToPlayer(track);
        _showSyncedBadge(moved);
      } else {
        _subtitleTimings[track.id] = (delay: 0.0, speed: 1.0);
        if (mounted) setState(() {});
      }
    } catch (e) {
      print('[sync] retiming failed: $e');
    }
  }

  /// _retimeMap, off the screen's thread. (Static: nothing of the screen
  /// goes with it.)
  static Future<TimingMap?> _retimeMapInBackground(
    String text,
    List<String> refTexts,
    List<String> groups,
    List<bool> exact,
  ) =>
      Isolate.run(() => _retimeMap(text, refTexts, groups, exact));

  /// [text]'s timing map against the references [refTexts]: one made for
  /// this very file ([exact]) alone, otherwise two from different release
  /// [groups] that agree, averaged. Null if none do.
  static TimingMap? _retimeMap(
    String text,
    List<String> refTexts,
    List<String> groups,
    List<bool> exact,
  ) {
    final cues = SubtitleSync.parseCues(text);
    final maps = [
      for (final t in refTexts)
        SubtitleRetime.mapAgainst(cues, SubtitleSync.parseCues(t)),
    ];
    for (var i = 0; i < maps.length; i++) {
      if (exact[i] && maps[i] != null) return maps[i];
    }
    for (var i = 0; i < maps.length; i++) {
      for (var j = i + 1; j < maps.length; j++) {
        final a = maps[i], b = maps[j];
        if (a == null || b == null || groups[i] == groups[j]) continue;
        if (a.agreesWith(b)) return a.averagedWith(b);
      }
    }
    return null;
  }

  /// The subtitle menu's word on Auto Sync for the subtitles shown: at it,
  /// done — or nothing (the viewer's own timing, subtitles in the video
  /// file, or given up on).
  String? get _subtitleSyncNote {
    final track = _selectedSubtitle;
    if (track == null || track.isEmbedded) return null;
    if (_autoSyncDone.contains(track.id)) return null;
    return _autoSynced.contains(track.id) || _referenceTimed.contains(track.id)
        ? 'Synced'
        : 'Syncing…';
  }

  /// Where [track]'s timing for the copy playing is kept between visits.
  String _timingKey(SubtitleTrackData track) =>
      'subtitle_timing2_${_currentStream.infoHash.toLowerCase()}_${track.id}';

  /// Keeps [track]'s timing ([timing], or the one set now) for the next
  /// time this copy plays with it — and whether the viewer set it.
  Future<void> _rememberTiming(
    SubtitleTrackData track, {
    ({double delay, double speed})? timing,
    required bool byViewer,
  }) async {
    if (track.isEmbedded) return;
    final t = timing ?? (delay: _subtitleDelaySeconds, speed: _subtitleSpeed);
    final key = _timingKey(track);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, '${t.delay}|${t.speed}|${byViewer ? 'viewer' : 'sync'}');
  }

  /// [track]'s timing kept from an earlier visit (see _rememberTiming).
  Future<({double delay, double speed, bool byViewer})?> _savedTiming(
    SubtitleTrackData track,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final parts = prefs.getString(_timingKey(track))?.split('|');
    if (parts == null || parts.length < 3) return null;
    final delay = double.tryParse(parts[0]);
    final speed = double.tryParse(parts[1]);
    if (delay == null || speed == null) return null;
    return (delay: delay, speed: speed, byViewer: parts[2] == 'viewer');
  }

  /// SubtitleSync.find, off the screen's thread: a few hundred
  /// milliseconds' sums on a phone. (Static: nothing of the screen goes
  /// with it.)
  static Future<SubtitleSyncResult?> _findSubtitleTiming(
    Int16List pcm,
    double start,
    List<SubtitleCue> cues,
  ) =>
      Isolate.run(
          () => SubtitleSync.find(pcm, windowStart: start, cues: cues));

  /// Shows [track] (null = subtitles off). A choice the viewer made
  /// ([remember]) becomes their preference for every video after this
  /// one — see _loadSubtitles.
  Future<void> _selectSubtitle(
    SubtitleTrackData? track, {
    bool remember = true,
  }) async {
    if (remember) {
      _userPickedSubtitleForThisVideo = true;
    }
    final old = _selectedSubtitle;
    if (old != null) {
      _subtitleTimings[old.id] =
          (delay: _subtitleDelaySeconds, speed: _subtitleSpeed);
    }
    var timing = track == null ? null : _subtitleTimings[track.id];
    if (track != null && !track.isEmbedded && timing == null) {
      // Synced (or set) when this copy was played before.
      final saved = await _savedTiming(track);
      if (saved != null) {
        timing = (delay: saved.delay, speed: saved.speed);
        (saved.byViewer ? _autoSyncDone : _autoSynced).add(track.id);
      }
    }
    final retime = (timing?.delay ?? 0.0) != _subtitleDelaySeconds ||
        (timing?.speed ?? 1.0) != _subtitleSpeed;
    if (!mounted) return; // Closed while the saved timing was read.
    setState(() {
      _selectedSubtitle = track;
      _subtitleDelaySeconds = timing?.delay ?? 0.0;
      _subtitleSpeed = timing?.speed ?? 1.0;
    });
    if (retime) await _applySubtitleTimingToMpv();
    if (!mounted) return;
    if (remember) {
      SharedPreferences.getInstance().then(
          (prefs) => prefs.setString(_subtitleLangPrefKey, track?.lang ?? ''));
    }
    await _applySubtitleTrackToPlayer(track);
    if (track != null) _retimeFromReferences(track);
  }

  // ─── Skip Intro / Recap / Credits / Preview (MKV chapters + API fallback) ───

  Future<void> _onMpvChapterList(String rawJson) async {
    if (!mounted) return;
    _lastRawChapterList = rawJson;
    _mkvChapters = SkipSegmentsService().parseMpvChapters(
      rawJson,
      totalDuration: _duration,
    );
    _mkvSkipSegments = SkipSegmentsService().parseMpvChapterList(
      rawJson,
      totalDuration: _duration,
    );
    _rebuildSkipSegments();
  }

  void _reparseMkvChaptersForDuration(Duration dur) {
    // No chapters: the skip-time services' parts are still fitted to the
    // file's length, now it's known (see _rebuildSkipSegments).
    if (_lastRawChapterList.isEmpty) {
      _rebuildSkipSegments();
      return;
    }
    _mkvChapters = SkipSegmentsService().parseMpvChapters(
      _lastRawChapterList,
      totalDuration: dur,
    );
    _mkvSkipSegments = SkipSegmentsService().parseMpvChapterList(
      _lastRawChapterList,
      totalDuration: dur,
    );
    _rebuildSkipSegments();
  }

  Future<void> _loadApiSkipSegments() async {
    final season = _currentSeason;
    final episode = _currentEpisode;
    final segments = await SkipSegmentsService().fetchApiSegments(
      tmdbId: widget.details.id,
      imdbId: widget.details.imdbId ?? widget.movie.imdbId,
      type: widget.details.type,
      season: season,
      episode: episode,
    );
    if (!mounted || season != _currentSeason || episode != _currentEpisode) {
      return;
    }
    _apiSkipSegments = segments;
    _rebuildSkipSegments();
  }

  void _rebuildSkipSegments() {
    _skipSegments = SkipSegmentsService().merge(
      mkvSegments: _mkvSkipSegments,
      // Measured on some copy of the video; fitted to this file.
      apiSegments:
          SkipSegmentsService().alignToFile(_apiSkipSegments, _duration),
    );
    _logSkipSegments();
    _updateTimelineShapes();
    _timelinePartitionRevision.value++;
    _updateActiveSkipSegment(_currentPosition);
  }

  // The last "[skip]" line logged, so it's logged only when it changes.
  String? _lastSkipLog;

  /// Logs the skip times this file got, and where from ("[skip] 21:46
  /// long: credits 20:49–end (introdb)") — for when a Skip button's in the
  /// wrong place: was it the data, or the fitting to this file?
  void _logSkipSegments() {
    if (_duration <= Duration.zero) return;
    String clock(Duration d) =>
        '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    final parts = [
      for (final s in _skipSegments)
        '${s.type.name} ${clock(s.start)}–'
            '${s.end == null ? 'end' : clock(s.end!)} (${s.source})',
    ];
    final line = '[skip] S${_currentSeason ?? '-'}E${_currentEpisode ?? '-'}, '
        '${clock(_duration)} long: '
        '${parts.isEmpty ? 'nothing to skip' : parts.join(', ')}';
    if (line == _lastSkipLog) return;
    _lastSkipLog = line;
    print(line);
  }

  // The seek bar's skip ranges and partition gaps, worked out when the
  // segments or the duration change rather than on every rebuild of the bar.
  List<({double start, double end})> _skipRanges = const [];
  List<double> _partitions = const [];

  void _updateTimelineShapes() {
    _skipRanges = _skipRangesFor(_duration);
    _partitions = _partitionFractionsFor(_duration);
  }

  /// Normalized `(start, end)` fraction ranges (`0.0..1.0`) for skippable
  /// segments (`Intro`, `Recap`, `Credits`, `Preview`) on the seek bar.
  List<({double start, double end})> _skipRangesFor(Duration totalDuration) {
    final totalMs = totalDuration.inMilliseconds;
    if (totalMs <= 0 || _skipSegments.isEmpty) return const [];
    final ranges = <({double start, double end})>[];
    for (final s in _skipSegments) {
      final startFrac = (s.start.inMilliseconds / totalMs).clamp(0.0, 1.0);
      final endMs = (s.end ?? totalDuration).inMilliseconds;
      final endFrac = (endMs / totalMs).clamp(0.0, 1.0);
      if (endFrac - startFrac >= 0.003) {
        ranges.add((start: startFrac, end: endFrac));
      }
    }
    return ranges;
  }

  /// Normalized boundary fractions (`0.0 < f < 1.0`) where the seek bar
  /// draws a partition gap (MKV chapters + skip segment boundaries).
  List<double> _partitionFractionsFor(Duration totalDuration) {
    final totalMs = totalDuration.inMilliseconds;
    if (totalMs <= 0) return const [];
    final rawPoints = <double>[];
    for (final ch in _mkvChapters) {
      final f = ch.start.inMilliseconds / totalMs;
      if (f > 0.008 && f < 0.992) rawPoints.add(f);
    }
    for (final s in _skipSegments) {
      final sf = s.start.inMilliseconds / totalMs;
      if (sf > 0.008 && sf < 0.992) rawPoints.add(sf);
      if (s.end != null) {
        final ef = s.end!.inMilliseconds / totalMs;
        if (ef > 0.008 && ef < 0.992) rawPoints.add(ef);
      }
    }
    if (rawPoints.isEmpty) return const [];
    rawPoints.sort();
    // Deduplicate points that are within 0.6% of total duration so adjacent
    // markers don't chew up the track.
    final deduped = <double>[rawPoints.first];
    for (var i = 1; i < rawPoints.length; i++) {
      if (rawPoints[i] - deduped.last >= 0.006) {
        deduped.add(rawPoints[i]);
      }
    }
    return deduped;
  }

  /// Chapter or skip-segment label for [position] to show inside the seek
  /// bar's hover/drag tooltip (e.g. `"Intro"`, `"Credits"`, or an MKV
  /// chapter title).
  String? _segmentLabelAt(Duration position, Duration totalDuration) {
    if (totalDuration <= Duration.zero) return null;
    for (final seg in _skipSegments) {
      final end = seg.end ?? totalDuration;
      if (position >= seg.start && position < end) {
        return seg.type.shortLabel;
      }
    }
    for (final ch in _mkvChapters) {
      if (ch.contains(position, totalDuration)) {
        return ch.meaningfulTitle;
      }
    }
    return null;
  }

  void _updateActiveSkipSegment(Duration pos) {
    if (_loadingVideo || _skipSegments.isEmpty) {
      if (_activeSkipSegmentNotifier.value != null) {
        _activeSkipSegmentNotifier.value = null;
      }
      return;
    }
    SkipSegment? active;
    for (final seg in _skipSegments) {
      if (seg.contains(pos, _duration)) {
        active = seg;
        break;
      }
    }
    if (_activeSkipSegmentNotifier.value != active) {
      _activeSkipSegmentNotifier.value = active;
    }
  }

  void _skipActiveSegment(SkipSegment segment) {
    _activeSkipSegmentNotifier.value = null;
    if (segment.type == SkipSegmentType.credits &&
        widget.details.type == 'tv' &&
        (_nextEpisode != null && !_nextEpisode!.isUnreleased) &&
        (segment.end == null ||
            (_duration > Duration.zero &&
                _duration - segment.end! <= const Duration(seconds: 15)))) {
      _playNextEpisode();
      return;
    }
    final target = segment.targetFor(_duration);
    if (target <= _currentPosition) return;
    _currentPosition = target;
    _positionNotifier.value = target;
    _seekTo(target);
    _syncMediaSessionPlaybackState();
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
    final wide = playerIsWide(context);
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
      // Back closes a panel, or else the player — via _close, to turn the
      // phone back first.
      canPop: false,
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
        } else {
          _close();
        }
      },
      child: _closing
          ? const ColoredBox(color: Colors.black)
          : Focus(
        autofocus: true,
        descendantsAreFocusable: false,
        child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: (!_controlsVisible &&
                  _isPlaying &&
                  !_showEpisodeDrawer &&
                  !_showSettingsPanel)
              ? SystemMouseCursors.none
              : MouseCursor.defer,
          onHover: _onMouseHover,
          child: Stack(
          children: [
            // Layer 1: PlayerGestureOverlay + Video + Controls
            PlayerGestureOverlay(
              enabled: !_episodeCoversVideo && !_showSettingsPanel,
              onTapAt: _onScreenTap,
              suppressDoubleTap: () => _pointerWasOnControls,
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
              onDoubleClick: WindowFullScreen.supported
                  ? () {
                      // The double-click's first click already scheduled
                      // a pause or the controls.
                      _screenTapTimer?.cancel();
                      // Not in the controls' strip, where clicks do
                      // nothing (see _inBottomBand), nor on a button.
                      if (_lastTapInBottomBand || _pointerWasOnControls) {
                        return;
                      }
                      WindowFullScreen.toggle();
                    }
                  : null,
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
                          width: wide ? 96 : 84,
                          height: wide ? 96 : 84,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_flashIcon,
                              color: Colors.white, size: wide ? 56 : 48),
                        ),
                      ),
                    ),
                  ),

                  // Switching (quality, episode, season, recovery): the
                  // video stays visible, softly darkened, under a small
                  // spinner and one quiet line.
                  if (_switchingQuality || _loadingSeason)
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
                            top: (wide ? 20 : 8) +
                                MediaQuery.of(context).padding.top,
                            left: (wide ? 28 : 16) + safe.left,
                            right: (wide ? 28 : 16) + safe.right,
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
                                          leading: CircleAvatar(
                                            backgroundColor: Colors.transparent,
                                            child: IconButton(
                                              icon: const Icon(
                                                GlassCircleButton.backIcon,
                                                color: Colors.white,
                                              ),
                                              tooltip: MaterialLocalizations.of(
                                                      context)
                                                  .backButtonTooltip,
                                              onPressed: () =>
                                                  Navigator.maybePop(context),
                                              iconSize: wide
                                                  ? 28
                                                  : GlassCircleButton
                                                      .backIconSize,
                                              padding: EdgeInsets.zero,
                                            ),
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
                                          Icon(
                                              Icons.arrow_downward_rounded,
                                              color: Colors.white38,
                                              size: wide ? 15 : 12),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${speed.toStringAsFixed(1)} MB/s',
                                            style: TextStyle(
                                                color: Colors.white54,
                                                fontWeight: FontWeight.w500,
                                                fontSize: wide ? 13.5 : 11),
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
                            top: 0,
                            bottom: 0,
                            left: (wide ? 56 : 32) + safe.left,
                            width: size.width * (wide ? 0.42 : 0.38),
                            child: IgnorePointer(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 350),
                                  opacity:
                                      (!_isPlaying && _controlsVisible) ? 1.0 : 0.0,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Title or Logo
                                      if (widget.details.logoUrl != null &&
                                          widget.details.logoUrl!.isNotEmpty)
                                        Padding(
                                          padding: EdgeInsets.only(
                                              bottom: wide ? 10 : 6),
                                          child: CachedNetworkImage(
                                            imageUrl: widget.details.logoUrl!,
                                            height: wide ? 120 : 64,
                                            fit: BoxFit.contain,
                                            alignment: Alignment.centerLeft,
                                            errorWidget:
                                                (context, url, error) {
                                              return Text(
                                                widget.movie.title,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: wide ? 38 : 22,
                                                  fontWeight: FontWeight.w800,
                                                  height: 1.15,
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
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: wide ? 38 : 22,
                                            fontWeight: FontWeight.w800,
                                            height: 1.15,
                                          ),
                                        ),
                                      // TV episode info, in the episode cards'
                                      // style: a small "S1 · E3" label over the
                                      // episode's name.
                                      if (widget.details.type == 'tv' &&
                                          _currentEpisode != null) ...[
                                        SizedBox(height: wide ? 16 : 10),
                                        Text(
                                          'S$_currentSeason · E$_currentEpisode',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: wide ? 16 : 12,
                                            height: 1.2,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        if (_playingEpisode?.name
                                            case final name?
                                            when name.isNotEmpty) ...[
                                          SizedBox(height: wide ? 4 : 2),
                                          Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: wide ? 24 : 15,
                                              height: 1.25,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                      SizedBox(height: wide ? 14 : 10),
                                      // Description
                                      Text(
                                        (_playingEpisode?.overview ?? '')
                                                .isNotEmpty
                                            ? _playingEpisode!.overview
                                            : widget.movie.description,
                                        maxLines: wide ? 4 : 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: wide
                                              ? Colors.white70
                                              : Colors.white60,
                                          fontSize: wide ? 18 : 13,
                                          height: 1.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // ─── BOTTOM BAR ───
                          Positioned(
                            bottom: (wide ? 24 : 16) +
                                MediaQuery.of(context).padding.bottom,
                            left: (wide ? 32 : 24) + safe.left,
                            right: (wide ? 32 : 24) + safe.right,
                            child: Listener(
                              key: _bottomBarKey,
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
                                      _bufferNotifier,
                                      _seekHoverFractionNotifier,
                                      _timelinePartitionRevision,
                                    ]),
                                    builder: (context, _) {
                                      final dur = _durationNotifier.value;
                                      final totalSeconds =
                                          dur.inSeconds.toDouble();
                                      final hoverFraction =
                                          _seekHoverFractionNotifier.value;
                                      final dragFraction = (_isDragging &&
                                              totalSeconds > 0)
                                          ? (_positionNotifier.value.inSeconds /
                                                  totalSeconds)
                                              .clamp(0.0, 1.0)
                                          : null;
                                      final activeFraction =
                                          dragFraction ?? hoverFraction;
                                      final showTooltip = !_loadingVideo &&
                                          totalSeconds > 0 &&
                                          activeFraction != null;
                                      final tooltipDuration = showTooltip
                                          ? Duration(
                                              seconds: (activeFraction *
                                                      totalSeconds)
                                                  .round()
                                                  .clamp(0, dur.inSeconds),
                                            )
                                          : Duration.zero;
                                      final tooltipLabel = showTooltip
                                          ? _segmentLabelAt(
                                              tooltipDuration,
                                              dur,
                                            )
                                          : null;
                                      final skipRanges = _skipRanges;
                                      final partitions = _partitions;
                                      final pad = wide ? 16.0 : 14.0;

                                      return LayoutBuilder(
                                        builder: (context, constraints) {
                                          final trackWidth = math.max(
                                            1.0,
                                            constraints.maxWidth - pad * 2,
                                          );
                                          final f = activeFraction ?? 0.0;
                                          final targetX =
                                              pad + f * trackWidth;
                                          final halfPill = tooltipLabel != null
                                              ? 110.0
                                              : 44.0;
                                          final clampedCenter = targetX.clamp(
                                            halfPill,
                                            math.max(
                                              halfPill,
                                              constraints.maxWidth - halfPill,
                                            ),
                                          );

                                          return Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              if (showTooltip)
                                                Positioned(
                                                  left:
                                                      clampedCenter - halfPill,
                                                  width: halfPill * 2,
                                                  bottom: wide ? 36 : 32,
                                                  child: IgnorePointer(
                                                    child: Center(
                                                      child: ClipPath(
                                                        clipper:
                                                            const ShapeBorderClipper(
                                                          shape:
                                                              StadiumBorder(),
                                                        ),
                                                        child: GlassBlur(
                                                          child: DecoratedBox(
                                                            decoration:
                                                                ShapeDecoration(
                                                              color: kGlassTint,
                                                              shape:
                                                                  StadiumBorder(
                                                                side: BorderSide(
                                                                  color:
                                                                      kGlassEdge,
                                                                ),
                                                              ),
                                                            ),
                                                            child: Padding(
                                                              padding:
                                                                  EdgeInsets.symmetric(
                                                                horizontal: wide
                                                                    ? 11
                                                                    : 9,
                                                                vertical:
                                                                    wide ? 5 : 4,
                                                              ),
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  Text(
                                                                    _formatDuration(
                                                                      tooltipDuration,
                                                                    ),
                                                                    style:
                                                                        TextStyle(
                                                                      color: Colors
                                                                          .white,
                                                                      fontSize: wide
                                                                          ? 13
                                                                          : 11.5,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                      height: 1.1,
                                                                      fontFeatures: const [
                                                                        FontFeature
                                                                            .tabularFigures(),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                  if (tooltipLabel !=
                                                                      null) ...[
                                                                    Flexible(
                                                                      child:
                                                                          Text(
                                                                        '  ·  $tooltipLabel',
                                                                        maxLines:
                                                                            1,
                                                                        overflow:
                                                                            TextOverflow.ellipsis,
                                                                        style:
                                                                            TextStyle(
                                                                          color:
                                                                              Colors.white70,
                                                                          fontSize: wide
                                                                              ? 12.5
                                                                              : 11,
                                                                          fontWeight:
                                                                              FontWeight.w500,
                                                                          height:
                                                                              1.1,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              MouseRegion(
                                                onHover: (event) {
                                                  final frac =
                                                      ((event.localPosition.dx -
                                                                  pad) /
                                                              trackWidth)
                                                          .clamp(0.0, 1.0);
                                                  _seekHoverFractionNotifier
                                                      .value = frac;
                                                },
                                                onExit: (_) {
                                                  _seekHoverFractionNotifier
                                                      .value = null;
                                                },
                                                child: SliderTheme(
                                                  // The cards' progress bar: a thin
                                                  // cream line, with a small white dot
                                                  // to drag, partitioned by chapters and
                                                  // skip segments.
                                                  data: SliderThemeData(
                                                    trackHeight:
                                                        wide ? 4.5 : 3,
                                                    trackShape:
                                                        _PartitionedSliderTrackShape(
                                                      partitions: partitions,
                                                      skipRanges: skipRanges,
                                                      hoveredFraction:
                                                          activeFraction,
                                                    ),
                                                    activeTrackColor:
                                                        AppTheme.primaryColor,
                                                    secondaryActiveTrackColor:
                                                        Colors.white.withValues(
                                                            alpha: 0.3),
                                                    inactiveTrackColor: Colors
                                                        .white
                                                        .withValues(
                                                            alpha: 0.15),
                                                    thumbColor: Colors.white,
                                                    thumbShape:
                                                        RoundSliderThumbShape(
                                                            enabledThumbRadius:
                                                                wide ? 7.5 : 6,
                                                            elevation: 0,
                                                            pressedElevation:
                                                                0),
                                                    overlayShape:
                                                        RoundSliderOverlayShape(
                                                            overlayRadius: wide
                                                                ? 16
                                                                : 14),
                                                    overlayColor: Colors.white
                                                        .withValues(
                                                            alpha: 0.12),
                                                  ),
                                                  // No seeking until the video has
                                                  // loaded (see _loadingVideo).
                                                  child: IgnorePointer(
                                                    ignoring: _loadingVideo,
                                                    child: Slider(
                                                      value: _positionNotifier
                                                          .value.inSeconds
                                                          .toDouble()
                                                          .clamp(0.0,
                                                              totalSeconds),
                                                      secondaryTrackValue:
                                                          _bufferNotifier
                                                              .value.inSeconds
                                                              .toDouble()
                                                              .clamp(0.0,
                                                                  totalSeconds),
                                                      min: 0.0,
                                                      max: totalSeconds > 0
                                                          ? totalSeconds
                                                          : 1.0,
                                                      onChangeStart: (val) {
                                                        _isDragging = true;
                                                      },
                                                      onChanged: (val) {
                                                        final d = Duration(
                                                            seconds:
                                                                val.toInt());
                                                        _currentPosition = d;
                                                        _positionNotifier
                                                            .value = d;
                                                      },
                                                      onChangeEnd: (val) {
                                                        _isDragging = false;
                                                        _seekTo(Duration(
                                                            seconds:
                                                                val.toInt()));
                                                        _syncMediaSessionPlaybackState();
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          );
                                        },
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
                                          width: wide ? 48 : 40,
                                          height: wide ? 48 : 40,
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
                                                  size: wide ? 34 : 24,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        SizedBox(width: wide ? 4 : 2),
                                        // Volume button + expandable slider:
                                        // the desktop app's only. A phone
                                        // has its own volume buttons.
                                        if (isComputer)
                                        MouseRegion(
                                          onEnter: (_) => setState(
                                              () => _volumeHover = true),
                                          onExit: (_) => setState(
                                              () => _volumeHover = false),
                                          child: ValueListenableBuilder<double>(
                                            valueListenable: _volumeNotifier,
                                            builder: (context, volume, _) {
                                              final showSlider = _volumeHover ||
                                                  _volumeDragging ||
                                                  _volumeRecentlyAdjusted;
                                              return Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  SizedBox(
                                                    width: wide ? 44 : 38,
                                                    height: wide ? 44 : 38,
                                                    child: IconButton(
                                                      onPressed: () =>
                                                          _toggleMute(),
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                      padding: EdgeInsets.zero,
                                                      icon: Icon(
                                                        _volumeIconFor(volume),
                                                        color: Colors.white,
                                                        size: wide ? 28 : 22,
                                                      ),
                                                    ),
                                                  ),
                                                  AnimatedContainer(
                                                    duration: const Duration(
                                                        milliseconds: 200),
                                                    curve: Curves.easeOutCubic,
                                                    width: showSlider
                                                        ? (wide ? 104 : 84)
                                                        : 0,
                                                    child: ClipRect(
                                                      child: SliderTheme(
                                                        data: SliderThemeData(
                                                          trackHeight:
                                                              wide ? 4 : 3,
                                                          activeTrackColor:
                                                              Colors.white,
                                                          inactiveTrackColor:
                                                              Colors.white
                                                                  .withValues(
                                                                      alpha:
                                                                          0.24),
                                                          thumbColor:
                                                              Colors.white,
                                                          thumbShape:
                                                              RoundSliderThumbShape(
                                                            enabledThumbRadius:
                                                                wide ? 6.5 : 5,
                                                            elevation: 0,
                                                            pressedElevation: 0,
                                                          ),
                                                          overlayShape:
                                                              RoundSliderOverlayShape(
                                                            overlayRadius:
                                                                wide ? 13 : 11,
                                                          ),
                                                          overlayColor: Colors
                                                              .white
                                                              .withValues(
                                                                  alpha: 0.12),
                                                        ),
                                                        child: Slider(
                                                          value: volume,
                                                          min: 0.0,
                                                          max: 100.0,
                                                          onChangeStart: (_) {
                                                            setState(() =>
                                                                _volumeDragging =
                                                                    true);
                                                          },
                                                          onChanged: (val) {
                                                            _setVolume(
                                                              val,
                                                              persist: false,
                                                            );
                                                          },
                                                          onChangeEnd: (val) {
                                                            setState(() =>
                                                                _volumeDragging =
                                                                    false);
                                                            _setVolume(
                                                              val,
                                                              showSlider: true,
                                                            );
                                                          },
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                        if (isComputer)
                                          SizedBox(width: wide ? 8 : 4),
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
                                                style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: wide ? 15 : 12,
                                                    fontWeight: FontWeight.w600),
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                '/ ${_formatDuration(_durationNotifier.value)}',
                                                style: TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: wide ? 15 : 12,
                                                    fontWeight:
                                                        FontWeight.w500),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // The buttons, at the right: shrunk
                                        // to fit when the window's too
                                        // narrow for them (a computer's
                                        // window made phone-narrow overflowed
                                        // by 108px).
                                        Expanded(
                                          child: Align(
                                            alignment: Alignment.centerRight,
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerRight,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                              if (wide) ...[
                                                _menuButton(GlassPillButton(
                                                  grouped: true,
                                                  key: _qualityButtonKey,
                                                  icon: Icons.hd_rounded,
                                                  label: 'Quality',
                                                  selected: _menuOpen('quality'),
                                                  onPressed: () =>
                                                      _toggleSettingsPanel(
                                                          'quality',
                                                          _qualityButtonKey),
                                                )),
                                                // English or the original, for a
                                                // title not made in English.
                                                if (AudioLanguageService.appliesTo(
                                                    widget.details)) ...[
                                                  const SizedBox(width: 10),
                                                  _menuButton(GlassPillButton(
                                                    grouped: true,
                                                    key: _audioButtonKey,
                                                    icon: Icons
                                                        .record_voice_over_rounded,
                                                    label: 'Audio',
                                                    selected: _menuOpen('audio'),
                                                    busy: _changingAudio,
                                                    onPressed: () =>
                                                        _toggleSettingsPanel(
                                                            'audio',
                                                            _audioButtonKey),
                                                  )),
                                                ],
                                                const SizedBox(width: 10),
                                                _menuButton(GlassPillButton(
                                                  grouped: true,
                                                  key: _subtitlesButtonKey,
                                                  icon: Icons.subtitles_rounded,
                                                  label: _subtitlesSyncing ? 'Syncing…' : 'Subtitles',
                                                  selected: _menuOpen('subtitles'),
                                                  busy: _subtitlesSyncing,
                                                  onPressed: () =>
                                                      _toggleSettingsPanel(
                                                          'subtitles',
                                                          _subtitlesButtonKey),
                                                )),
                                                const SizedBox(width: 10),
                                                _menuButton(GlassPillButton(
                                                  grouped: true,
                                                  key: _videoSizeButtonKey,
                                                  icon: _videoFit.icon,
                                                  label: 'Video Size',
                                                  selected: _menuOpen('videoSize'),
                                                  onPressed: () =>
                                                      _toggleSettingsPanel(
                                                          'videoSize',
                                                          _videoSizeButtonKey),
                                                )),
                                              ] else
                                                // Settings — quality, subtitles and
                                                // video size
                                                _menuButton(GlassPillButton(
                                                  grouped: true,
                                                  key: _settingsButtonKey,
                                                  // Syncing: what's being synced.
                                                  icon: _subtitlesSyncing
                                                      ? Icons.subtitles_rounded
                                                      : Icons.tune_rounded,
                                                  label: _subtitlesSyncing ? 'Syncing…' : 'Settings',
                                                  // Subtitles are in here.
                                                  busy: _subtitlesSyncing,
                                                  selected: _menuOpen('main'),
                                                  onPressed: () =>
                                                      _toggleSettingsPanel(
                                                          'main', _settingsButtonKey),
                                                )),
                                              if (widget.details.type == 'tv') ...[
                                                const SizedBox(width: 10),
                                                // In the panel's group: its own
                                                // press toggles it, rather than
                                                // counting as a click outside.
                                                TapRegion(
                                                  groupId:
                                                      EpisodeBrowser.panelTapGroup,
                                                  child: GlassPillButton(
                                                    grouped: true,
                                                    icon: Icons.grid_view_rounded,
                                                    label: 'Episodes',
                                                    selected: _showEpisodeDrawer,
                                                    onPressed: _toggleEpisodeBrowser,
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                GlassPillButton(
                                                  grouped: true,
                                                  icon: Icons.skip_next_rounded,
                                                  label: 'Next',
                                                  onPressed: nextEpisodePlayable
                                                      ? _playNextEpisode
                                                      : null,
                                                ),
                                              ],
                                              if (WindowFullScreen.supported) ...[
                                                const SizedBox(width: 10),
                                                ValueListenableBuilder<bool>(
                                                  valueListenable:
                                                      WindowFullScreen.state,
                                                  builder: (context, isFullScreen, _) =>
                                                      GlassCircleButton(
                                                    grouped: true,
                                                    icon: isFullScreen
                                                        ? Icons.fullscreen_exit_rounded
                                                        : Icons.fullscreen_rounded,
                                                    iconSize: wide ? 24 : 20,
                                                    dimension: wide ? 42 : 34,
                                                    onPressed: () {
                                                      _resetControlsTimer();
                                                      WindowFullScreen.toggle();
                                                    },
                                                  ),
                                                ),
                                              ],
                                                ],
                                              ),
                                            ),
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

                  // "Subtitles synced" for a moment when syncing moved
                  // them (see _showSyncedBadge) — under "Resumed from" if
                  // that's up too.
                  _glassBadge(
                    top: 16 + safe.top + (_resumeBadge != null ? 44 : 0),
                    visible: _syncedBadge && !_speedBoost,
                    children: const [
                      Icon(Icons.subtitles_rounded, color: Colors.white, size: 16),
                      SizedBox(width: 6),
                      Text('Subtitles synced', style: _badgeTextStyle),
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

                  // "Skip Intro" / "Skip Recap" / "Skip Credits" floating
                  // pill — remains visible even when the main controls hide,
                  // shifting up smoothly when the bottom control bar is shown.
                  // At an episode's end, in its place: Watch Credits and
                  // Next Episode, filling to play it (see _updateUpNext).
                  ListenableBuilder(
                    listenable: Listenable.merge(
                        [_activeSkipSegmentNotifier, _upNextShown]),
                    builder: (context, _) {
                      final segment = _activeSkipSegmentNotifier.value;
                      final upNext = _upNextShown.value;
                      final visible = (segment != null || upNext) &&
                          !_loadingVideo &&
                          !_showEpisodeDrawer &&
                          !_showSettingsPanel;
                      final bottomOffset = (_controlsVisible
                              ? (wide ? 128.0 : 104.0)
                              : (wide ? 36.0 : 24.0)) +
                          MediaQuery.of(context).padding.bottom;
                      return AnimatedPositioned(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        right: (wide ? 32 : 24) + safe.right,
                        bottom: bottomOffset,
                        child: IgnorePointer(
                          ignoring: !visible,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            opacity: visible ? 1.0 : 0.0,
                            child: Listener(
                              onPointerDown: _markControlsPointer,
                              child: upNext
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        GlassPillButton(
                                          grouped: true,
                                          label: 'Watch Credits',
                                          onPressed: _watchCredits,
                                        ),
                                        const SizedBox(width: 10),
                                        GlassPillButton(
                                          grouped: true,
                                          icon: Icons.skip_next_rounded,
                                          label: 'Next Episode',
                                          progress: _upNextFill,
                                          onPressed: _playNextFromUpNext,
                                        ),
                                      ],
                                    )
                                  : GlassPillButton(
                                      grouped: true,
                                      icon: Icons.skip_next_rounded,
                                      label: segment?.type.buttonLabel ??
                                          'Skip Intro',
                                      onPressed: segment == null
                                          ? null
                                          : () => _skipActiveSegment(segment),
                                    ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            // Layer 2: Episode Browser (outside overlay) — stays mounted
            // through the slide-down animation (see _episodeDrawerMounted's
            // doc), rather than disappearing the instant a close is
            // requested.
            if (_episodeDrawerMounted && widget.movie.type == 'tv')
              ..._episodeBrowserLayer(context),

            // Layer 3: Unified Settings Panel (outside overlay)
            if (_showSettingsPanel)
              Positioned.fill(
                // Its own key, as the episode browser's layer has: matched
                // by position instead, the popup was taken for the browser's
                // layer as that went (its slide-out done, just after a click
                // outside it opened the popup) and built afresh — opening
                // twice.
                key: const ValueKey('settings-popup-layer'),
                child: PlayerSettingsPanel(
                  // Fresh for each menu, so switching straight to another
                  // (see _toggleSettingsPanel) opens that one, by its button.
                  key: ValueKey(_settingsPanelInitialView),
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
                  audioTitle: AudioLanguageService.appliesTo(widget.details)
                      ? widget.details
                      : null,
                  onAudioLanguageSelected: _setAudioLanguage,
                  audioChanging: _changingAudio,
                  subtitleDelaySeconds: _subtitleDelaySeconds,
                  onSubtitleDelayChanged: _setSubtitleDelay,
                  subtitleSpeed: _subtitleSpeed,
                  onSubtitleSpeedChanged: _setSubtitleSpeed,
                  subtitleSyncNote: _subtitleSyncNote,
                  subtitleSyncing: _subtitlesSyncing,
                  anchorCenterX: _settingsPanelAnchorX,
                  initialView: _settingsPanelInitialView,
                  closeRequests: _settingsCloseRequests,
                  // Level with the episode panel's foot on a wide window.
                  bottom: playerIsWide(context)
                      ? _bottomBarClearance(MediaQuery.sizeOf(context))
                      : null,
                  onClose: () {
                    setState(() {
                      _showSettingsPanel = false;
                      if (!player.state.playing) {
                        _controlsVisible = true;
                      }
                    });
                    // The controls hide again in a moment, as after any
                    // other control's use.
                    _resetControlsTimer();
                  },
                ),
              ),
          ],
        ),
        ),
      ),
      ),
    );
  }
}

/// Custom seek-bar track shape that partitions the timeline by embedded MKV
/// chapters and skip segments (`Intro`, `Recap`, `Credits`, `Preview`), with
/// YouTube-style 2.5px gaps between partitions, a slight height expansion on
/// the hovered partition, and a subtle warm highlight on skippable ranges.
class _PartitionedSliderTrackShape extends RoundedRectSliderTrackShape {
  final List<double> partitions;
  final List<({double start, double end})> skipRanges;
  final double? hoveredFraction;

  const _PartitionedSliderTrackShape({
    this.partitions = const [],
    this.skipRanges = const [],
    this.hoveredFraction,
  });

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4.0;
    if (trackHeight <= 0) return;

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.width <= 0) return;

    final canvas = context.canvas;
    final activePaint = Paint()
      ..color = sliderTheme.activeTrackColor ?? Colors.white;
    final secondaryPaint = Paint()
      ..color = sliderTheme.secondaryActiveTrackColor ?? Colors.white30;
    final inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? Colors.white12;
    // Skippable segments (Intro / Recap / Credits) get a subtle warm gold/amber
    // tint over their unplayed portion so you can spot them at a glance.
    final skipPaint = Paint()
      ..color = const Color(0xFFFFD54F).withValues(alpha: 0.45);

    final boundaries = <double>[0.0, ...partitions, 1.0];
    final gapHalf = partitions.isEmpty ? 0.0 : 1.25;
    final thumbX = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final bufferX = (secondaryOffset?.dx ?? trackRect.left)
        .clamp(trackRect.left, trackRect.right);

    for (var i = 0; i < boundaries.length - 1; i++) {
      final fStart = boundaries[i];
      final fEnd = boundaries[i + 1];
      var segLeft = trackRect.left +
          fStart * trackRect.width +
          (i > 0 ? gapHalf : 0.0);
      var segRight = trackRect.left +
          fEnd * trackRect.width -
          (i < boundaries.length - 2 ? gapHalf : 0.0);
      if (segRight <= segLeft) continue;

      final isHovered = hoveredFraction != null &&
          hoveredFraction! >= fStart &&
          (i == boundaries.length - 2
              ? hoveredFraction! <= fEnd
              : hoveredFraction! < fEnd);

      final vExpand = isHovered ? 1.5 : 0.0;
      final segTop = trackRect.top - vExpand;
      final segBottom = trackRect.bottom + vExpand;
      final radius = Radius.circular((segBottom - segTop) / 2);
      final segRRect = RRect.fromLTRBR(
        segLeft,
        segTop,
        segRight,
        segBottom,
        radius,
      );

      canvas.save();
      canvas.clipRRect(segRRect);

      // 1. Base inactive background for the partition
      canvas.drawRect(
        Rect.fromLTRB(segLeft, segTop, segRight, segBottom),
        inactivePaint,
      );

      // 2. Buffered (secondary) fill
      if (bufferX > segLeft) {
        final bufRight = math.min(segRight, bufferX);
        canvas.drawRect(
          Rect.fromLTRB(segLeft, segTop, bufRight, segBottom),
          secondaryPaint,
        );
      }

      // 3. Skippable segment highlight (Intro / Recap / Credits / Preview)
      for (final sr in skipRanges) {
        final srLeft =
            math.max(segLeft, trackRect.left + sr.start * trackRect.width);
        final srRight =
            math.min(segRight, trackRect.left + sr.end * trackRect.width);
        if (srRight > srLeft) {
          canvas.drawRect(
            Rect.fromLTRB(srLeft, segTop, srRight, segBottom),
            skipPaint,
          );
        }
      }

      // 4. Active played progress fill
      if (thumbX > segLeft) {
        final actRight = math.min(segRight, thumbX);
        canvas.drawRect(
          Rect.fromLTRB(segLeft, segTop, actRight, segBottom),
          activePaint,
        );
      }

      canvas.restore();
    }
  }
}


