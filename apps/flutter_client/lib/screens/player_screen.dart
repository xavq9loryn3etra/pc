import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart' hide WebPlayer;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import '../services/saved_movies_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/tmdb_service.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../widgets/player_gesture_overlay.dart';
import '../widgets/episode_drawer.dart';
import '../widgets/player_settings_panel.dart';
import 'details_screen.dart';
import 'web_player/web_player.dart';
import '../services/scraper_service.dart';
import '../services/subtitle_service.dart';

class PlayerScreen extends StatefulWidget {
  final String url;
  final int torrentId;
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

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player player;
  late final VideoController controller;

  // Mutable Stream/Torrent State
  late TorrentStream _currentStream;
  late int _torrentId;
  late String _streamUrl;
  late int? _currentEpisode;
  late int? _currentSeason;

  // Episode Drawer state
  bool _showEpisodeDrawer = false;
  late int? _browsingSeason;
  late List<Episode> _episodes;

  // Settings Panel state
  bool _showSettingsPanel = false;
  String _settingsPanelInitialView = 'main';

  // Peer & Torrent Statistics
  int _peers = 0;
  double _downloadSpeed = 0.0;
  StreamSubscription? _torrentSub;

  // UI Control State
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _switchingQuality = false;
  String? _switchingMessage;

  // Playback position tracking
  Duration _currentPosition = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isDragging = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  Duration _bufferPosition = Duration.zero;
  StreamSubscription? _bufferSub;
  List<SubtitleTrackData> _availableSubtitles = [];
  SubtitleTrackData? _selectedSubtitle;
  bool _isLoadingSubtitles = false;
  bool _initialPositionRestored = false;
  double? _pendingResumeSnackbarProgress;
  bool _isMediaOpening = true; // True from player.open() until first buffering/play event
  DateTime? _lastSaveTime;

  final _resolver = StreamResolver();

  @override
  void initState() {
    super.initState();
    _currentStream = widget.selectedStream;
    _torrentId = widget.torrentId;
    _streamUrl = widget.url;
    _currentEpisode = widget.episode;
    _currentSeason = widget.season;
    _browsingSeason = widget.season;
    _episodes = widget.episodes;

    // Set screen orientations to landscape for immersive viewing
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Initialize media_kit Player
    player = Player();
    controller = VideoController(player);

    _initPlayer();
    _subscribeToTorrent(_torrentId);
    _resetControlsTimer();
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
        setState(() => _currentPosition = pos);
        // Save progress periodically (throttled) ONLY after initial position is restored
        if (_initialPositionRestored) {
          _saveProgress();
        }
      }
    });

    // Listen to total duration
    // Listen to total duration
    _durationSub = player.stream.duration.listen((dur) {
      if (mounted) {
        setState(() => _duration = dur);

        if (_pendingResumeSnackbarProgress != null && dur.inSeconds > 0) {
          final targetSeconds = (dur.inSeconds * _pendingResumeSnackbarProgress!).round();
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
          if (val) _isMediaOpening = false; // playback started, hide initial spinner
        });
        if (val) {
          _resetControlsTimer();
        } else {
          setState(() => _controlsVisible = true);
          _controlsTimer?.cancel();
        }
      }
    });

    // Clear _isMediaOpening as soon as buffering state is first observed
    player.stream.buffering.listen((isBuffering) {
      if (mounted && _isMediaOpening) {
        setState(() => _isMediaOpening = false);
      }
    });

    // Listen to video buffer duration (for YouTube-style grayed-out buffered bar)
    _bufferSub = player.stream.buffer.listen((buf) {
      if (mounted) {
        setState(() => _bufferPosition = buf);
      }
    });
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
        setState(() {
          _peers = t.numPeers;
          _downloadSpeed = t.downloadRate / 1024 / 1024; // Convert to MB/s
        });
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
    _resetControlsTimer();
  }

  void _skipForward() {
    final newPos = _currentPosition + const Duration(seconds: 10);
    player.seek(newPos > _duration ? _duration : newPos);
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
      // 1. Save last played torrent infohash to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final String imdbId = widget.details.imdbId ?? widget.details.id;
      final String key = _currentSeason != null && _currentEpisode != null
          ? 'last_played_torrent_${imdbId}_${_currentSeason}_${_currentEpisode}'
          : 'last_played_torrent_$imdbId';
      await prefs.setString(key, newStream.infoHash);

      // 2. Dispose old torrent FFI daemon to save resources
      _resolver.cleanup(_torrentId);

      // 3. Spin up new torrent
      final result = await _resolver.resolve(newStream);

      // 4. Open new media at exactly saved position natively
      await _openMediaWithResume(result.streamUrl, precisePosition: savedPos);
      player.play();

      if (mounted) {
        setState(() {
          _currentStream = newStream;
          _torrentId = result.torrentId;
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

  /// Generalized Play Episode Function
  Future<void> _playEpisode(Episode targetEp, int seasonNumber) async {
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

      // 2. Fetch Streams for Episode from Torrentio
      final torrentIndex = TorrentIndexService();
      final imdbId = widget.details.imdbId ?? widget.details.id;
      final streams = await torrentIndex.getSeriesStreams(
          imdbId, seasonNumber, targetEp.episodeNumber);

      if (streams.isEmpty) {
        throw Exception('No streams found for this episode.');
      }

      // 3. Sort & Resolve Best Option (First stream)
      streams.sort((a, b) {
        int score(TorrentStream s) {
          int sc = 0;
          final q = s.quality?.toLowerCase() ?? '';
          if (q.contains('4k') || q.contains('2160'))
            sc += 3000;
          else if (q.contains('1080'))
            sc += 2000;
          else if (q.contains('720')) sc += 1000;
          return sc + (s.seeders ?? 0).clamp(0, 1000);
        }

        return score(b) - score(a);
      });

      final bestStream = streams.first;
      final result = await _resolver.resolve(bestStream);

      // 4. Save history for the episode
      await SavedMoviesService().addToHistory(
        widget.movie,
        season: seasonNumber,
        episode: targetEp.episodeNumber,
      );

      // Save last played torrent infohash to SharedPreferences for this episode
      try {
        final prefs = await SharedPreferences.getInstance();
        final String key =
            'last_played_torrent_${imdbId}_${seasonNumber}_${targetEp.episodeNumber}';
        await prefs.setString(key, bestStream.infoHash);
      } catch (e) {
        print('Error saving last played torrent: $e');
      }

      // 5. Play in same controller
      await _openMediaWithResume(
        result.streamUrl,
        overrideSeason: seasonNumber,
        overrideEpisode: targetEp.episodeNumber,
      );

      if (mounted) {
        setState(() {
          _currentStream = bestStream;
          _torrentId = result.torrentId;
          _streamUrl = result.streamUrl;
          _currentEpisode = targetEp.episodeNumber;
          _currentSeason = seasonNumber;
          _switchingQuality = false;
          _currentPosition = Duration.zero;
          _duration = Duration.zero;
          _resetControlsTimer();
        });
        _subscribeToTorrent(_torrentId);
        _loadSubtitles();
      }
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
    // 1. Reset system navigation and landscape orientation to app defaults
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // 2. Save final history position
    _saveProgress(force: true);

    // 3. Cancel subscriptions & timers
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _bufferSub?.cancel();
    _torrentSub?.cancel();
    _controlsTimer?.cancel();

    // 4. Dispose players and clean up active FFI torrent process
    player.dispose();
    _resolver.cleanup(_torrentId);

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
        orElse: () => subs.isNotEmpty ? subs.first : SubtitleTrackData(id: '', url: '', lang: ''),
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
                      Icon(Icons.subtitles_rounded, color: AppTheme.primaryColor, size: 22),
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
                              style: TextStyle(color: Colors.white38, fontSize: 14),
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
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
                                            color: AppTheme.primaryColor, size: 20)
                                        : null,
                                    onTap: () {
                                      _selectSubtitle(null);
                                      Navigator.pop(sheetContext);
                                    },
                                  ),
                                );
                              }

                              final track = _availableSubtitles[index - 1];
                              final isSelected = _selectedSubtitle?.id == track.id;
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
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
                                          color: AppTheme.primaryColor, size: 20)
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
    final hasNextEpisode = widget.details.type == 'tv' &&
        _currentEpisode != null &&
        _episodes.isNotEmpty &&
        _episodes.indexWhere((e) => e.episodeNumber == _currentEpisode) <
            _episodes.length - 1;

    return PopScope(
      canPop: !_showEpisodeDrawer && !_showSettingsPanel,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_showEpisodeDrawer) {
          setState(() {
            _showEpisodeDrawer = false;
            if (!player.state.playing) {
              _controlsVisible = true;
            }
          });
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
              onSwipeUp: widget.movie.type == 'tv'
                  ? () => setState(() {
                        _showEpisodeDrawer = true;
                        _controlsVisible = false;
                      })
                  : null,
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
                            const CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppTheme.primaryColor),
                            ),
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
                                // Torrent stats pill
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.arrow_downward_rounded,
                                          color: Colors.greenAccent.shade400,
                                          size: 12),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${_downloadSpeed.toStringAsFixed(1)} MB/s',
                                        style: TextStyle(
                                            color: Colors.greenAccent.shade400,
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
                                      Text('$_peers',
                                          style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600)),
                                    ],
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
                                      child: Image.network(
                                        widget.details.logoUrl!,
                                        height: 64,
                                        fit: BoxFit.contain,
                                        alignment: Alignment.centerLeft,
                                        errorBuilder:
                                            (context, error, stackTrace) {
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
                                    widget.movie.description,
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
                                // Seek slider
                                SliderTheme(
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
                                    overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 16),
                                    overlayColor:
                                        AppTheme.primaryColor.withOpacity(0.12),
                                  ),
                                  child: Slider(
                                    value: _currentPosition.inSeconds
                                        .toDouble()
                                        .clamp(0.0,
                                            _duration.inSeconds.toDouble()),
                                    secondaryTrackValue: _bufferPosition.inSeconds
                                        .toDouble()
                                        .clamp(0.0,
                                            _duration.inSeconds.toDouble()),
                                    min: 0.0,
                                    max: _duration.inSeconds.toDouble() > 0
                                        ? _duration.inSeconds.toDouble()
                                        : 1.0,
                                    onChangeStart: (val) {
                                      setState(() {
                                        _isDragging = true;
                                      });
                                    },
                                    onChanged: (val) {
                                      setState(() {
                                        _currentPosition =
                                            Duration(seconds: val.toInt());
                                      });
                                    },
                                    onChangeEnd: (val) {
                                      setState(() {
                                        _isDragging = false;
                                      });
                                      player
                                          .seek(Duration(seconds: val.toInt()));
                                    },
                                  ),
                                ),
                                // Timestamps + next episode row
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Row(
                                    children: [
                                      Text(
                                        _formatDuration(_currentPosition),
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '/ ${_formatDuration(_duration)}',
                                        style: TextStyle(
                                            color:
                                                Colors.white.withOpacity(0.35),
                                            fontSize: 12),
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
                                        icon: const Icon(
                                            Icons.hd_rounded,
                                            color: Colors.white,
                                            size: 18),
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
                                            _settingsPanelInitialView = 'quality';
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
                                        icon: Icon(
                                            Icons.subtitles_rounded,
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
                                                  _settingsPanelInitialView = 'subtitles';
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
                                          onPressed: () {
                                            setState(() {
                                              _showEpisodeDrawer = true;
                                              _controlsVisible = false;
                                            });
                                          },
                                        ),
                                      ],
                                      if (hasNextEpisode) ...[
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
                                              Icons.skip_next_rounded,
                                              color: Colors.white,
                                              size: 18),
                                          label: const Text(
                                            'Next Episode',
                                            style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 11),
                                          ),
                                          onPressed: _playNextEpisode,
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

            // Layer 2: Episode Drawer (outside overlay)
            if (_showEpisodeDrawer && widget.movie.type == 'tv')
              Positioned.fill(
                child: EpisodeDrawer(
                  episodes: _episodes,
                  seasons: widget.details.seasons,
                  movie: widget.details,
                  currentSeason: _browsingSeason ?? 1,
                  playingSeason: _currentSeason ?? 1,
                  playingEpisode: _currentEpisode ?? 1,
                  movieId: widget.movie.id,
                  onEpisodeTap: (epNum) {
                    final ep =
                        _episodes.firstWhere((e) => e.episodeNumber == epNum);
                    _playEpisode(ep, _browsingSeason ?? 1);
                    setState(() => _showEpisodeDrawer = false);
                  },
                  onSeasonChanged: _switchSeason,
                  onClose: () => setState(() {
                    _showEpisodeDrawer = false;
                    if (!player.state.playing) {
                      _controlsVisible = true;
                    }
                  }),
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
