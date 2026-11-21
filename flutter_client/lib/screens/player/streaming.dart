part of '../player_screen.dart';

extension _PlayerStreaming on _PlayerScreenState {
  /// Sets the player up and opens the video. If any of that fails, the
  /// spinner stops and the viewer's told, rather than it spinning forever.
  Future<void> _initPlayer() async {
    try {
      await _setUpPlayer();
    } catch (e) {
      // Closed meanwhile: the player's gone, nothing to say.
      if (!mounted) return;
      debugPrint('Player setup failed: $e');
      _updateState(() => _isMediaOpening = false);
      showAppMessage(
        context,
        "Couldn't start playback. Try another quality.",
        error: true,
      );
    }
  }

  Future<void> _setUpPlayer() async {
    _loadSubtitles();
    _checkAudioLanguages();
    _loadApiSkipSegments();
    // Configure MPV for torrent streaming — P2P data arrives in bursts,
    // so we tune the cache to fill a sensible buffer before starting playback
    // and to re-pause when the buffer drains rather than stalling mid-stream.
    // Each step stops if the player's been closed meanwhile.
    final mpv = player.platform as NativePlayer;
    // A phone's memory is tighter: a smaller demuxer cache there.
    final phone = Platform.isAndroid || Platform.isIOS;
    mpv.onLoadHooks.add(() => _applyLoadStart(mpv));
    await mpv.observeProperty('chapter-list', _onMpvChapterList);
    // Which subtitle tracks are on, in the log ([subtitles] sid / secondary).
    for (final p in ['sid', 'secondary-sid']) {
      await mpv.observeProperty(p, (v) async => print('[subtitles] $p = $v'));
    }
    for (final p in {
      'cache': 'yes',
      'cache-secs': '60', // Keep up to 60s of video cached ahead
      'demuxer-readahead-secs':
          '10', // Fetch 10s ahead (not 30) to start sooner
      // Demuxer cache ahead, and back-buffer for seeking.
      'demuxer-max-bytes': phone ? '64M' : '150M',
      'demuxer-max-back-bytes': phone ? '16M' : '50M',
      'cache-pause-initial':
          'yes', // Pause at startup until initial cache fills
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
        _updateState(() => _isPlaying = val);
        if (_isMediaOpening) {
          print('[timing] opening: ${val ? 'playing' : 'paused'} at '
              '${_openingStopwatch.elapsedMilliseconds} ms');
        }
        // Sync play/pause to notification
        _syncMediaSessionPlaybackState();
        // The screen stays on while the player's open, paused too (it used
        // to sleep a minute into a pause): see initState.
        // Up next's countdown runs only while the video plays.
        // (The preview's fill follows the video itself: see _updateUpNext.)
        if (_upNextStage.value == UpNextStage.countdown) {
          val ? _upNextFill.forward() : _upNextFill.stop();
        }
        if (val) {
          _resetControlsTimer();
        } else {
          _updateState(() => _controlsVisible = true);
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
        print('[timing] opening: ' +
            (isBuffering ? 'waiting for data' : 'has enough data') +
            ' at ${_openingStopwatch.elapsedMilliseconds} ms');
      }
      _updateState(() => _isBuffering = isBuffering);
      // The loading spinner rings the play/pause button, which lives in the
      // controls — so bring them up for any stall long enough to notice
      // (not the momentary blip after every seek), and let them auto-hide
      // again once playback resumes.
      _bufferingRevealTimer?.cancel();
      if (isBuffering) {
        _bufferingRevealTimer = Timer(const Duration(milliseconds: 600), () {
          if (!mounted || !_isBuffering) return;
          _revealWait();
        });
      } else {
        if (_tvWaitShown) _updateState(() => _tvWaitShown = false);
        _resetControlsTimer();
      }
    });

    void applyDuration(Duration dur) {
      if (!mounted || dur <= Duration.zero) return;
      _duration = dur;
      _durationNotifier.value = dur;
      _updateMediaSessionMetadata();
      _rememberEpisodeLength(dur);
      _scheduleLengthCheck();
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
        // Reopening after a stall: the bar stays where it was until the
        // video's playing there again.
        final holding = _heldPosition != null && _isMediaOpening;
        if (!inInitialSeekWindow && !holding) {
          // Not wrapped in setState — only the seek bar (via _positionNotifier)
          // needs to react to this, not the whole screen, since this fires
          // several times a second during playback.
          _currentPosition = pos;
          _sinhala?.watchingAt(pos.inMilliseconds / 1000);
          // The seek bar and the clock show whole seconds, and hidden
          // controls show nothing (they catch up when shown again: see
          // _controlsVisible) — so no rebuild for anything finer.
          if (_controlsVisible &&
              pos.inSeconds != _positionNotifier.value.inSeconds) {
            _positionNotifier.value = pos;
          }
        }
        if (_isMediaOpening) {
          _checkOpeningFinished(pos);
          _checkReadyWhilePaused();
        }
        if (_seekPending) _checkSeekFinished(pos);
        _updateActiveSkipSegment(pos);
        // A season's last episode: the next season's looked up from the
        // start (once), so Next works all through it.
        if (_nextSeasonLookedUpFrom != (_currentSeason ?? 1) &&
            !_nextSeasonLoading &&
            _isLastOfSeason) {
          unawaited(_loadNextSeason());
        }
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
      if (mounted && _isMediaOpening) _checkReadyWhilePaused();
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

  /// An error from mpv (see _errorSub). Some are passing decoder complaints
  /// that playback carries on through, so it's taken for a dead stream only
  /// if, a few seconds on, the video is still opening or stuck in place.
  void _onPlayerError(String error) {
    if (!mounted || _closing) return;
    print('[player] error: $error');
    if (_switchingQuality || _recoveringStream || _errorCheck != null) return;
    // About something other than the video: an online subtitle file that
    // wouldn't load ("Failed to open https://…", "Can not open external
    // file …"). The video is served from 127.0.0.1; one of these arriving
    // while it's still opening must not be taken for a dead stream.
    if (_isAboutOtherFile(error)) return;
    final at = _currentPosition;
    _errorCheck = Timer(const Duration(seconds: 5), () {
      _errorCheck = null;
      if (!mounted || _closing || _switchingQuality || _recoveringStream) {
        return;
      }
      final stuck = _isMediaOpening || (_isPlaying && _currentPosition == at);
      if (!stuck) return;
      if (_autoRecoverAttempts >= _PlayerScreenState._maxAutoRecoverAttempts) {
        // Nothing left to try: no endless spinner — recovery's message
        // says to try another quality.
        _updateState(() => _isMediaOpening = false);
      }
      _attemptStreamRecovery(reason: 'mpv error: $error');
    });
  }

  /// Whether mpv [error] is about a file other than the video being played.
  static bool _isAboutOtherFile(String error) {
    if (error.toLowerCase().contains('external file')) return true;
    final urls = _PlayerScreenState._urlPattern.allMatches(error).map((m) => m.group(0)!);
    return urls.isNotEmpty &&
        urls.every((u) => !u.contains('127.0.0.1') && !u.contains('localhost'));
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
    // The preview's played to the end: on to the next episode, as its
    // fill would have.
    if (_upNextStage.value == UpNextStage.preview) {
      _playNextFromUpNext();
      return;
    }
    final next = _nextEpisode;
    if (widget.details.type == 'tv' &&
        next != null &&
        !next.isUnreleased &&
        !_upNextShown.value) {
      _playNextEpisode();
    } else {
      _controlsTimer?.cancel();
      _updateState(() => _controlsVisible = true);
    }
  }

  /// Ends the opening state once playback is genuinely under way: playing,
  /// not buffering, and the position moving forward in small steps. A
  /// single "playing"/"not buffering" event isn't enough (both fire before
  /// the stream connects), and the first position change is often the jump
  /// to the resume point rather than playback.
  /// Opening, but paused: done loading once it's at the spot it starts
  /// from with a few seconds downloaded ahead — the spinner goes, rather
  /// than staying till it plays (_checkOpeningFinished waits for that).
  /// Paused by the viewer, it then waits for them; otherwise (paused by
  /// something along the way) it plays.
  void _checkReadyWhilePaused() {
    if (!_isMediaOpening || _isPlaying || _switchingQuality ||
        _recoveringStream || _closing) {
      return;
    }
    if (_duration <= Duration.zero) return;
    final pos = player.state.position;
    final share = _openingStartShare;
    final at = _openingStartAt ??
        (share == null
            ? Duration.zero
            : Duration(milliseconds: (_duration.inMilliseconds * share).round()));
    // Not at its starting spot yet (the jump to the resume point).
    if (pos < at - const Duration(seconds: 5)) return;
    if (player.state.buffer - pos < const Duration(seconds: 3)) return;
    if (_heldByViewer) {
      _heldPosition = null;
      _updateState(() => _isMediaOpening = false);
      print('[timing] ready, held paused by the viewer, '
          '${_openingStopwatch.elapsedMilliseconds} ms after opening');
    } else {
      player.play();
    }
  }

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
      _heldPosition = null;
      _updateState(() => _isMediaOpening = false);
      TorrentEngineService.instance.streamStarted(_streamId);
      print('[timing] video playing ${_openingStopwatch.elapsedMilliseconds} '
          'ms after the player opened it');
      // Started on a small read-ahead so the first pieces came first (see
      // TorrentEngineService.startupStreamCacheBytes): now fetch ahead fully.
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) {
        TorrentEngineService.instance.setStreamCacheCapacity(
            _streamId, TorrentEngineService.defaultStreamCacheBytes);
      }
      _fingerprintSubtitles();
      // Loaded: now the controls can start counting down to hide.
      _resetControlsTimer();
      // Where it really carries on from: a resume lands on the keyframe
      // before the saved spot (see 'hr-seek'), up to several seconds
      // earlier, and the notice gave the saved spot ("Resumed from 00:08"
      // over a picture at 00:06).
      final resumedFrom = _pendingResumeBadge;
      _pendingResumeBadge = null;
      if (resumedFrom != null) {
        _showResumeBadge(
            'Resumed from ${_formatDuration(_currentPosition)}');
      }
    }
  }

  /// Seeks to [target], ringing play/pause with the loading spinner until
  /// playback carries on (see _seekPending) — and, like a stall, bringing
  /// the controls up to show it if that takes long enough to notice.
  void _seekTo(Duration target) {
    _pendingSkipSeek = null; // A newer seek replaces a waiting skip.
    player.seek(target);
    _updateState(() {
      _seekPending = true;
      _seekStartedAt = DateTime.now();
      _seekLastPosition = null;
    });
    _seekRevealTimer?.cancel();
    _seekRevealTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || !_seekPending) return;
      _revealWait();
    });
  }

  void _checkSeekFinished(Duration pos) {
    final startedAt = _seekStartedAt;
    if (startedAt == null) return;
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed >= _PlayerScreenState._seekRingLimit) {
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

  /// A wait long enough to notice (a seek, a stall): the controls up to
  /// show it, the play button ringed with the spinner — or on a TV, where
  /// only OK brings them up, a spinner of its own (see _tvWaitShown).
  void _revealWait() {
    if (TvDevice.isTv) {
      if (!_controlsVisible) _updateState(() => _tvWaitShown = true);
      return;
    }
    _controlsTimer?.cancel();
    _updateState(() => _controlsVisible = true);
  }

  void _finishSeek() {
    _updateState(() {
      _seekPending = false;
      _seekStartedAt = null;
      _tvWaitShown = false;
    });
    // Playing again: the controls can hide as usual.
    _resetControlsTimer();
  }

  /// How long the copy being opened has to deliver its first MB (see
  /// _checkForStall): longer for the one last played.
  Duration get _openingWait =>
      _currentStream.infoHash.toLowerCase() == _patientHash
          ? _PlayerScreenState._openingDataWaitRemembered
          : _PlayerScreenState._openingDataWait;

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
      } else if (DateTime.now().difference(baseline.at) >= _openingWait &&
          downloadedBytes - baseline.bytes < _PlayerScreenState._openingMinBytes &&
          // Not a copy with much on the device already (resumed, or
          // downloaded whole): it has little or nothing left to fetch, so
          // its count stays flat however well it's doing — and this left a
          // whole downloaded episode for another copy from nothing ("Finding
          // a faster copy…"), deleting it. The 45 s rule below still
          // catches one that's really stuck.
          baseline.bytes < _PlayerScreenState._openingHasDataBytes &&
          StreamResolver.sameQuality(_currentStream, _availableStreams).any(
              (s) =>
                  !_triedStartHashes.contains(s.infoHash.toLowerCase()) &&
                  s.infoHash.toLowerCase() !=
                      _currentStream.infoHash.toLowerCase())) {
        _openingBaseline = null;
        _stallTicks = 0;
        _attemptStreamRecovery(
          reason: 'Under 2 MB after ${_openingWait.inSeconds}s of opening',
        );
        return;
      }
    }

    final positionStuck = _currentPosition == _lastWatchdogPosition;
    // totalDone counts only finished pieces: on a slow copy (two sharers at
    // ~50 KB/s, 4 MB pieces) it stays flat for over a minute while data is
    // arriving, and recovery — which deletes what's downloaded — kept
    // restarting it from nothing. Data still coming in isn't a stall.
    final receiving =
        (LibtorrentFlutter.instance.torrents[_torrentId]?.downloadRate ?? 0) >=
            _PlayerScreenState._stillReceivingBytesPerSecond;
    final downloadStuck = !receiving &&
        (_lastWatchdogDownloadedBytes == null ||
            downloadedBytes == null ||
            downloadedBytes <= _lastWatchdogDownloadedBytes!);

    _stallTicks = (positionStuck && downloadStuck) ? _stallTicks + 1 : 0;
    _lastWatchdogPosition = _currentPosition;
    _lastWatchdogDownloadedBytes = downloadedBytes;

    final threshold =
        _isMediaOpening ? _PlayerScreenState._openingStallTicksThreshold : _PlayerScreenState._stallTicksThreshold;
    if (_stallTicks >= threshold) {
      _stallTicks = 0;
      _attemptStreamRecovery(
        reason: 'No playback or download progress for ${threshold * 5}s',
      );
    }
  }

  /// Checks the length of the copy playing, once it's settled (see
  /// _checkLength).
  void _scheduleLengthCheck() {
    if (_lengthCheckOff || widget.movie.type != 'movie') return;
    _lengthCheckTimer?.cancel();
    _lengthCheckTimer =
        Timer(const Duration(milliseconds: 1500), _checkLength);
  }

  /// A film's copy far shorter or longer than the film (see
  /// StreamResolver.wrongLength) is another film filed under it — The
  /// Asylum's 86-minute The Odyssey played for Nolan's 173 — and the next
  /// copy goes instead (see _leaveWrongCopy). Once per copy.
  void _checkLength() {
    if (!mounted || _lengthCheckOff) return;
    // Mid-switch, the length may be the last copy's: once it's settled.
    if (_switchingQuality || _recoveringStream) {
      _scheduleLengthCheck();
      return;
    }
    final hash = _currentStream.infoHash.toLowerCase();
    if (hash == _lengthCheckedHash) return;
    _lengthCheckedHash = hash;
    final expected = StreamResolver.minutesOf(widget.details.runtime);
    if (!StreamResolver.wrongLength(_duration, expected)) return;
    print('This copy is ${_duration.inMinutes} min, the film $expected: '
        'another film');
    unawaited(_leaveWrongCopy());
  }

  /// Leaves the copy playing, found to be another film — or, given
  /// [language], to have no soundtrack in it (see _checkAudio). Another
  /// film's copy is never offered for this one again
  /// (StreamResolver.markWrongCopy) and its download is deleted; a dub's
  /// is kept, for its own language. The next copy — of the same quality
  /// first — plays from the saved spot; with none, a dub stops rather than
  /// play on in the wrong language.
  Future<void> _leaveWrongCopy({SpokenLanguage? language}) async {
    if (_switchingQuality || _recoveringStream || !mounted) return;
    final wrong = _currentStream;
    final hash = wrong.infoHash.toLowerCase();
    final imdbId = widget.details.imdbId ?? widget.details.id;
    final dub = language != null;
    final languageName = language?.name ?? '';
    final kind = widget.details.type == 'tv' ? 'episode' : 'film';
    if (dub) {
      // Not a word of it heard: stopped while the next is found.
      player.pause();
    } else {
      _wrongLengthHashes.add(hash);
      if (_wrongLengthHashes.length >= 3) {
        _lengthCheckOff = true;
        for (final h in _wrongLengthHashes) {
          unawaited(StreamResolver.markWrongCopy(imdbId, h, wrong: false));
        }
        return;
      }
      unawaited(StreamResolver.markWrongCopy(imdbId, hash));
    }
    _triedStartHashes.add(hash);
    bool untried(TorrentStream s) =>
        !_triedStartHashes.contains(s.infoHash.toLowerCase());
    final rest = [
      for (final s in _availableStreams)
        if (s.infoHash.toLowerCase() != hash) s,
    ];
    final same = StreamResolver.sameQuality(wrong, rest)
        .where((s) => s.infoHash.toLowerCase() != hash && untried(s))
        .toList();
    final candidates = [
      ...same,
      ...rest.where((s) => !same.contains(s) && untried(s)),
    ];
    _updateState(() => _availableStreams = rest);
    if (candidates.isEmpty) {
      showAppMessage(
        context,
        dub
            ? 'This copy turned out to be dubbed, and this $kind has no '
                'other with $languageName audio.'
            : 'This copy seems to be a different film, and there are no '
                'others.',
        error: true,
      );
      return;
    }

    _recoveringStream = true;
    _updateState(() {
      _switchingQuality = true;
      _switchingMessage = dub
          ? 'Finding a copy in $languageName…'
          : 'Finding the right copy…';
      _initialPositionRestored = false;
      _forgetFileSubtitles();
    });
    player.pause();
    StreamResult? started;
    try {
      final resolved = await _resolver.resolveWithFallback(
        candidates.first,
        candidates,
        isCancelled: () => !mounted,
        title: widget.details,
      );
      final result = started = resolved.result;
      if (_closedDuringSwitch(started)) return;
      await _rememberPlayedTorrent(resolved.stream);
      if (_closedDuringSwitch(started)) return;
      await _openMediaWithResume(result.streamUrl, streamId: result.streamId);
      if (_closedDuringSwitch(started)) return;
      _playUnlessHeld();
      _updateState(() {
        _currentStream = resolved.stream;
        _torrentId = result.torrentId;
        _streamId = result.streamId;
        _streamUrl = result.streamUrl;
        _switchingQuality = false;
        _resetControlsTimer();
      });
      _subscribeToTorrent(_torrentId);
      _loadSubtitles();
      // The other film's download (a dub's is kept, for its own language).
      if (!dub) unawaited(TorrentStorageService.deleteByInfoHash(hash));
    } on ResolveCancelledException {
      return;
    } catch (e) {
      if (_closedDuringSwitch(started)) return;
      _returnAfterFailedSwitch(resumePlayback: false);
      if (mounted) {
        _updateState(() {
          _switchingQuality = false;
          _initialPositionRestored = true;
        });
        showAppMessage(
          context,
          dub
              ? "This copy turned out to be dubbed, and one with "
                  "$languageName audio wouldn't start. Try another "
                  'quality.'
              : "This copy seems to be a different film, and another "
                  "wouldn't start. Try another quality.",
          error: true,
        );
      }
    } finally {
      _recoveringStream = false;
    }
  }

  Future<void> _attemptStreamRecovery({String? reason}) async {
    if (_recoveringStream || _switchingQuality || !mounted) return;

    // Mid-film, first just reopen this copy where it was (see
    // _reconnectInPlace); only if it's stuck again soon after does the
    // rest happen.
    final lastInPlace = _lastInPlaceReconnectAt;
    if (!_isMediaOpening &&
        (lastInPlace == null ||
            DateTime.now().difference(lastInPlace) > _PlayerScreenState._inPlaceReconnectHolds)) {
      await _reconnectInPlace(reason: reason);
      return;
    }

    if (_autoRecoverAttempts >= _PlayerScreenState._maxAutoRecoverAttempts) {
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
    _heldPosition = resumeAt;
    final staleInfoHash = _currentStream.infoHash;
    final stuckTorrentId = _torrentId;
    // Fully downloaded: the stall can't be missing data (download bytes are
    // always flat once it's done), so wiping would only throw away a good
    // copy — it's just reopened at the current position.
    final stuckTorrent = LibtorrentFlutter.instance.torrents[stuckTorrentId];
    final alreadyComplete = stuckTorrent != null &&
        stuckTorrent.totalWanted > 0 &&
        stuckTorrent.totalDone >= stuckTorrent.totalWanted;
    // Much downloaded already: kept if another copy takes over (below).
    final hadData =
        (stuckTorrent?.totalDone ?? 0) >= _PlayerScreenState._openingHasDataBytes;

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
      _updateState(() {
        _switchingQuality = true;
        // Still starting, nothing's playing to reconnect: it's moving on
        // to a faster copy, under the loading spinner. Mid-film, the tag
        // at the top (see _reconnecting).
        _reconnecting = !_isMediaOpening;
        _switchingMessage =
            _isMediaOpening ? 'Finding a faster copy…' : 'Reconnecting…';
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
          title: widget.details,
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
          title: widget.details,
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

      await _openMediaWithResume(result.streamUrl,
          precisePosition: resumeAt, streamId: result.streamId);
      if (_closedDuringSwitch(result)) return;
      _playUnlessHeld();
      if (otherCopies.isNotEmpty && stuckTorrentId != result.torrentId) {
        // Kept (just stopped) when it had much on the device: deleted, a
        // downloaded episode was lost for good.
        hadData
            ? _resolver.pause(stuckTorrentId)
            : _resolver.cleanup(stuckTorrentId);
      }

      if (mounted) {
        _updateState(() {
          _currentStream = resolvedStream;
          _torrentId = result.torrentId;
          _streamId = result.streamId;
          _streamUrl = result.streamUrl;
          _switchingQuality = false;
          _reconnecting = false;
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
      _heldPosition = null;
      if (otherCopies.isNotEmpty) {
        // No other copy started either: carry on waiting for the first
        // one (the watchdog checks it again).
        _returnAfterFailedSwitch(resumePlayback: true);
      }
      if (mounted) {
        _updateState(() {
          _switchingQuality = false;
          _reconnecting = false;
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

  /// Reopens the video being played where it was, from the same copy,
  /// keeping everything downloaded. Mid-film, a stall is most often the
  /// app's own connection to the download dropping (mpv then stops, or
  /// takes it for the end of the file) rather than the copy failing, and
  /// the full recovery deleted the whole download and started over: the
  /// picture went back to the start and loaded again, the saved progress
  /// then taking it back to the spot. A colleague hit it twice in one film.
  Future<void> _reconnectInPlace({String? reason}) async {
    print('Stream reconnect in place: $reason');
    _lastInPlaceReconnectAt = DateTime.now();
    _recoveringStream = true;
    final resumeAt = _currentPosition;
    _heldPosition = resumeAt;
    if (mounted) {
      _updateState(() {
        _switchingQuality = true;
        _switchingMessage = 'Reconnecting…';
        _reconnecting = true;
      });
    }
    try {
      await _openMediaWithResume(_streamUrl, precisePosition: resumeAt);
      if (!mounted || _closing) return;
      _playUnlessHeld();
    } catch (e) {
      debugPrint('Reconnecting in place failed: $e');
      _heldPosition = null;
    } finally {
      _recoveringStream = false;
      if (mounted) {
        _updateState(() {
          _switchingQuality = false;
          _reconnecting = false;
          _resetControlsTimer();
        });
      }
    }
  }

  /// Where another copy of this video should start: the spot being watched,
  /// or null — the saved progress (see _openMediaWithResume) — while it's
  /// still opening or near the start, when the position is still 0 and not
  /// where the viewer had got to.
  ///
  /// Reopening after a stall (see _heldPosition), the spot it was at.
  Duration? _resumePointForSwitch() =>
      _heldPosition ??
      ((_isMediaOpening || _currentPosition < const Duration(seconds: 5))
          ? null
          : _currentPosition);

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

  /// Roughly "2 minutes of this file" in bytes, estimated from its total
  /// size and duration (assumes near-constant bitrate — close enough for
  /// capping background pre-fetch, doesn't need to be exact). Falls back to
  /// a flat cap when size/duration aren't known yet (e.g. backgrounded
  /// right as playback starts, before the player has reported a duration).
  int _backgroundCacheBytes() {
    const flatFallback = 20 * 1024 * 1024; // 20 MB
    const twoMinutes = Duration(minutes: 2);
    final totalBytes =
        TorrentDownloadRegistry.parseSizeBytes(_currentStream.size);
    if (totalBytes == null || totalBytes <= 0 || _duration.inSeconds <= 0) {
      return flatFallback;
    }
    final bytesPerSecond = totalBytes / _duration.inSeconds;
    final bytes = (bytesPerSecond * twoMinutes.inSeconds).round();
    return bytes.clamp(
        flatFallback, TorrentEngineService.defaultStreamCacheBytes);
  }

  Future<void> _openMediaWithResume(
    String url, {
    Duration? precisePosition,
    int? overrideSeason,
    int? overrideEpisode,
    int? streamId,
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

    _openingStartAt = precisePosition;
    _openingStartShare = null;
    if (precisePosition != null) {
      _loadStart = '${precisePosition.inSeconds}';
      await mpv.setProperty('start', _loadStart);
      if (mounted) {
        _updateState(() {
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
        final histMovie = SavedMoviesService()
            .getMovieFromHistory(widget.movie.id, type: widget.movie.type);
        progress = histMovie?.progress;
      }

      if (progress != null && progress > 0.0 && progress < 0.95) {
        _openingStartShare = progress;
        final startPercent = (progress * 100).toStringAsFixed(2);
        _loadStart = '$startPercent%';
        await mpv.setProperty('start', _loadStart);
        _pendingResumeSnackbarProgress = progress;
      } else {
        _loadStart = '0';
        await mpv.setProperty('start', '0'); // reset globally persistent option
      }

      if (mounted) {
        _updateState(() {
          _isMediaOpening = true;
          _openingLastPosition = null;
          _seekPending = false;
          _initialPositionRestored = true;
        });
      }
    }

    // Where in the file it starts, for the engine: that part first, and
    // not the 40 MB after the file's headers (see resumeStreamAt).
    final double? startShare = precisePosition != null
        ? (_duration > Duration.zero
            ? precisePosition.inMilliseconds / _duration.inMilliseconds
            : null)
        : _openingStartShare;
    TorrentEngineService.instance
        .resumeStreamAt(streamId ?? _streamId, startShare);

    // Paused by the viewer: opened paused, and it stays so when ready.
    await player.open(Media(url), play: !_heldByViewer);
    await _applySubtitleTimingToMpv();
    if (_selectedSubtitle != null) {
      await _applySubtitleTrackToPlayer(_selectedSubtitle);
    }
  }

  /// Gives mpv the spot the file being loaded starts at (_loadStart), as it
  /// loads. Set only before opening, it was lost whenever a file replaced
  /// another in this player: media_kit clears 'start' as the old one
  /// unloads. Every reopen — after a stall, another copy, another quality
  /// — then played from 0:00, and the progress saved there lost the spot
  /// (Attack on Titan, again and again, back to the start).
  Future<void> _applyLoadStart(NativePlayer mpv) async {
    try {
      await mpv.setProperty('start', _loadStart);
    } catch (_) {}
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
    // Still opening (see _checkOpeningFinished): the position is 0, not
    // yet the resume point it's on its way to — a copy that starts slowly
    // (another device's, nothing downloaded here yet) reported 0 for
    // seconds, and saving it wiped the progress: the copy tried next, and
    // the next Resume, started from the beginning. Closing meanwhile
    // keeps the progress as it was too.
    if (_isMediaOpening) return;
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

      // Into the end credits (where Up Next shows: their start when it's
      // known, else 25 s from the end), and it's watched: an anime's
      // ending song and preview start at about 90%, short of the 95% that
      // counts as watched, and an episode stopped there showed "2m left".
      final atCredits = _duration > const Duration(minutes: 2) &&
          _currentPosition >= _upNextStart();
      final double progress = atCredits
          ? 1.0
          : _currentPosition.inSeconds / _duration.inSeconds;
      await SavedMoviesService().addToHistory(
        widget.movie,
        season: _currentSeason,
        episode: _currentEpisode,
        progress: progress,
      );
      // A series' episode watched: where it's at moves on to the next one
      // (when it's out) — what Resume, the posters' S·E and the series
      // page go by — as on Netflix, rather than staying on the one
      // finished, which Resume played again from its start.
      final next = atCredits ? _nextUp : null;
      if (next != null && !next.episode.isUnreleased) {
        await SavedMoviesService().addToHistory(
          widget.movie,
          season: next.season,
          episode: next.episode.episodeNumber,
        );
      }
    }
  }

  /// Hides the controls after 4s of playback — but not while a video is
  /// still loading (opening, or a quality / episode switch): mpv reports
  /// "playing" before any picture arrives, so they'd vanish mid-load.
  /// _checkOpeningFinished starts the countdown once it really plays.
  bool get _loadingVideo => _isMediaOpening || _switchingQuality;

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
    // A quality picked plays, whether or not this one was paused.
    _heldByViewer = false;
    if (newStream.infoHash.toLowerCase() ==
        _currentStream.infoHash.toLowerCase()) return;

    final savedPos = _resumePointForSwitch();
    final wasPlaying = _isPlaying;
    final oldTorrentId = _torrentId;
    player.pause();

    _updateState(() {
      _switchingQuality = true;
      _switchingMessage = message ??
          'Switching to ${QualityOption(StreamResolver.tierOf(newStream), [
                newStream
              ]).name}…';
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
        title: widget.details,
      );
      final resolvedStream = resolved.stream;
      final result = started = resolved.result;
      if (_closedDuringSwitch(result)) return;

      // 3. Save last played torrent infohash — the one that actually
      // resolved, not necessarily the one originally tapped.
      await _rememberPlayedTorrent(resolvedStream);
      if (_closedDuringSwitch(result)) return;

      // 4. Open new media at exactly saved position natively
      await _openMediaWithResume(result.streamUrl,
          precisePosition: savedPos, streamId: result.streamId);
      if (_closedDuringSwitch(result)) return;
      _playUnlessHeld();

      // 5. Now the new one plays, discard the old torrent and its data.
      if (oldTorrentId != result.torrentId) _resolver.cleanup(oldTorrentId);

      if (mounted) {
        _updateState(() {
          _currentStream = resolvedStream;
          _torrentId = result.torrentId;
          _streamId = result.streamId;
          _streamUrl = result.streamUrl;
          _switchingQuality = false;
          _reconnecting = false;
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
        _updateState(() {
          _switchingQuality = false;
          _reconnecting = false;
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
    if (resumePlayback) _playUnlessHeld();
  }

  /// Plays, unless the viewer paused it (see _heldByViewer).
  void _playUnlessHeld() {
    if (!_heldByViewer) player.play();
  }

  /// Whether the player was closed while a switch awaited something. If so
  /// the torrent the switch [started] is paused — dispose() only paused the
  /// one playing then — and the switch should stop there.
  bool _closedDuringSwitch(StreamResult? started) {
    if (mounted) return false;
    if (started != null) _resolver.pause(started.torrentId);
    return true;
  }

  /// The Quality button's label: the quality playing ("HD", "Full HD").
  String get _qualityLabel =>
      const {4: 'Ultra HD', 3: 'Full HD', 2: 'HD', 1: 'SD'}[
          StreamResolver.tierOf(_currentStream)] ??
      'Quality';
}
