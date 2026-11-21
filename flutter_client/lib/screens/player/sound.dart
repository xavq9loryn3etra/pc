part of '../player_screen.dart';

extension _PlayerSound on _PlayerScreenState {
  /// Checks the soundtracks of the copy playing, once they're listed and
  /// it's settled (see _checkAudio).
  void _scheduleAudioCheck() {
    _audioCheckTimer?.cancel();
    _audioCheckTimer = Timer(const Duration(milliseconds: 800), _checkAudio);
  }

  /// A copy whose soundtracks all say they're in another language than the
  /// one it's to play in is a dub — its name said nothing, and so it was
  /// taken for the title's own language: Attack on Titan, set to Japanese,
  /// played an English-only pack. As on Netflix, it never plays in another
  /// language: it's noted as heard in those (StreamResolver.noteHeardIn,
  /// so it's not offered in this language again — it still is in its
  /// own), and a copy in the language goes instead (see _leaveWrongCopy).
  /// Nothing's done when a soundtrack doesn't say ("und", "Stereo").
  void _checkAudio() {
    if (!mounted) return;
    // Mid-switch, the soundtracks may be the last copy's: once it's settled.
    if (_switchingQuality || _recoveringStream) {
      _scheduleAudioCheck();
      return;
    }
    final audio = [
      for (final t in player.state.tracks.audio)
        if (t.id != 'auto' && t.id != 'no') t,
    ];
    if (audio.isEmpty) return; // Not listed yet.
    final hash = _currentStream.infoHash.toLowerCase();
    final title = widget.details;
    final wanted = AudioLanguageService.appliesTo(title) &&
            AudioLanguageService().of(title) == AudioLanguage.original
        ? title.originalLanguage!
        : 'en';
    final checking = '$hash:$wanted';
    if (checking == _audioCheckedFor) return;
    _audioCheckedFor = checking;
    final heard = <String>{};
    AudioTrack? inIt;
    var unsaid = false;
    for (final t in audio) {
      final code = SpokenLanguage.codeOfTrack(t.language, t.title);
      if (code == null) {
        unsaid = true;
      } else {
        heard.add(code);
        if (SpokenLanguage.mayBeSame(code, wanted)) inIt ??= t;
      }
    }
    if (inIt != null) {
      // The player goes by tags ('alang'); one known only by its name
      // ("Japanese", tagged "und") is picked here.
      final playing = player.state.track.audio.id;
      final current = audio.where((t) => t.id == playing).firstOrNull;
      final currentCode = current == null
          ? null
          : SpokenLanguage.codeOfTrack(current.language, current.title);
      if (currentCode == null ||
          !SpokenLanguage.mayBeSame(currentCode, wanted)) {
        unawaited(player.setAudioTrack(inIt));
      }
      return;
    }
    if (unsaid) return; // One doesn't say: it may well be it.
    final imdbId = title.imdbId ?? title.id;
    print('This copy\'s soundtracks are in ${heard.join(', ')}, not '
        '$wanted: a dub');
    unawaited(StreamResolver.noteHeardIn(imdbId, hash, heard));
    unawaited(_leaveWrongCopy(
        language: AudioLanguageService().languageFor(title)));
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
            _heldByViewer = false;
            player.play();
            break;
          case MediaAction.pause:
            _heldByViewer = true;
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
    final saved = prefs.getDouble(_PlayerScreenState._volumePrefKey);
    if (saved == null || !mounted) return;
    final clamped = saved.clamp(0.0, 100.0);
    _volumeNotifier.value = clamped;
    if (clamped > 0) _volumeBeforeMute = clamped;
    player.setVolume(clamped);
  }

  void _keepVolumeSliderOpenTemporarily() {
    _volumeCollapseTimer?.cancel();
    if (!_volumeRecentlyAdjusted) {
      _updateState(() => _volumeRecentlyAdjusted = true);
    }
    _volumeCollapseTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) _updateState(() => _volumeRecentlyAdjusted = false);
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
          .then((prefs) => prefs.setDouble(_PlayerScreenState._volumePrefKey, clamped));
    }
    if (showSlider) {
      _updateState(() => _controlsVisible = true);
      _keepVolumeSliderOpenTemporarily();
    }
    if (flash) {
      _updateState(() => _flashIcon = _volumeIconFor(clamped));
      _playPauseFlash.forward(from: 0);
    }
    _resetControlsTimer();
  }

  void _toggleMute({bool flash = false}) {
    final current = _volumeNotifier.value;
    final next =
        current > 0 ? 0.0 : (_volumeBeforeMute > 0 ? _volumeBeforeMute : 100.0);
    _setVolume(next, showSlider: true, flash: flash);
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
      // libmpv's default output on Android is OpenSL ES, which is stereo
      // only; AudioTrack takes 5.1/7.1 (OpenSL ES stays as the fallback).
      if (Platform.isAndroid) 'ao': 'audiotrack,opensles',
      // Windows too: with Windows Sonic / Dolby Atmos for Headphones on, or
      // surround speakers, the device takes the film's channels; on a plain
      // stereo device mpv folds them down as before.
      if (Platform.isAndroid || Platform.isWindows) 'audio-channels': 'auto',
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
    // The film's channel layout and what reaches the device, in the log:
    // how to tell whether the surround gets through on a given phone.
    for (final p in [
      'current-ao',
      'audio-params/channel-count',
      'audio-out-params/channel-count',
    ]) {
      if (!mounted) return;
      try {
        await mpv.observeProperty(p, (v) async {
          if (v.isNotEmpty) print('[sound] $p = $v');
        });
      } catch (_) {}
    }
  }

  /// Which of the title's audio languages have a copy of what's playing
  /// (this episode, for a series) — the details page's check
  /// (StreamResolver.getAvailableStreams in each), so the Audio menu
  /// doesn't offer English for a film with none (Aavesham).
  Future<void> _checkAudioLanguages() async {
    final title = widget.details;
    if (!AudioLanguageService.appliesTo(title)) return;
    final season = _currentSeason, episode = _currentEpisode;
    final isTv = title.type == 'tv';
    final none = <AudioLanguage>{};
    for (final language in AudioLanguage.values) {
      try {
        final streams = await _resolver.getAvailableStreams(
          imdbId: title.imdbId ?? title.id,
          type: title.type,
          season: isTv ? season : null,
          episode: isTv ? episode : null,
          title: title,
          audioLanguage: language,
        );
        if (streams.isEmpty) none.add(language);
      } catch (_) {
        return; // Couldn't tell: nothing greyed out.
      }
    }
    if (!mounted || _currentSeason != season || _currentEpisode != episode) {
      return;
    }
    _updateState(() => _noAudioIn = none);
  }

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
    _updateState(() => _changingAudio = true);
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
        // Subtitles that fit what's heard now (the dub's, or not).
        unawaited(_rebuildAvailableSubtitles());
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
      if (streams.isNotEmpty) _updateState(() => _availableStreams = streams);
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
      if (mounted) _updateState(() => _changingAudio = false);
    }
  }

  /// This file's soundtrack in [language], if it says which one that is.
  AudioTrack? _audioTrackIn(SpokenLanguage language) {
    for (final t in player.state.tracks.audio) {
      if (t.id == 'auto' || t.id == 'no') continue;
      final tag = t.language?.toLowerCase().trim();
      final code = SpokenLanguage.codeOfTrack(t.language, t.title);
      final named = SpokenLanguage.of(code);
      if (named != null
          ? named == language ||
              named.trackCodes.any(language.trackCodes.contains)
          : tag != null && language.trackCodes.contains(tag)) {
        return t;
      }
    }
    return null;
  }
}
