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
import 'package:path_provider/path_provider.dart';
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
import '../services/tv_device.dart';
import '../services/landscape_side.dart';
import '../widgets/tv_focus.dart';
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
import '../services/subtitle_translator.dart';
import '../services/episode_numbering.dart';
import '../services/gemini_key_service.dart';
import '../widgets/gemini_key_form.dart';
import '../services/subtitle_retime.dart';
import '../services/subtitle_sync.dart';
import '../services/window_full_screen.dart';
import '../services/sync/sync_ledger.dart';

part 'player/streaming.dart';
part 'player/subtitles.dart';
part 'player/episodes.dart';
part 'player/controls.dart';
part 'player/skip_intro.dart';
part 'player/sound.dart';

/// No copy of an episode in the language it plays in: it isn't played in
/// another (see StreamResolver.getAvailableStreams).
class _NotInLanguageException implements Exception {
  final String language;
  const _NotInLanguageException(this.language);
}

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
    this.rememberedCopy = false,
  });

  /// [selectedStream] is the copy this title (or episode) last played —
  /// here or, synced, on another device — whose progress lands on the
  /// same moment: it's given longer to start before another is tried
  /// (see _openingDataWaitRemembered).
  final bool rememberedCopy;

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

  // A TV remote (see _onTvKey): the player itself, selected while none of
  // its buttons is, and the play button, where the remote lands on them.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'Player');
  final FocusNode _playButtonFocus = FocusNode(debugLabel: 'Play/pause');

  // On a TV, the seek bar can be selected (up from the buttons), and OK
  // there selects its pointer: then left and right move it, OK plays from
  // there and Back puts it back (see _onTvScrubKey). The spot it's moved
  // to while selected, or null.
  final FocusNode _seekBarFocus = FocusNode(debugLabel: 'Seek bar');
  final ValueNotifier<Duration?> _tvScrubTarget = ValueNotifier(null);
  DateTime? _tvScrubHeldSince;
  DateTime? _tvScrubLastMove;
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

  /// Which of up next's stages is showing (see UpNextPlan).
  final ValueNotifier<UpNextStage> _upNextStage =
      ValueNotifier(UpNextStage.none);

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

  /// Reconnecting after a stall: shown as a tag at the top, as "Resumed
  /// from", with the video left as it is — not the switching cover and
  /// spinner over the picture, nor the controls brought up.
  bool _reconnecting = false;

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

  /// Subtitles (ids) found not to fit this video — their length, or no
  /// match with the speech (see _tryAnotherSubtitle) — and those whose
  /// length has been checked (see _checkSubtitleFits).
  final Set<String> _rejectedSubtitles = {};
  final Set<String> _fitChecked = {};
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

  // Sinhala subtitles being made from English ones (SubtitleTranslator),
  // and the English track's id they're made from.
  SinhalaSubtitles? _sinhala;
  String? _sinhalaFrom;
  Future<SinhalaSubtitles?>? _sinhalaStarting;
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

  /// Paused by the viewer — space, a click, the button, a media key —
  /// while loading too: kept when the video's ready, and through a switch
  /// of copy, so it waits for them (see _checkReadyWhilePaused).
  bool _heldByViewer = false;

  /// Where the video being opened is to start, as a share of it (from the
  /// saved progress) or a spot: until it's there, being "ready" means
  /// nothing (see _checkReadyWhilePaused).
  double? _openingStartShare;
  Duration? _openingStartAt;
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
  // On a TV, a seek or stall gone on long enough to notice: its spinner
  // in the middle, the controls staying away (see _revealWait).
  bool _tvWaitShown = false;
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
  // While opening, a copy that has still delivered less than
  // [_openingMinBytes] after [_openingDataWait] is given up for another of
  // its quality — even if it trickles in now and then, which keeps the
  // rule above from ever firing. (The Mentalist's "328 sharers" pick had
  // no one for 27s, then 20 KB/s: two minutes before it was left.) A
  // healthy one has several MB by then.
  static const Duration _openingDataWait = Duration(seconds: 20);
  // The copy last played (on another device, it has nothing here yet and
  // starts from cold): twice as long, as it's the one whose progress lands
  // on the same moment — another copy may be cut a few seconds apart.
  static const Duration _openingDataWaitRemembered = Duration(seconds: 40);
  // The copy given that longer: the one last played, lowercased.
  late String? _patientHash = widget.rememberedCopy
      ? widget.selectedStream.infoHash.toLowerCase()
      : null;
  static const int _openingMinBytes = 2 * 1024 * 1024;
  // More than a head start's ~6 MB: a copy already downloaded (some way).
  static const int _openingHasDataBytes = 32 * 1024 * 1024;
  // The torrent being opened, how much it had when that was first seen,
  // and when — the baseline for the rule above.
  ({int torrentId, int bytes, DateTime at})? _openingBaseline;
  bool _recoveringStream = false;

  // When playback was last reconnected in place mid-film (see
  // _reconnectInPlace): stuck again soon after, the full recovery runs.
  DateTime? _lastInPlaceReconnectAt;
  static const Duration _inPlaceReconnectHolds = Duration(minutes: 2);

  // The spot the seek bar holds at while the video reopens there after a
  // stall: the reopened file reports 0 at first, and the bar jumped to the
  // start. Cleared once it's playing again.
  Duration? _heldPosition;

  // Where the next file opened starts (mpv's 'start': seconds, "n%", or
  // "0"), set by _openMediaWithResume and given to mpv as the file loads
  // (see _applyLoadStart).
  String _loadStart = '0';

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
  // Never on a TV: its screen doesn't turn, and asking for portrait there
  // shrinks the app to a phone-shaped strip.
  static final _canTurn =
      (Platform.isAndroid || Platform.isIOS) && !TvDevice.isTv;
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

  /// Closes the settings popup, animated (PlayerSettingsPanel.
  /// closeRequests): bumped by its button pressed again, or Esc.
  final ValueNotifier<int> _settingsCloseRequests = ValueNotifier(0);

  static final _urlPattern = RegExp(r'https?://\S+');

  /// Ends _seekPending once playback visibly moves on: two position ticks
  /// in a small forward step while playing — whatever spot it landed on.
  /// Ticks from just after the seek was asked for are skipped (they can
  /// still be the old position playing on); while paused, any later tick
  /// means it's arrived. Gives up after [_seekRingLimit] whatever happens
  /// — a seek that never gets going is the stall watchdog's business.
  static const _seekRingLimit = Duration(seconds: 20);

  /// Ticks every 5s (see [_stallWatchdogTimer]). If both playback position
  /// and real torrent download bytes stay completely flat for
  /// [_stallTicksThreshold] consecutive ticks while we're supposed to be
  /// actively playing, treats it as a stuck stream and attempts recovery.
  /// Requiring *both* to be flat (not just position) avoids false-triggering
  /// on a decoder-side hiccup that has nothing to do with missing torrent
  /// data — wiping and re-downloading wouldn't fix that anyway.
  /// A download at least this fast is making progress, finished pieces or
  /// not (see _checkForStall).
  static const int _stillReceivingBytesPerSecond = 8 * 1024;

  /// Recovers from a stalled/stuck stream: wipes this torrent's cached save
  /// directory (the same operation Settings > Storage's manual "Delete"
  /// performs — see TorrentStorageService.deleteByInfoHash) and re-resolves
  /// a fresh stream, falling back to a different source if this exact one
  /// keeps failing. Previously this required the user to notice playback
  /// had died, back out to Settings, and delete the cached file by hand;
  /// this does the same thing automatically, in place.
  // ── The copy's length (see _checkLength) ──

  Timer? _lengthCheckTimer;
  // The copy whose length has been checked.
  String? _lengthCheckedHash;
  // Copies left this session for their length. A third in a row, and it's
  // the film's listed length that's off rather than the copies: that one
  // plays, and none of them count as wrong.
  final List<String> _wrongLengthHashes = [];
  bool _lengthCheckOff = false;

  // ── The copy's soundtracks (see _checkAudio) ──

  Timer? _audioCheckTimer;
  // The copy, and the language, whose soundtracks have been checked.
  String? _audioCheckedFor;

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

  /// The video, for moving its subtitles above the controls (see
  /// _placeSubtitles).
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  /// The subtitles' space below them now, so they're moved only on a
  /// change.
  double _subtitleBottom = 24;

  /// Whether the last click landed in [_inBottomBand] (so a double-click
  /// there doesn't toggle full screen either).
  bool _lastTapInBottomBand = false;

  static const _badgeTextStyle = TextStyle(
    color: Colors.white,
    fontSize: 13,
    fontWeight: FontWeight.w700,
  );

  // Press-and-hold on the video plays at 2× until the finger lifts
  // (PlayerGestureOverlay.onHoldStart / onHoldEnd), with a badge saying so.
  bool _speedBoost = false;

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

  /// Audio languages with no copy of what's playing (see
  /// _checkAudioLanguages): greyed out in the Audio menu.
  Set<AudioLanguage> _noAudioIn = const {};

  /// Whether a change of audio language is being carried out (finding a
  /// copy with it): the choice can't be changed again meanwhile.
  bool _changingAudio = false;

  // When a click outside the side panel last closed it (see
  // _dismissEpisodePanel): that click, let go of on the video, mustn't
  // also play or pause it (_onScreenTap).
  DateTime? _episodePanelDismissedAt;

  // The next season's episodes, looked up while the last episode of this
  // one plays (see _loadNextSeason): Next Episode goes on into it — Ghosts'
  // season 1 finale offered nothing, or Next did nothing.
  int? _nextSeasonNumber;
  List<Episode> _nextSeasonEpisodes = const [];
  // The season the next one was looked up from, so it's done once.
  int? _nextSeasonLookedUpFrom;
  bool _nextSeasonLoading = false;
  // After a failed lookup: not tried again before this.
  DateTime? _nextSeasonRetryAt;

  // The next episode, readied near the end of this one (see
  // _maybeReadyNextEpisode): which one, its torrents (_playEpisode uses
  // them rather than looking them up again), and its head start's.
  ({
    int season,
    int episode,
    Future<List<TorrentStream>> streams
  })? _readiedNext;
  List<TorrentStream> _nextHeadStart = const [];
  // The episode ("season:episode") the next one was readied from, so it's
  // done once per episode.
  String? _readiedFrom;

  // The stream fingerprinted for subtitles already (see
  // _fingerprintSubtitles): once per video.
  String? _fingerprinted;

  // ─── Sinhala subtitles, made from English ones (SubtitleTranslator) ───

  /// Languages Sinhala is made from when there are no English subtitles
  /// (nor ones in the title's own language), most used first.
  static const _otherSources = [
    'Japanese',
    'Korean',
    'Chinese',
    'Hindi',
    'Tamil',
    'Malayalam',
    'Telugu',
    'Kannada',
    'Bengali',
    'Spanish',
    'French',
    'German',
    'Italian',
    'Portuguese',
    'Portuguese (Brazil)',
    'Russian',
    'Arabic',
    'Turkish',
    'Indonesian',
    'Thai',
    'Vietnamese',
  ];

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

  /// The buffered video ahead of the position that auto sync waits for
  /// before starting its second player (see _maybeAutoSync).
  static const Duration _autoSyncMinLead = Duration(seconds: 30);

  // One client for every subtitle download, with timeouts: a new one per
  // call had none, so a dead server hung the sync.
  static final Dio _subtitleDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  // The last "[skip]" line logged, so it's logged only when it changes.
  String? _lastSkipLog;

  // The seek bar's skip ranges and partition gaps, worked out when the
  // segments or the duration change rather than on every rebuild of the bar.
  List<({double start, double end})> _skipRanges = const [];
  List<double> _partitions = const [];

  /// The most chapters drawn as gaps on the seek bar (see
  /// _partitionFractionsFor).
  static const _maxChapterGaps = 8;

  // Skip targets readied for this video (seconds), once each.
  final Set<int> _readiedSkipTargets = {};

  void _updateState(VoidCallback update) => setState(update);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the screen on for the whole time the player is open, paused or
    // playing — without this, the OS can lock the screen mid-playback (video
    // keeps decoding behind a black/locked screen) since Flutter doesn't
    // request a wakelock on its own. Released in dispose.
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

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    if (TvDevice.isTv) return _onTvKey(event);
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
      // While loading too: paused then, it waits once it's ready.
      if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
        if (!_episodeCoversVideo) {
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

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _discardRetimedFiles();
    _stopSinhala();
    WakelockPlus.disable();
    _rootFocus.dispose();
    _playButtonFocus.dispose();
    _seekBarFocus.dispose();
    _tvScrubTarget.dispose();
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
      if (_canTurn) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
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
        totalBytes: finalTorrentInfo.totalWanted > 0
            ? finalTorrentInfo.totalWanted
            : null,
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
    _lengthCheckTimer?.cancel();
    _audioCheckTimer?.cancel();
    _resumeBadgeTimer?.cancel();
    _syncedBadgeTimer?.cancel();
    _mediaActionSub?.cancel();
    _mediaSession.deactivate();
    _episodeDrawerController.dispose();
    _playPauseFlash.dispose();
    _upNextFill.dispose();
    _upNextShown.dispose();
    _upNextStage.dispose();
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

  /// More lines translated: the player reads the file again, if they're
  /// on screen.
  Future<void> _onSinhalaUpdate() async {
    final job = _sinhala;
    if (!mounted || job == null) return;
    setState(() {}); // The menu's progress.
    if (_selectedSubtitle?.translatedFrom?.id != _sinhalaFrom) return;
    final added = await _addedSubtitleTracks();
    final id = added.entries
        .where((e) => e.value == job.path)
        .map((e) => e.key)
        .firstOrNull;
    if (id == null) return;
    try {
      await (player.platform as NativePlayer).command(['sub-reload', id]);
    } catch (e) {
      print('[sinhala] reload: $e');
    }
  }

  void _onSinhalaProblem() {
    final problem = _sinhala?.problem.value;
    if (problem == null || !mounted) return;
    showAppMessage(context, problem, error: true);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Once laid out: the subtitles above the controls, or at the foot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _placeSubtitles();
    });
    final size = MediaQuery.of(context).size;
    final wide = playerIsWide(context);
    // Camera cutout (punch hole / notch) — the video draws under it (see
    // MainActivity), but the controls stay clear of it.
    final safe = MediaQuery.of(context).padding;
    // This season's next, or the next season's first (see _nextUp), once
    // it's out.
    final nextForButton = widget.details.type == 'tv' ? _nextEpisode : null;
    final nextEpisodePlayable =
        nextForButton != null && !nextForButton.isUnreleased;

    return PopScope(
      // Back closes a panel, or else the player — via _close, to turn the
      // phone back first.
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        // On a TV: the seek bar's pointer goes back first (see
        // _onTvScrubKey).
        if (_tvScrubTarget.value != null) {
          _cancelTvScrub();
          return;
        }
        // On a TV: a menu open in a panel (the episodes' season menu)
        // closes first (TvBack).
        if (TvBack.handle()) return;
        if (_showEpisodeDrawer) {
          _closeEpisodeBrowser();
        } else if (_showSettingsPanel) {
          setState(() {
            _showSettingsPanel = false;
            if (!player.state.playing) {
              _controlsVisible = true;
            }
          });
        } else if (TvDevice.isTv &&
            _controlsVisible &&
            _isPlaying &&
            !_loadingVideo) {
          // On a TV, Back puts the controls away before it leaves.
          _controlsTimer?.cancel();
          setState(() => _controlsVisible = false);
          _rootFocus.requestFocus();
        } else {
          _close();
        }
      },
      child: _closing
          ? const ColoredBox(color: Colors.black)
          : Focus(
              focusNode: _rootFocus,
              autofocus: true,
              onKeyEvent: _onRootKey,
              // Keys are the player's own (_onHardwareKey), not its
              // buttons' — except on a TV, where the remote moves between
              // them while they're showing (see _onTvKey).
              descendantsAreFocusable: TvDevice.isTv &&
                  (_controlsVisible ||
                      _showSettingsPanel ||
                      _showEpisodeDrawer),
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
                                if (_lastTapInBottomBand ||
                                    _pointerWasOnControls) {
                                  return;
                                }
                                WindowFullScreen.toggle();
                              }
                            : null,
                        onSwipeUp: widget.movie.type == 'tv'
                            ? _openEpisodeBrowser
                            : null,
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
                                    key: _videoKey,
                                    controller: controller,
                                    // media_kit's own look, with a font for Sinhala
                                    // (subtitles made from English: SubtitleTranslator),
                                    // bigger: see _subtitleScaler.
                                    subtitleViewConfiguration:
                                        SubtitleViewConfiguration(
                                      textScaler: _subtitleScaler(context),
                                      style: TextStyle(
                                        // Sinhala in its own font throughout,
                                        // spaces and commas too: switching
                                        // fonts between words left gaps in
                                        // the black behind the line.
                                        fontFamily: _selectedSubtitle != null &&
                                                _getLanguageName(
                                                        _selectedSubtitle!
                                                            .lang) ==
                                                    'Sinhala'
                                            ? 'NotoSansSinhala'
                                            : null,
                                        height: 1.4,
                                        fontSize: 38.0,
                                        letterSpacing: 0.0,
                                        wordSpacing: 0.0,
                                        // Out of sight while paused: clear,
                                        // not removed, so the line on
                                        // screen comes back with play.
                                        color: _isPlaying
                                            ? const Color(0xffffffff)
                                            : Colors.transparent,
                                        // A touch heavier on a TV: thin
                                        // strokes blur from across a room.
                                        fontWeight: TvDevice.isTv
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                        backgroundColor: _isPlaying
                                            ? const Color(0xaa000000)
                                            : Colors.transparent,
                                        fontFamilyFallback: ['NotoSansSinhala'],
                                      ),
                                    ),
                                    controls:
                                        NoVideoControls, // Pure custom controls overlay
                                    fit: _videoFit.boxFit,
                                    width: double.infinity,
                                    height: double.infinity,
                                  ),
                                ),
                              ),
                            ),

                            // On a TV, a wait the controls don't show (see
                            // _revealWait).
                            if (TvDevice.isTv &&
                                _tvWaitShown &&
                                !_controlsVisible &&
                                (_seekPending || _isBuffering))
                              const IgnorePointer(
                                child: Center(
                                  child: SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: Colors.white,
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
                                      color:
                                          Colors.black.withValues(alpha: 0.45),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(_flashIcon,
                                        color: Colors.white,
                                        size: wide ? 56 : 48),
                                  ),
                                ),
                              ),
                            ),

                            // Switching (quality, episode, season, recovery): the
                            // video stays visible, softly darkened, under a small
                            // spinner and one quiet line.
                            if ((_switchingQuality && !_reconnecting) ||
                                _loadingSeason)
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
                                            Colors.black.withOpacity(
                                                _isPlaying ? 0.8 : 0.92),
                                          ],
                                          stops: const [0.0, 0.18, 0.6, 1.0],
                                        ),
                                      ),
                                    ),

                                    // When paused: left-side cinematic gradient for metadata (animates in/out)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: AnimatedOpacity(
                                          duration:
                                              const Duration(milliseconds: 350),
                                          opacity: !_isPlaying ? 1.0 : 0.0,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.centerLeft,
                                                end: Alignment.centerRight,
                                                colors: [
                                                  Colors.black
                                                      .withOpacity(0.85),
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
                                                child: TweenAnimationBuilder<
                                                    double>(
                                                  tween: Tween<double>(
                                                      end: _isPlaying
                                                          ? 1.0
                                                          : 0.0),
                                                  duration: const Duration(
                                                      milliseconds: 300),
                                                  builder:
                                                      (context, reveal, _) =>
                                                          GlassBubbleBar(
                                                    reveal: reveal,
                                                    leading: CircleAvatar(
                                                      backgroundColor:
                                                          Colors.transparent,
                                                      child: IconButton(
                                                        icon: const Icon(
                                                          GlassCircleButton
                                                              .backIcon,
                                                          color: Colors.white,
                                                        ),
                                                        tooltip:
                                                            MaterialLocalizations
                                                                    .of(context)
                                                                .backButtonTooltip,
                                                        onPressed: () =>
                                                            Navigator.maybePop(
                                                                context),
                                                        iconSize: wide
                                                            ? 28
                                                            : GlassCircleButton
                                                                .backIconSize,
                                                        padding:
                                                            EdgeInsets.zero,
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
                                              padding: const EdgeInsets.only(
                                                  right: 12),
                                              child: ValueListenableBuilder<
                                                  double>(
                                                valueListenable:
                                                    _downloadSpeedNotifier,
                                                builder: (context, speed, _) =>
                                                    Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                        Icons
                                                            .arrow_downward_rounded,
                                                        color: Colors.white38,
                                                        size: wide ? 15 : 12),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      '${speed.toStringAsFixed(1)} MB/s',
                                                      style: TextStyle(
                                                          color: Colors.white54,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                          fontSize:
                                                              wide ? 13.5 : 11),
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
                                            duration: const Duration(
                                                milliseconds: 350),
                                            opacity: (!_isPlaying &&
                                                    _controlsVisible)
                                                ? 1.0
                                                : 0.0,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                // Title or Logo
                                                if (widget.details.logoUrl !=
                                                        null &&
                                                    widget.details.logoUrl!
                                                        .isNotEmpty)
                                                  Padding(
                                                    padding: EdgeInsets.only(
                                                        bottom: wide ? 10 : 6),
                                                    child: CachedNetworkImage(
                                                      imageUrl: widget
                                                          .details.logoUrl!,
                                                      height: wide ? 120 : 64,
                                                      fit: BoxFit.contain,
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      errorWidget: (context,
                                                          url, error) {
                                                        return Text(
                                                          widget.movie.title,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontSize:
                                                                wide ? 38 : 22,
                                                            fontWeight:
                                                                FontWeight.w800,
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
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: wide ? 38 : 22,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      height: 1.15,
                                                    ),
                                                  ),
                                                // TV episode info, in the episode cards'
                                                // style: a small "S1 · E3" label over the
                                                // episode's name.
                                                if (widget.details.type ==
                                                        'tv' &&
                                                    _currentEpisode !=
                                                        null) ...[
                                                  SizedBox(
                                                      height: wide ? 16 : 10),
                                                  Text(
                                                    'S$_currentSeason · E$_currentEpisode',
                                                    style: TextStyle(
                                                      color: Colors.white54,
                                                      fontSize: wide ? 16 : 12,
                                                      height: 1.2,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      letterSpacing: 0.5,
                                                    ),
                                                  ),
                                                  if (_playingEpisode?.name
                                                      case final name?
                                                      when name.isNotEmpty) ...[
                                                    SizedBox(
                                                        height: wide ? 4 : 2),
                                                    Text(
                                                      name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize:
                                                            wide ? 24 : 15,
                                                        height: 1.25,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                                SizedBox(
                                                    height: wide ? 14 : 10),
                                                // Description
                                                Text(
                                                  (_playingEpisode?.overview ??
                                                              '')
                                                          .isNotEmpty
                                                      ? _playingEpisode!
                                                          .overview
                                                      : widget
                                                          .movie.description,
                                                  maxLines: wide ? 4 : 3,
                                                  overflow:
                                                      TextOverflow.ellipsis,
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
                                                _tvScrubTarget,
                                              ]),
                                              builder: (context, _) {
                                                final dur =
                                                    _durationNotifier.value;
                                                final totalSeconds =
                                                    dur.inSeconds.toDouble();
                                                final hoverFraction =
                                                    _seekHoverFractionNotifier
                                                        .value;
                                                final dragFraction =
                                                    (_isDragging &&
                                                            totalSeconds > 0)
                                                        ? (_positionNotifier
                                                                    .value
                                                                    .inSeconds /
                                                                totalSeconds)
                                                            .clamp(0.0, 1.0)
                                                        : null;
                                                // A TV's seek pointer, moved (see
                                                // _onTvScrubKey).
                                                final scrubTarget =
                                                    _tvScrubTarget.value;
                                                final scrubbing =
                                                    scrubTarget != null &&
                                                        totalSeconds > 0;
                                                final scrubFraction = scrubbing
                                                    ? (scrubTarget.inSeconds /
                                                            totalSeconds)
                                                        .clamp(0.0, 1.0)
                                                    : null;
                                                final activeFraction =
                                                    scrubFraction ??
                                                        dragFraction ??
                                                        hoverFraction;
                                                final showTooltip =
                                                    !_loadingVideo &&
                                                        totalSeconds > 0 &&
                                                        activeFraction != null;
                                                final tooltipDuration =
                                                    showTooltip
                                                        ? Duration(
                                                            seconds: (activeFraction *
                                                                    totalSeconds)
                                                                .round()
                                                                .clamp(0,
                                                                    dur.inSeconds),
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
                                                  builder:
                                                      (context, constraints) {
                                                    final trackWidth = math.max(
                                                      1.0,
                                                      constraints.maxWidth -
                                                          pad * 2,
                                                    );
                                                    final f =
                                                        activeFraction ?? 0.0;
                                                    final targetX =
                                                        pad + f * trackWidth;
                                                    final halfPill =
                                                        tooltipLabel != null
                                                            ? (scrubbing
                                                                ? 140.0
                                                                : 110.0)
                                                            : (scrubbing
                                                                ? 64.0
                                                                : 44.0);
                                                    final barFocused =
                                                        TvDevice.isTv &&
                                                            _seekBarFocus
                                                                .hasFocus;
                                                    final clampedCenter =
                                                        targetX.clamp(
                                                      halfPill,
                                                      math.max(
                                                        halfPill,
                                                        constraints.maxWidth -
                                                            halfPill,
                                                      ),
                                                    );

                                                    // Selectable with a TV remote, up
                                                    // from the buttons (see _onTvKey);
                                                    // the slider itself never is.
                                                    return Focus(
                                                      focusNode: _seekBarFocus,
                                                      canRequestFocus:
                                                          TvDevice.isTv &&
                                                              !_loadingVideo,
                                                      skipTraversal:
                                                          !TvDevice.isTv,
                                                      onFocusChange: (_) =>
                                                          setState(() {}),
                                                      child: Stack(
                                                      clipBehavior: Clip.none,
                                                      children: [
                                                        if (showTooltip)
                                                          Positioned(
                                                            left:
                                                                clampedCenter -
                                                                    halfPill,
                                                            width: halfPill * 2,
                                                            bottom: scrubbing
                                                                ? 44
                                                                : (wide
                                                                    ? 36
                                                                    : 32),
                                                            child:
                                                                IgnorePointer(
                                                              child: Center(
                                                                child: ClipPath(
                                                                  clipper:
                                                                      const ShapeBorderClipper(
                                                                    shape:
                                                                        StadiumBorder(),
                                                                  ),
                                                                  child:
                                                                      GlassBlur(
                                                                    child:
                                                                        DecoratedBox(
                                                                      decoration:
                                                                          ShapeDecoration(
                                                                        color:
                                                                            glassTint(context),
                                                                        shape:
                                                                            StadiumBorder(
                                                                          side:
                                                                              BorderSide(
                                                                            color:
                                                                                kGlassEdge,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                      child:
                                                                          Padding(
                                                                        padding:
                                                                            EdgeInsets.symmetric(
                                                                          horizontal: wide
                                                                              ? 11
                                                                              : 9,
                                                                          vertical: wide
                                                                              ? 5
                                                                              : 4,
                                                                        ),
                                                                        child:
                                                                            Row(
                                                                          mainAxisSize:
                                                                              MainAxisSize.min,
                                                                          children: [
                                                                            Text(
                                                                              _formatDuration(
                                                                                tooltipDuration,
                                                                              ),
                                                                              style: TextStyle(
                                                                                color: Colors.white,
                                                                                fontSize: scrubbing
                                                                                    ? 22
                                                                                    : (wide ? 13 : 11.5),
                                                                                fontWeight: FontWeight.w600,
                                                                                height: 1.1,
                                                                                fontFeatures: const [
                                                                                  FontFeature.tabularFigures(),
                                                                                ],
                                                                              ),
                                                                            ),
                                                                            if (tooltipLabel !=
                                                                                null) ...[
                                                                              Flexible(
                                                                                child: Text(
                                                                                  '  ·  $tooltipLabel',
                                                                                  maxLines: 1,
                                                                                  overflow: TextOverflow.ellipsis,
                                                                                  style: TextStyle(
                                                                                    color: Colors.white70,
                                                                                    fontSize: wide ? 12.5 : 11,
                                                                                    fontWeight: FontWeight.w500,
                                                                                    height: 1.1,
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
                                                            final frac = ((event
                                                                            .localPosition
                                                                            .dx -
                                                                        pad) /
                                                                    trackWidth)
                                                                .clamp(
                                                                    0.0, 1.0);
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
                                                            data:
                                                                SliderThemeData(
                                                              trackHeight: wide
                                                                  ? 4.5
                                                                  : 3,
                                                              trackShape:
                                                                  _PartitionedSliderTrackShape(
                                                                partitions:
                                                                    partitions,
                                                                skipRanges:
                                                                    skipRanges,
                                                                hoveredFraction:
                                                                    activeFraction,
                                                              ),
                                                              activeTrackColor:
                                                                  AppTheme
                                                                      .accent,
                                                              secondaryActiveTrackColor:
                                                                  Colors.white
                                                                      .withValues(
                                                                          alpha:
                                                                              0.3),
                                                              inactiveTrackColor:
                                                                  Colors.white
                                                                      .withValues(
                                                                          alpha:
                                                                              0.15),
                                                              thumbColor:
                                                                  Colors.white,
                                                              thumbShape: RoundSliderThumbShape(
                                                                  enabledThumbRadius:
                                                                      wide
                                                                          ? 7.5
                                                                          : 6,
                                                                  elevation: 0,
                                                                  pressedElevation:
                                                                      0),
                                                              overlayShape:
                                                                  RoundSliderOverlayShape(
                                                                      overlayRadius: wide
                                                                          ? 16
                                                                          : 14),
                                                              overlayColor: Colors
                                                                  .white
                                                                  .withValues(
                                                                      alpha:
                                                                          0.12),
                                                            ),
                                                            // No seeking until the video has
                                                            // loaded (see _loadingVideo).
                                                            child:
                                                                // Not for a TV remote: it took the
                                                                // arrows and kept them. Left and
                                                                // right skip there (see _onTvKey).
                                                                ExcludeFocus(
                                                                    excluding:
                                                                        TvDevice
                                                                            .isTv,
                                                                    child:
                                                                        IgnorePointer(
                                                                      ignoring:
                                                                          _loadingVideo,
                                                                      child:
                                                                          Slider(
                                                                        value: (scrubTarget ??
                                                                                _positionNotifier.value)
                                                                            .inSeconds
                                                                            .toDouble()
                                                                            .clamp(0.0,
                                                                                totalSeconds),
                                                                        secondaryTrackValue: _bufferNotifier
                                                                            .value
                                                                            .inSeconds
                                                                            .toDouble()
                                                                            .clamp(0.0,
                                                                                totalSeconds),
                                                                        min:
                                                                            0.0,
                                                                        max: totalSeconds >
                                                                                0
                                                                            ? totalSeconds
                                                                            : 1.0,
                                                                        onChangeStart:
                                                                            (val) {
                                                                          _isDragging =
                                                                              true;
                                                                        },
                                                                        onChanged:
                                                                            (val) {
                                                                          final d =
                                                                              Duration(seconds: val.toInt());
                                                                          _currentPosition =
                                                                              d;
                                                                          _positionNotifier.value =
                                                                              d;
                                                                        },
                                                                        onChangeEnd:
                                                                            (val) {
                                                                          _isDragging =
                                                                              false;
                                                                          _seekTo(
                                                                              Duration(seconds: val.toInt()));
                                                                          _syncMediaSessionPlaybackState();
                                                                        },
                                                                      ),
                                                                    )),
                                                          ),
                                                        ),
                                                        // The bar selected with a TV
                                                        // remote: outlined, as a button.
                                                        if (barFocused &&
                                                            !scrubbing)
                                                          Positioned(
                                                            left: pad - 12,
                                                            right: pad - 12,
                                                            top: 2,
                                                            bottom: 2,
                                                            child: IgnorePointer(
                                                              child:
                                                                  DecoratedBox(
                                                                decoration:
                                                                    BoxDecoration(
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              999),
                                                                  border: Border.all(
                                                                      color: Colors
                                                                          .white,
                                                                      width: 2.5),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        // Its pointer selected: ringed,
                                                        // an arrow either side.
                                                        if (scrubbing)
                                                          Positioned(
                                                            left: targetX - 52,
                                                            width: 104,
                                                            top: 0,
                                                            bottom: 0,
                                                            child:
                                                                const IgnorePointer(
                                                              child: Row(
                                                                mainAxisAlignment:
                                                                    MainAxisAlignment
                                                                        .center,
                                                                children: [
                                                                  Icon(
                                                                      Icons
                                                                          .arrow_left_rounded,
                                                                      color: Colors
                                                                          .white,
                                                                      size: 30),
                                                                  SizedBox(
                                                                    width: 30,
                                                                    height: 30,
                                                                    child:
                                                                        DecoratedBox(
                                                                      decoration:
                                                                          BoxDecoration(
                                                                        shape: BoxShape
                                                                            .circle,
                                                                        border: Border.fromBorderSide(
                                                                            BorderSide(
                                                                                color: Colors.white,
                                                                                width: 2.5)),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  Icon(
                                                                      Icons
                                                                          .arrow_right_rounded,
                                                                      color: Colors
                                                                          .white,
                                                                      size: 30),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                    );
                                                  },
                                                );
                                              },
                                            ),
                                            // Timestamps + next episode row
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8),
                                              child: Row(
                                                children: [
                                                  // Play / pause, ringed by the loading
                                                  // spinner while opening, buffering or
                                                  // seeking
                                                  SizedBox(
                                                    width: wide ? 48 : 40,
                                                    height: wide ? 48 : 40,
                                                    child: Stack(
                                                      alignment:
                                                          Alignment.center,
                                                      children: [
                                                        if (!_switchingQuality &&
                                                            (_isMediaOpening ||
                                                                _isBuffering ||
                                                                _seekPending))
                                                          const Positioned.fill(
                                                            child:
                                                                CircularProgressIndicator(
                                                              color: Colors
                                                                  .white70,
                                                              strokeWidth: 2,
                                                            ),
                                                          ),
                                                        IconButton(
                                                          focusNode:
                                                              _playButtonFocus,
                                                          onPressed: _playPause,
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          padding:
                                                              EdgeInsets.zero,
                                                          icon: Icon(
                                                            _isPlaying
                                                                ? Icons
                                                                    .pause_rounded
                                                                : Icons
                                                                    .play_arrow_rounded,
                                                            color: Colors.white,
                                                            size:
                                                                wide ? 34 : 24,
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
                                                          () => _volumeHover =
                                                              true),
                                                      onExit: (_) => setState(
                                                          () => _volumeHover =
                                                              false),
                                                      child:
                                                          ValueListenableBuilder<
                                                              double>(
                                                        valueListenable:
                                                            _volumeNotifier,
                                                        builder: (context,
                                                            volume, _) {
                                                          final showSlider =
                                                              _volumeHover ||
                                                                  _volumeDragging ||
                                                                  _volumeRecentlyAdjusted;
                                                          return Row(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              SizedBox(
                                                                width: wide
                                                                    ? 44
                                                                    : 38,
                                                                height: wide
                                                                    ? 44
                                                                    : 38,
                                                                child:
                                                                    IconButton(
                                                                  onPressed: () =>
                                                                      _toggleMute(),
                                                                  visualDensity:
                                                                      VisualDensity
                                                                          .compact,
                                                                  padding:
                                                                      EdgeInsets
                                                                          .zero,
                                                                  icon: Icon(
                                                                    _volumeIconFor(
                                                                        volume),
                                                                    color: Colors
                                                                        .white,
                                                                    size: wide
                                                                        ? 28
                                                                        : 22,
                                                                  ),
                                                                ),
                                                              ),
                                                              AnimatedContainer(
                                                                duration:
                                                                    const Duration(
                                                                        milliseconds:
                                                                            200),
                                                                curve: Curves
                                                                    .easeOutCubic,
                                                                width: showSlider
                                                                    ? (wide
                                                                        ? 104
                                                                        : 84)
                                                                    : 0,
                                                                child: ClipRect(
                                                                  child:
                                                                      ExcludeFocus(
                                                                          excluding: TvDevice
                                                                              .isTv,
                                                                          child:
                                                                              SliderTheme(
                                                                            data:
                                                                                SliderThemeData(
                                                                              trackHeight: wide ? 4 : 3,
                                                                              activeTrackColor: Colors.white,
                                                                              inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
                                                                              thumbColor: Colors.white,
                                                                              thumbShape: RoundSliderThumbShape(
                                                                                enabledThumbRadius: wide ? 6.5 : 5,
                                                                                elevation: 0,
                                                                                pressedElevation: 0,
                                                                              ),
                                                                              overlayShape: RoundSliderOverlayShape(
                                                                                overlayRadius: wide ? 13 : 11,
                                                                              ),
                                                                              overlayColor: Colors.white.withValues(alpha: 0.12),
                                                                            ),
                                                                            child:
                                                                                Slider(
                                                                              value: volume,
                                                                              min: 0.0,
                                                                              max: 100.0,
                                                                              onChangeStart: (_) {
                                                                                setState(() => _volumeDragging = true);
                                                                              },
                                                                              onChanged: (val) {
                                                                                _setVolume(
                                                                                  val,
                                                                                  persist: false,
                                                                                );
                                                                              },
                                                                              onChangeEnd: (val) {
                                                                                setState(() => _volumeDragging = false);
                                                                                _setVolume(
                                                                                  val,
                                                                                  showSlider: true,
                                                                                );
                                                                              },
                                                                            ),
                                                                          )),
                                                                ),
                                                              ),
                                                            ],
                                                          );
                                                        },
                                                      ),
                                                    ),
                                                  if (isComputer)
                                                    SizedBox(
                                                        width: wide ? 8 : 4),
                                                  ListenableBuilder(
                                                    listenable:
                                                        Listenable.merge([
                                                      _positionNotifier,
                                                      _durationNotifier
                                                    ]),
                                                    builder: (context, _) =>
                                                        Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          _formatDuration(
                                                              _positionNotifier
                                                                  .value),
                                                          style: TextStyle(
                                                              color:
                                                                  Colors.white,
                                                              fontSize: wide
                                                                  ? 15
                                                                  : 12,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),
                                                        Text(
                                                          '/ ${_formatDuration(_durationNotifier.value)}',
                                                          style: TextStyle(
                                                              color: Colors
                                                                  .white54,
                                                              fontSize: wide
                                                                  ? 15
                                                                  : 12,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500),
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
                                                      alignment:
                                                          Alignment.centerRight,
                                                      child: FittedBox(
                                                        fit: BoxFit.scaleDown,
                                                        alignment: Alignment
                                                            .centerRight,
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            if (wide) ...[
                                                              _menuButton(
                                                                  GlassPillButton(
                                                                grouped: true,
                                                                key:
                                                                    _qualityButtonKey,
                                                                icon: Icons
                                                                    .hd_rounded,
                                                                // The quality playing.
                                                                label:
                                                                    _qualityLabel,
                                                                selected:
                                                                    _menuOpen(
                                                                        'quality'),
                                                                onPressed: () =>
                                                                    _toggleSettingsPanel(
                                                                        'quality',
                                                                        _qualityButtonKey),
                                                              )),
                                                              // English or the original, for a
                                                              // title not made in English.
                                                              if (AudioLanguageService
                                                                  .appliesTo(widget
                                                                      .details)) ...[
                                                                const SizedBox(
                                                                    width: 10),
                                                                _menuButton(
                                                                    GlassPillButton(
                                                                  grouped: true,
                                                                  key:
                                                                      _audioButtonKey,
                                                                  icon: Icons
                                                                      .record_voice_over_rounded,
                                                                  label:
                                                                      'Audio',
                                                                  selected:
                                                                      _menuOpen(
                                                                          'audio'),
                                                                  busy:
                                                                      _changingAudio,
                                                                  onPressed: () =>
                                                                      _toggleSettingsPanel(
                                                                          'audio',
                                                                          _audioButtonKey),
                                                                )),
                                                              ],
                                                              const SizedBox(
                                                                  width: 10),
                                                              _menuButton(
                                                                  GlassPillButton(
                                                                grouped: true,
                                                                key:
                                                                    _subtitlesButtonKey,
                                                                icon: Icons
                                                                    .subtitles_rounded,
                                                                label: _subtitlesSyncing
                                                                    ? 'Syncing…'
                                                                    : 'Subtitles',
                                                                selected: _menuOpen(
                                                                    'subtitles'),
                                                                busy:
                                                                    _subtitlesSyncing,
                                                                onPressed: () =>
                                                                    _toggleSettingsPanel(
                                                                        'subtitles',
                                                                        _subtitlesButtonKey),
                                                              )),
                                                              const SizedBox(
                                                                  width: 10),
                                                              _menuButton(
                                                                  GlassPillButton(
                                                                grouped: true,
                                                                key:
                                                                    _videoSizeButtonKey,
                                                                icon: _videoFit
                                                                    .icon,
                                                                label:
                                                                    'Video Size',
                                                                selected: _menuOpen(
                                                                    'videoSize'),
                                                                onPressed: () =>
                                                                    _toggleSettingsPanel(
                                                                        'videoSize',
                                                                        _videoSizeButtonKey),
                                                              )),
                                                            ] else
                                                              // Settings — quality, subtitles and
                                                              // video size
                                                              _menuButton(
                                                                  GlassPillButton(
                                                                grouped: true,
                                                                key:
                                                                    _settingsButtonKey,
                                                                // Syncing: what's being synced.
                                                                icon: _subtitlesSyncing
                                                                    ? Icons
                                                                        .subtitles_rounded
                                                                    : Icons
                                                                        .tune_rounded,
                                                                label: _subtitlesSyncing
                                                                    ? 'Syncing…'
                                                                    : 'Settings',
                                                                // Subtitles are in here.
                                                                busy:
                                                                    _subtitlesSyncing,
                                                                selected:
                                                                    _menuOpen(
                                                                        'main'),
                                                                onPressed: () =>
                                                                    _toggleSettingsPanel(
                                                                        'main',
                                                                        _settingsButtonKey),
                                                              )),
                                                            if (widget.details
                                                                    .type ==
                                                                'tv') ...[
                                                              const SizedBox(
                                                                  width: 10),
                                                              // In the panel's group: its own
                                                              // press toggles it, rather than
                                                              // counting as a click outside.
                                                              TapRegion(
                                                                groupId:
                                                                    EpisodeBrowser
                                                                        .panelTapGroup,
                                                                child:
                                                                    GlassPillButton(
                                                                  grouped: true,
                                                                  icon: Icons
                                                                      .grid_view_rounded,
                                                                  label:
                                                                      'Episodes',
                                                                  selected:
                                                                      _showEpisodeDrawer,
                                                                  onPressed:
                                                                      _toggleEpisodeBrowser,
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                  width: 10),
                                                              GlassPillButton(
                                                                grouped: true,
                                                                icon: Icons
                                                                    .skip_next_rounded,
                                                                label: 'Next',
                                                                onPressed:
                                                                    nextEpisodePlayable
                                                                        ? _playNextEpisode
                                                                        : null,
                                                              ),
                                                            ],
                                                            if (WindowFullScreen
                                                                .supported) ...[
                                                              const SizedBox(
                                                                  width: 10),
                                                              ValueListenableBuilder<
                                                                  bool>(
                                                                valueListenable:
                                                                    WindowFullScreen
                                                                        .state,
                                                                builder: (context,
                                                                        isFullScreen,
                                                                        _) =>
                                                                    GlassCircleButton(
                                                                  grouped: true,
                                                                  icon: isFullScreen
                                                                      ? Icons
                                                                          .fullscreen_exit_rounded
                                                                      : Icons
                                                                          .fullscreen_rounded,
                                                                  iconSize: wide
                                                                      ? 24
                                                                      : 20,
                                                                  dimension:
                                                                      wide
                                                                          ? 42
                                                                          : 34,
                                                                  onPressed:
                                                                      () {
                                                                    _resetControlsTimer();
                                                                    WindowFullScreen
                                                                        .toggle();
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

                            // "Reconnecting…" while a stalled stream's picked
                            // back up (see _reconnecting): where "Resumed from"
                            // shows, which it never overlaps.
                            _glassBadge(
                              top: 16 + safe.top,
                              visible: _reconnecting && !_speedBoost,
                              children: const [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: Colors.white,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text('Reconnecting…', style: _badgeTextStyle),
                              ],
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
                                Text(_resumeBadge ?? '',
                                    style: _badgeTextStyle),
                              ],
                            ),

                            // "Subtitles synced" for a moment when syncing moved
                            // them (see _showSyncedBadge) — under "Resumed from" if
                            // that's up too.
                            _glassBadge(
                              top: 16 +
                                  safe.top +
                                  (_resumeBadge != null ? 44 : 0),
                              visible: _syncedBadge && !_speedBoost,
                              children: const [
                                Icon(Icons.subtitles_rounded,
                                    color: Colors.white, size: 16),
                                SizedBox(width: 6),
                                Text('Subtitles synced',
                                    style: _badgeTextStyle),
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
                                  [_activeSkipSegmentNotifier, _upNextShown, _upNextStage]),
                              builder: (context, _) {
                                final segment =
                                    _activeSkipSegmentNotifier.value;
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
                                      duration:
                                          const Duration(milliseconds: 220),
                                      opacity: visible ? 1.0 : 0.0,
                                      child: Listener(
                                        onPointerDown: _markControlsPointer,
                                        child: upNext
                                            ? Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  // The credits, a preview after
                                                  // them: on to it. During the
                                                  // preview: Next Episode alone.
                                                  // Otherwise: Watch Credits.
                                                  if (_upNextStage.value ==
                                                      UpNextStage.credits) ...[
                                                    GlassPillButton(
                                                      grouped: true,
                                                      label: 'Skip Credits',
                                                      onPressed: () {
                                                        final to = UpNextPlan.at(
                                                                _skipSegments,
                                                                _duration,
                                                                _currentPosition)
                                                            .previewStart;
                                                        if (to != null) {
                                                          _skipCreditsToPreview(
                                                              to);
                                                        }
                                                      },
                                                    ),
                                                    const SizedBox(width: 10),
                                                  ] else if (_upNextStage
                                                          .value !=
                                                      UpNextStage.preview) ...[
                                                    GlassPillButton(
                                                      grouped: true,
                                                      label: 'Watch Credits',
                                                      onPressed: _watchCredits,
                                                    ),
                                                    const SizedBox(width: 10),
                                                  ],
                                                  GlassPillButton(
                                                    grouped: true,
                                                    icon:
                                                        Icons.skip_next_rounded,
                                                    label: 'Next Episode',
                                                    progress: _upNextFill,
                                                    onPressed:
                                                        _playNextFromUpNext,
                                                  ),
                                                ],
                                              )
                                            : GlassPillButton(
                                                grouped: true,
                                                icon: Icons.skip_next_rounded,
                                                label:
                                                    segment?.type.buttonLabel ??
                                                        'Skip Intro',
                                                onPressed: segment == null
                                                    ? null
                                                    : () => _skipActiveSegment(
                                                        segment),
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
                            sinhalaProgress: _sinhala?.progress.value,
                            sinhalaProblem: _sinhala?.problem.value,
                            onAddGeminiKey: _addGeminiKey,
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
                            audioTitle:
                                AudioLanguageService.appliesTo(widget.details)
                                    ? widget.details
                                    : null,
                            onAudioLanguageSelected: _setAudioLanguage,
                            unavailableAudio: _noAudioIn,
                            audioChanging: _changingAudio,
                            subtitleDelaySeconds: _subtitleDelaySeconds,
                            onSubtitleDelayChanged: _setSubtitleDelay,
                            subtitleSpeed: _subtitleSpeed,
                            onSubtitleSpeedChanged: _setSubtitleSpeed,
                            subtitleSyncNote: _subtitleSyncNote,
                            subtitleFitNote: _subtitleFitNote,
                            subtitleFollows: _subtitleFollows,
                            subtitleSyncing: _subtitlesSyncing,
                            anchorCenterX: _settingsPanelAnchorX,
                            initialView: _settingsPanelInitialView,
                            closeRequests: _settingsCloseRequests,
                            // Level with the episode panel's foot on a wide window.
                            bottom: playerIsWide(context)
                                ? _bottomBarClearance(
                                    MediaQuery.sizeOf(context))
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
