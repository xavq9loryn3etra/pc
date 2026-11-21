part of '../player_screen.dart';

extension _PlayerEpisodes on _PlayerScreenState {
  /// Records how long this copy of the episode really is — TMDB's runtime
  /// can be well off (a 17-minute edit listed as 24m) — for its card and
  /// "time left" (see SavedMoviesService.saveEpisodeLength), here and in
  /// the episode browser.
  void _rememberEpisodeLength(Duration length) {
    final s = _currentSeason, e = _currentEpisode;
    if (s == null || e == null || length.inSeconds < 60) return;
    SavedMoviesService().saveEpisodeLength(widget.movie.id, s, e, length);
    final minutes =
        SavedMoviesService().getEpisodeMinutes(widget.movie.id, s, e);
    List<Episode> updated(List<Episode> eps) => [
          for (final ep in eps)
            ep.episodeNumber == e ? ep.withRuntime(minutes) : ep,
        ];
    _updateState(() {
      _episodes = updated(_episodes);
      if (_browsingSeason == s) _browsingEpisodes = updated(_browsingEpisodes);
    });
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
        _updateState(() => _showEpisodeDrawer = false);
        _animateEpisodeDrawerClosed();
        _playEpisodeWithChosenStream(ep, season, stream, allStreams);
      },
      onWebPlayerChosen: (ep, season, provider) {
        _pausedForEpisodeBrowser = false;
        _updateState(() => _showEpisodeDrawer = false);
        _animateEpisodeDrawerClosed();
        _openWebPlayerForEpisode(ep, season, provider);
      },
    );
    if (!asPanel) {
      return [
        Positioned.fill(
          key: const ValueKey('episode-browser-layer'),
          child:
              SlideTransition(position: _episodeDrawerOffset, child: browser),
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
                      reducedTint: Colors.black,
                      child: child!,
                    ),
                    child: ColoredBox(
                      color: glassSheetTint(context),
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
      final top = _topLeftInPlayer(box).dy;
      return math.max(0.0, size.height - top) + kSideColumnGap;
    }
    return 140;
  }

  /// Where [box] is in the player's own layout, the one its menus and
  /// subtitles are placed in — not on the screen. On a TV the app's laid
  /// out 1280 wide and shrunk to fit (TvScreenScale), so screen positions
  /// came out a quarter smaller: the menus floated up and to the left of
  /// their buttons, and the subtitles rose above the controls. (Elsewhere
  /// the two are the same.)
  Offset _topLeftInPlayer(RenderBox box) {
    final player = context.findRenderObject();
    return box.localToGlobal(Offset.zero,
        ancestor: player is RenderBox && player.attached ? player : null);
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
    _updateState(() {
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
      if (mounted) _updateState(() => _episodeDrawerMounted = false);
    });
  }

  /// Close the episode browser without having picked a new episode/source —
  /// resumes playback only if [_openEpisodeBrowser] was the one to pause it.
  void _closeEpisodeBrowser() {
    _updateState(() {
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
    // An episode picked plays, whether or not this one was paused.
    _heldByViewer = false;
    if (targetEp.isUnreleased) {
      showAppMessage(context, "This episode hasn't aired yet.");
      return;
    }

    _updateState(() {
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
        throw _NotInLanguageException(
            AudioLanguageService().nameFor(widget.details));
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
      // The copy this episode last played (maybe on another device): given
      // longer to start, if it's the one picked.
      _patientHash = lastPlayed?.toLowerCase();
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
        title: widget.details,
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
    _updateState(() {
      _switchingQuality = false;
          _reconnecting = false;
      _controlsVisible = true;
    });
    debugPrint('Episode switch failed: $e');
    showAppMessage(
      context,
      e is NotEnoughSpaceException
          ? e.toString()
          : e is _NotInLanguageException
              ? "S$seasonNumber E${targetEp.episodeNumber} isn't available in "
                  "${e.language} yet, so you're still on the episode you were "
                  'watching.'
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

    _updateState(() {
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
        title: widget.details,
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
      _updateState(() {
        // Picked from another season in the browser: that season's
        // episodes are now the playing ones.
        if (seasonNumber == _browsingSeason) {
          _episodes = _browsingEpisodes;
        } else if (seasonNumber == _nextSeasonNumber &&
            _nextSeasonEpisodes.isNotEmpty) {
          // Next Episode on into the next season.
          _episodes = _nextSeasonEpisodes;
        }
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
        _manualSubtitleTiming.clear();
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
      _readiedSkipTargets.clear();
      _updateTimelineShapes();
      _timelinePartitionRevision.value++;
      _activeSkipSegmentNotifier.value = null;
    }

    try {
      await _openMediaWithResume(
        result.streamUrl,
        overrideSeason: seasonNumber,
        overrideEpisode: targetEp.episodeNumber,
        streamId: result.streamId,
      );
    } catch (_) {
      if (mounted) {
        _updateState(() {
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
      _updateState(() {
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
          _reconnecting = false;
        _resetControlsTimer();
      });
      _subscribeToTorrent(_torrentId);
      _loadSubtitles();
      _checkAudioLanguages();
      _loadApiSkipSegments();
      _updateMediaSessionMetadata();
    }
  }

  /// The season after the playing one, by the show's seasons (not the
  /// specials, season 0).
  int? get _followingSeason {
    final current = _currentSeason ?? 1;
    final later = [
      for (final s in widget.details.seasons ?? const <Season>[])
        if (s.seasonNumber > current) s.seasonNumber,
    ]..sort();
    return later.firstOrNull;
  }

  /// Whether the playing episode is its season's last.
  bool get _isLastOfSeason {
    if (_currentEpisode == null || _episodes.isEmpty) return false;
    return _episodes.indexWhere((e) => e.episodeNumber == _currentEpisode) ==
        _episodes.length - 1;
  }

  /// The episode after the playing one — this season's next, or, after its
  /// last, the next season's first — and its season.
  ({Episode episode, int season})? get _nextUp {
    if (_currentEpisode == null || _episodes.isEmpty) return null;
    final currentIndex =
        _episodes.indexWhere((e) => e.episodeNumber == _currentEpisode);
    if (currentIndex == -1) return null;
    if (currentIndex < _episodes.length - 1) {
      return (episode: _episodes[currentIndex + 1], season: _currentSeason ?? 1);
    }
    final nextSeason = _nextSeasonNumber;
    if (nextSeason == null ||
        nextSeason != _followingSeason ||
        _nextSeasonEpisodes.isEmpty) {
      return null;
    }
    return (episode: _nextSeasonEpisodes.first, season: nextSeason);
  }

  Episode? get _nextEpisode => _nextUp?.episode;

  /// On a season's last episode: the next season's episodes, for Next
  /// Episode. Once per season.
  Future<void> _loadNextSeason() async {
    if (widget.details.type != 'tv' || !_isLastOfSeason) return;
    final from = _currentSeason ?? 1;
    if (_nextSeasonLookedUpFrom == from || _nextSeasonLoading) return;
    if (_nextSeasonRetryAt?.isAfter(DateTime.now()) ?? false) return;
    final following = _followingSeason;
    _nextSeasonLookedUpFrom = from;
    if (following == null) return;
    _nextSeasonLoading = true;
    try {
      final eps = await TMDBService().getSeasonDetails(
        widget.details.id,
        following,
      );
      if (!mounted) return;
      _updateState(() {
        _nextSeasonNumber = following;
        _nextSeasonEpisodes = eps;
      });
    } catch (e) {
      debugPrint('Next season lookup failed: $e');
      // Tried again later in the episode.
      _nextSeasonLookedUpFrom = null;
      _nextSeasonRetryAt = DateTime.now().add(const Duration(seconds: 30));
    } finally {
      _nextSeasonLoading = false;
    }
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
    final eligible = widget.details.type == 'tv' &&
        next != null &&
        !next.isUnreleased &&
        !_loadingVideo &&
        !_switchingQuality &&
        _duration > const Duration(minutes: 2) &&
        _upNextDismissedFor != key;
    final plan = UpNextPlan.at(_skipSegments, _duration, pos);
    final stage = eligible ? plan.stage : UpNextStage.none;
    if (stage == UpNextStage.preview) {
      // The fill follows the preview: full as it ends, when the next
      // episode plays (the fill's status listener) — paused, sought
      // back or forth, it keeps up.
      if (_upNextStage.value != stage) {
        _upNextFill.stop();
        _upNextStage.value = stage;
        _upNextShown.value = true;
      }
      _upNextFill.value = plan.previewShare >= 0.99 ? 1.0 : plan.previewShare;
      return;
    }
    if (stage == _upNextStage.value) return;
    _upNextStage.value = stage;
    _upNextShown.value = stage != UpNextStage.none;
    _upNextFill
      ..stop()
      ..value = 0;
    if (stage == UpNextStage.countdown && _isPlaying) _upNextFill.forward();
  }

  /// Where up next begins (see UpNextPlan.start).
  Duration _upNextStart() =>
      UpNextPlan.at(_skipSegments, _duration, Duration.zero).start;

  /// Next Episode pressed, or its fill full: the next episode, now.
  void _playNextFromUpNext() {
    if (!_upNextShown.value) return;
    _upNextShown.value = false;
    _upNextStage.value = UpNextStage.none;
    _upNextFill
      ..stop()
      ..value = 0;
    _playNextEpisode();
  }

  /// Watch Credits: up next goes, for this episode, and the credits play.
  void _watchCredits() {
    _upNextDismissedFor = '$_currentSeason:$_currentEpisode';
    _upNextShown.value = false;
    _upNextStage.value = UpNextStage.none;
    _upNextFill
      ..stop()
      ..value = 0;
  }

  /// Skip Credits, with a preview after them: on to the preview, Next
  /// Episode filling over it.
  void _skipCreditsToPreview(Duration previewStart) {
    _currentPosition = previewStart;
    _positionNotifier.value = previewStart;
    _seekTo(previewStart);
    _syncMediaSessionPlaybackState();
  }

  /// Netflix Auto Play Next Episode Feature
  Future<void> _playNextEpisode() async {
    final next = _nextUp;
    if (next == null) return;
    _playEpisode(next.episode, next.season);
  }

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
    // The season's last: readied once the next season's episodes are in.
    if (_isLastOfSeason && _nextUp == null) {
      unawaited(_loadNextSeason());
      if (_nextSeasonLoading ||
          _nextSeasonLookedUpFrom != (_currentSeason ?? 1)) {
        return;
      }
    }
    _readiedFrom = from;
    final nextUp = _nextUp;
    if (nextUp == null || nextUp.episode.isUnreleased) return;
    final next = nextUp.episode;
    final season = nextUp.season;
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
    _updateState(() {
      _loadingSeason = true;
      _switchingMessage = 'Loading season $seasonNumber…';
    });

    try {
      final eps = await TMDBService().getSeasonDetails(
        widget.details.id,
        seasonNumber,
      );

      if (mounted) {
        _updateState(() {
          _browsingSeason = seasonNumber;
          _browsingEpisodes = eps;
          _loadingSeason = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _updateState(() {
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

  /// The playing episode's details, when it's in [_episodes] (TV only).
  Episode? get _playingEpisode => _currentEpisode == null
      ? null
      : _episodes.where((e) => e.episodeNumber == _currentEpisode).firstOrNull;
}
