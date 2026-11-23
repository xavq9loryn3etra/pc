part of '../player_screen.dart';

extension _PlayerControls on _PlayerScreenState {
  Future<void> _loadVideoFit() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_PlayerScreenState._videoFitPrefKey);
    for (final fit in VideoFit.values) {
      if (fit.name == saved) {
        if (mounted) _updateState(() => _videoFit = fit);
        return;
      }
    }
  }

  void _selectVideoFit(VideoFit fit) {
    _updateState(() => _videoFit = fit);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_PlayerScreenState._videoFitPrefKey, fit.name));
  }

  /// Whether the settings popup is open from [view]'s button — shown
  /// selected (GlassPillButton.selected) while it is.
  bool _menuOpen(String view) =>
      _showSettingsPanel && _settingsPanelInitialView == view;

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
        final topLeft = _topLeftInPlayer(box);
        anchorX = topLeft.dx + box.size.width / 2;
      }
    }
    _updateState(() {
      _showSettingsPanel = true;
      _settingsPanelInitialView = view;
      _settingsPanelAnchorX = anchorX;
    });
  }

  void _turnLandscape() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _tilt = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 300),
    ).listen((event) {
      // The side it's held on (named the other way round on an iPhone:
      // see landscapeSideFor). In between — held upright, or lying flat —
      // stays on the current side.
      final side = landscapeSideFor(event.x);
      if (side == null || side == _landscapeSide || _closing) return;
      _landscapeSide = side;
      SystemChrome.setPreferredOrientations([side]);
    }, onError: (_) {}); // No sensor: the system picks the side.
  }

  /// Closes the player: first turning the phone back to portrait over
  /// black, so the page it goes back to is never seen sideways.
  Future<void> _close() async {
    if (_closing) return;
    _updateState(() => _closing = true);
    _orientationHandedOn = true;
    _tilt?.cancel();
    // Where they'd got to, saved before stopping: stop() reports the
    // position as 0, which would otherwise be saved as the progress (the
    // position listener ignores it too, now _closing is set).
    _finishedAtClose = !_switchingQuality && _finishedWatching;
    _finalSave = _saveProgress(force: true);
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
      if (_PlayerScreenState._canTurn && mounted) {
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

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (_isPlaying && !_loadingVideo) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        // Not mid-seek either, while its ring is showing — nor while a
        // menu's open: the seek bar and buttons stay with it (a mouse
        // moving over the video restarts this timer meanwhile).
        if (mounted &&
            _isPlaying &&
            !_loadingVideo &&
            !_seekPending &&
            !_showSettingsPanel &&
            // Nor while a TV's seek pointer is out: the spot picked
            // stays until OK or Back.
            _tvScrubTarget.value == null) {
          _updateState(() => _controlsVisible = false);
          // On a TV, off the buttons as they go: the arrows skip again.
          if (TvDevice.isTv) _rootFocus.requestFocus();
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
  bool get _episodeCoversVideo => _showEpisodeDrawer && !playerIsWide(context);

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
        _updateState(() => _flashIcon = Icons.play_arrow_rounded);
        _playPauseFlash.forward(from: 0);
      }
      return;
    }

    final width = MediaQuery.of(context).size.width;
    final inMiddle = position.dx > width / 3 && position.dx < width * 2 / 3;
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
      _updateState(() => _controlsVisible = true);
    }
    _resetControlsTimer();
  }

  void _toggleControls() {
    // While paused, or still loading, the controls stay up (neither screen
    // is dismissible).
    if (!_isPlaying || _loadingVideo) {
      _updateState(() => _controlsVisible = true);
      return;
    }
    _updateState(() => _controlsVisible = !_controlsVisible);
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

  void _showResumeBadge(String text) {
    _updateState(() => _resumeBadge = text);
    _resumeBadgeTimer?.cancel();
    _resumeBadgeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _updateState(() => _resumeBadge = null);
    });
  }

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
                reducedTint: Colors.black,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: ShapeDecoration(
                    color: glassTint(context),
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
    _updateState(() => _speedBoost = true);
    _syncMediaSessionPlaybackState(); // Its position now moves at 2x.
  }

  void _endSpeedBoost() {
    if (!_speedBoost) return;
    player.setRate(1.0);
    _updateState(() => _speedBoost = false);
    _syncMediaSessionPlaybackState();
  }

  void _playPause() {
    // Mid-switch the player is held paused: playing would start the old
    // video again under the loading overlay. The choice is kept for when
    // the new one's in instead.
    if (_switchingQuality) {
      _updateState(() => _heldByViewer = !_heldByViewer);
      return;
    }
    if (_isPlaying) {
      _heldByViewer = true;
      player.pause();
    } else {
      _heldByViewer = false;
      player.play();
    }
    // Flash what just happened in the middle of the screen, since the
    // play/pause button itself is tucked into the bottom bar.
    _updateState(() => _flashIcon =
        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded);
    _playPauseFlash.forward(from: 0);
  }

  void _skipBackward({bool flash = false}) =>
      _skipBy(const Duration(seconds: -10), flash: flash);

  void _skipForward({bool flash = false}) =>
      _skipBy(const Duration(seconds: 10), flash: flash);

  void _seekThrottled(Duration target) {
    if (_skipSeekTimer?.isActive ?? false) {
      _pendingSkipSeek = target;
      return;
    }
    _seekTo(target);
    _skipSeekTimer = Timer(_PlayerScreenState._skipSeekGap, _flushSkipSeek);
  }

  void _flushSkipSeek() {
    final target = _pendingSkipSeek;
    if (target == null || !mounted) return;
    _seekTo(target);
    _skipSeekTimer = Timer(_PlayerScreenState._skipSeekGap, _flushSkipSeek);
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
      _updateState(() {
        // Not on a TV: only OK brings them up there.
        if (!TvDevice.isTv) _controlsVisible = true;
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

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
