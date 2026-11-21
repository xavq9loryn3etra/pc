part of '../player_screen.dart';

extension _PlayerTvControls on _PlayerScreenState {
  /// Whether one of the player's buttons has a TV remote's selection.
  bool get _tvButtonFocused {
    final focused = FocusManager.instance.primaryFocus;
    return focused != null &&
        focused != _rootFocus &&
        focused.ancestors.contains(_rootFocus);
  }

  /// A TV remote, as TV apps' players take it. The remote's own play,
  /// pause, fast-forward and rewind buttons work whatever's showing. With
  /// none of the player's buttons selected, left and right skip (the
  /// controls staying away: only OK brings them up), OK brings the
  /// controls up with the play button selected (the film playing on), and
  /// once they're up, up or down selects the play button; on the buttons, the arrows move
  /// between them and OK presses one, as anywhere else in the app (see
  /// TvTraversalPolicy) — until the controls fade, when the arrows skip
  /// again. A menu (subtitles & audio, the episodes) takes the arrows while
  /// it's open. Volume is the TV's own (its remote's volume buttons), not
  /// up and down as on a computer. Back: see the PopScope in build.
  bool _onTvKey(KeyEvent event) {
    final key = event.logicalKey;
    final pressed = event is KeyDownEvent;

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      final wanted = key == LogicalKeyboardKey.mediaPlayPause ||
          (key == LogicalKeyboardKey.mediaPlay) != _isPlaying;
      if (pressed && wanted && !_loadingVideo && !_episodeCoversVideo) {
        _playPause();
        _showTvControls();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      if (!_loadingVideo && !_episodeCoversVideo) _skipForward(flash: true);
      return true;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      if (!_loadingVideo && !_episodeCoversVideo) _skipBackward(flash: true);
      return true;
    }

    if (_showSettingsPanel || _showEpisodeDrawer) return false;

    // The seek bar's pointer selected: it takes the arrows and OK.
    if (_tvScrubTarget.value != null) return _onTvScrubKey(event);
    // The seek bar selected: OK selects its pointer; left and right do
    // nothing yet (no seek by accident); up and down move on as anywhere.
    if (_controlsVisible && _seekBarFocus.hasFocus) {
      _resetControlsTimer();
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (pressed) _startTvScrub();
        return true;
      }
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return true;
      }
      return false;
    }

    if (_controlsVisible && _tvButtonFocused) {
      _resetControlsTimer();
      return false;
    }

    // OK, as Netflix's: the controls up, the film playing on, the play
    // button selected — OK again (on it) pauses. Up already (paused, or by
    // the remote's own play button) with nothing selected: as the play
    // button, and onto it.
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (pressed && !_loadingVideo) {
        if (_controlsVisible) _playPause();
        _showTvControls(selectPlay: true);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (!_loadingVideo) _skipBackward(flash: true);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (!_loadingVideo) _skipForward(flash: true);
      return true;
    }
    // Only OK brings the controls up; once they're up (none of their
    // buttons selected yet), up or down selects the play button.
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (pressed && _controlsVisible) _showTvControls(selectPlay: true);
      return true;
    }
    return false;
  }

  /// On a TV, with the player itself selected (none of its buttons): the
  /// arrows and OK are spent here — _onTvKey has already acted on them.
  /// Every key also goes on to the app's own handling, which moves the
  /// selection with the arrows: with the controls up, a right arrow meant
  /// to skip moved it onto the buttons instead (and the presses after it
  /// moved along them).
  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (!TvDevice.isTv ||
        !node.hasPrimaryFocus ||
        _showSettingsPanel ||
        _showEpisodeDrawer) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The seek bar's pointer, selected (see _seekBarFocus): left and right
  /// move it — 10 s a press; held, faster the longer it's held — while
  /// the video plays on where it was, and nothing's fetched for the spots
  /// passed over; OK plays from it; Back (see the PopScope in build) puts
  /// it back. Up and down do nothing meanwhile: OK or Back first.
  bool _onTvScrubKey(KeyEvent event) {
    final key = event.logicalKey;
    final left = key == LogicalKeyboardKey.arrowLeft;
    if (left || key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyUpEvent) {
        _tvScrubHeldSince = null;
      } else {
        _moveTvScrub(left ? -1 : 1, held: event is KeyRepeatEvent);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) _commitTvScrub();
      return true;
    }
    return true;
  }

  void _startTvScrub() {
    if (_loadingVideo || _duration <= Duration.zero) return;
    _controlsTimer?.cancel();
    _tvScrubHeldSince = null;
    _tvScrubLastMove = null;
    _updateState(() => _tvScrubTarget.value = _currentPosition);
  }

  /// A held arrow repeats some 20–30 times a second: a move at most every
  /// 120 ms, of 10 s for the first second and a half, then 30 s, then a
  /// minute from 3½ s on — about a minute, then four, then eight of video
  /// a second.
  void _moveTvScrub(int direction, {required bool held}) {
    final target = _tvScrubTarget.value;
    if (target == null) return;
    final now = DateTime.now();
    if (!held) {
      _tvScrubHeldSince = now;
    } else {
      _tvScrubHeldSince ??= now;
      final last = _tvScrubLastMove;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 120)) {
        return;
      }
    }
    _tvScrubLastMove = now;
    final heldFor = now.difference(_tvScrubHeldSince!);
    final seconds = !held || heldFor < const Duration(milliseconds: 1500)
        ? 10
        : heldFor < const Duration(milliseconds: 3500)
            ? 30
            : 60;
    var next = target + Duration(seconds: seconds * direction);
    if (next < Duration.zero) next = Duration.zero;
    if (next > _duration) next = _duration;
    _tvScrubTarget.value = next;
  }

  /// OK on the pointer: the video plays from where it was moved to; the
  /// seek bar stays selected.
  void _commitTvScrub() {
    final target = _tvScrubTarget.value;
    if (target == null) return;
    _updateState(() => _tvScrubTarget.value = null);
    if (target != _currentPosition) {
      _currentPosition = target;
      _positionNotifier.value = target;
      _seekTo(target);
      _syncMediaSessionPlaybackState();
    }
    _resetControlsTimer();
  }

  /// Back on the pointer: put back where the video is; nothing moves.
  void _cancelTvScrub() {
    _updateState(() => _tvScrubTarget.value = null);
    _resetControlsTimer();
  }

  /// The controls up, for their usual few seconds — with the play button
  /// selected ([selectPlay]) once they're there to be selected.
  void _showTvControls({bool selectPlay = false}) {
    _updateState(() => _controlsVisible = true);
    _resetControlsTimer();
    if (selectPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsVisible) _playButtonFocus.requestFocus();
      });
    }
  }

  Widget _buildTvWaitIndicator() => const IgnorePointer(
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
      );

  Widget _buildTvSeekFocusOutline(double pad) => Positioned(
        left: pad - 12,
        right: pad - 12,
        top: 2,
        bottom: 2,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white, width: 2.5),
            ),
          ),
        ),
      );

  Widget _buildTvSeekPointer(double targetX) => Positioned(
        left: targetX - 52,
        width: 104,
        top: 0,
        bottom: 0,
        child: const IgnorePointer(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.arrow_left_rounded, color: Colors.white, size: 30),
              SizedBox(
                width: 30,
                height: 30,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                        BorderSide(color: Colors.white, width: 2.5)),
                  ),
                ),
              ),
              Icon(Icons.arrow_right_rounded, color: Colors.white, size: 30),
            ],
          ),
        ),
      );
}
