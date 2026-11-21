part of '../player_screen.dart';

extension _PlayerBottomBar on _PlayerScreenState {
  Widget _buildBottomBar(BuildContext context,
          {required bool wide,
          required EdgeInsets safe,
          required bool nextEpisodePlayable}) =>
      Positioned(
        bottom: (wide ? 24 : 16) + MediaQuery.of(context).padding.bottom,
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
              _buildSeekBar(wide: wide),
              // Timestamps + next episode row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    // Play / pause, ringed by the loading
                    // spinner while opening, buffering or
                    // seeking
                    _buildPlayPauseButton(wide: wide),
                    SizedBox(width: wide ? 4 : 2),
                    // Volume button + expandable slider:
                    // the desktop app's only. A phone
                    // has its own volume buttons.
                    if (isComputer) _buildVolumeControl(wide: wide),
                    if (isComputer) SizedBox(width: wide ? 8 : 4),
                    _buildTimestamps(wide: wide),
                    const SizedBox(width: 8),
                    // The buttons, at the right: shrunk
                    // to fit when the window's too
                    // narrow for them (a computer's
                    // window made phone-narrow overflowed
                    // by 108px).
                    _buildPlayerActions(
                        wide: wide, nextEpisodePlayable: nextEpisodePlayable),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildSeekBar({required bool wide}) => ListenableBuilder(
        listenable: Listenable.merge([
          _positionNotifier,
          _durationNotifier,
          _bufferNotifier,
          _seekHoverFractionNotifier,
          _timelinePartitionRevision,
          _tvScrubTarget,
        ]),
        builder: (context, _) {
          final dur = _durationNotifier.value;
          final totalSeconds = dur.inSeconds.toDouble();
          final hoverFraction = _seekHoverFractionNotifier.value;
          final dragFraction = (_isDragging && totalSeconds > 0)
              ? (_positionNotifier.value.inSeconds / totalSeconds)
                  .clamp(0.0, 1.0)
              : null;
          // A TV's seek pointer, moved (see
          // _onTvScrubKey).
          final scrubTarget = _tvScrubTarget.value;
          final scrubbing = scrubTarget != null && totalSeconds > 0;
          final scrubFraction = scrubbing
              ? (scrubTarget.inSeconds / totalSeconds).clamp(0.0, 1.0)
              : null;
          final activeFraction = scrubFraction ?? dragFraction ?? hoverFraction;
          final showTooltip =
              !_loadingVideo && totalSeconds > 0 && activeFraction != null;
          final tooltipDuration = showTooltip
              ? Duration(
                  seconds: (activeFraction * totalSeconds)
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
              final targetX = pad + f * trackWidth;
              final halfPill = tooltipLabel != null
                  ? (scrubbing ? 140.0 : 110.0)
                  : (scrubbing ? 64.0 : 44.0);
              final barFocused = TvDevice.isTv && _seekBarFocus.hasFocus;
              final clampedCenter = targetX.clamp(
                halfPill,
                math.max(
                  halfPill,
                  constraints.maxWidth - halfPill,
                ),
              );

              // Selectable with a TV remote, up
              // from the buttons (see _onTvKey);
              // the slider itself never is.
              return Focus(
                focusNode: _seekBarFocus,
                canRequestFocus: TvDevice.isTv && !_loadingVideo,
                skipTraversal: !TvDevice.isTv,
                onFocusChange: (_) => _updateState(() {}),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (showTooltip)
                      _buildSeekTooltip(context,
                          wide: wide,
                          scrubbing: scrubbing,
                          clampedCenter: clampedCenter,
                          halfPill: halfPill,
                          tooltipDuration: tooltipDuration,
                          tooltipLabel: tooltipLabel),
                    MouseRegion(
                      onHover: (event) {
                        final frac =
                            ((event.localPosition.dx - pad) / trackWidth)
                                .clamp(0.0, 1.0);
                        _seekHoverFractionNotifier.value = frac;
                      },
                      onExit: (_) {
                        _seekHoverFractionNotifier.value = null;
                      },
                      child: SliderTheme(
                        // The cards' progress bar: a thin
                        // cream line, with a small white dot
                        // to drag, partitioned by chapters and
                        // skip segments.
                        data: SliderThemeData(
                          trackHeight: wide ? 4.5 : 3,
                          trackShape: _PartitionedSliderTrackShape(
                            partitions: partitions,
                            skipRanges: skipRanges,
                            hoveredFraction: activeFraction,
                          ),
                          activeTrackColor: AppTheme.accent,
                          secondaryActiveTrackColor:
                              Colors.white.withValues(alpha: 0.3),
                          inactiveTrackColor:
                              Colors.white.withValues(alpha: 0.15),
                          thumbColor: Colors.white,
                          thumbShape: RoundSliderThumbShape(
                              enabledThumbRadius: wide ? 7.5 : 6,
                              elevation: 0,
                              pressedElevation: 0),
                          overlayShape: RoundSliderOverlayShape(
                              overlayRadius: wide ? 16 : 14),
                          overlayColor: Colors.white.withValues(alpha: 0.12),
                        ),
                        // No seeking until the video has
                        // loaded (see _loadingVideo).
                        child:
                            // Not for a TV remote: it took the
                            // arrows and kept them. Left and
                            // right skip there (see _onTvKey).
                            ExcludeFocus(
                                excluding: TvDevice.isTv,
                                child: IgnorePointer(
                                  ignoring: _loadingVideo,
                                  child: Slider(
                                    value:
                                        (scrubTarget ?? _positionNotifier.value)
                                            .inSeconds
                                            .toDouble()
                                            .clamp(0.0, totalSeconds),
                                    secondaryTrackValue: _bufferNotifier
                                        .value.inSeconds
                                        .toDouble()
                                        .clamp(0.0, totalSeconds),
                                    min: 0.0,
                                    max: totalSeconds > 0 ? totalSeconds : 1.0,
                                    onChangeStart: (val) {
                                      _isDragging = true;
                                    },
                                    onChanged: (val) {
                                      final d = Duration(seconds: val.toInt());
                                      _currentPosition = d;
                                      _positionNotifier.value = d;
                                    },
                                    onChangeEnd: (val) {
                                      _isDragging = false;
                                      _seekTo(Duration(seconds: val.toInt()));
                                      _syncMediaSessionPlaybackState();
                                    },
                                  ),
                                )),
                      ),
                    ),
                    // The bar selected with a TV
                    // remote: outlined, as a button.
                    if (barFocused && !scrubbing) _buildTvSeekFocusOutline(pad),
                    // Its pointer selected: ringed,
                    // an arrow either side.
                    if (scrubbing) _buildTvSeekPointer(targetX),
                  ],
                ),
              );
            },
          );
        },
      );

  Widget _buildSeekTooltip(BuildContext context,
          {required bool wide,
          required bool scrubbing,
          required num clampedCenter,
          required double halfPill,
          required Duration tooltipDuration,
          required String? tooltipLabel}) =>
      Positioned(
        left: clampedCenter - halfPill,
        width: halfPill * 2,
        bottom: scrubbing ? 44 : (wide ? 36 : 32),
        child: IgnorePointer(
          child: Center(
            child: ClipPath(
              clipper: const ShapeBorderClipper(
                shape: StadiumBorder(),
              ),
              child: GlassBlur(
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: glassTint(context),
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: kGlassEdge,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? 11 : 9,
                      vertical: wide ? 5 : 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatDuration(
                            tooltipDuration,
                          ),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: scrubbing ? 22 : (wide ? 13 : 11.5),
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        if (tooltipLabel != null) ...[
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
      );

  Widget _buildPlayPauseButton({required bool wide}) => SizedBox(
        width: wide ? 48 : 40,
        height: wide ? 48 : 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (!_switchingQuality &&
                (_isMediaOpening || _isBuffering || _seekPending))
              const Positioned.fill(
                child: CircularProgressIndicator(
                  color: Colors.white70,
                  strokeWidth: 2,
                ),
              ),
            IconButton(
              focusNode: _playButtonFocus,
              onPressed: _playPause,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              icon: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: wide ? 34 : 24,
              ),
            ),
          ],
        ),
      );

  Widget _buildVolumeControl({required bool wide}) => MouseRegion(
        onEnter: (_) => _updateState(() => _volumeHover = true),
        onExit: (_) => _updateState(() => _volumeHover = false),
        child: ValueListenableBuilder<double>(
          valueListenable: _volumeNotifier,
          builder: (context, volume, _) {
            final showSlider =
                _volumeHover || _volumeDragging || _volumeRecentlyAdjusted;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: wide ? 44 : 38,
                  height: wide ? 44 : 38,
                  child: IconButton(
                    onPressed: () => _toggleMute(),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      _volumeIconFor(volume),
                      color: Colors.white,
                      size: wide ? 28 : 22,
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  width: showSlider ? (wide ? 104 : 84) : 0,
                  child: ClipRect(
                    child: ExcludeFocus(
                        excluding: TvDevice.isTv,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: wide ? 4 : 3,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.24),
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
                          child: Slider(
                            value: volume,
                            min: 0.0,
                            max: 100.0,
                            onChangeStart: (_) {
                              _updateState(() => _volumeDragging = true);
                            },
                            onChanged: (val) {
                              _setVolume(
                                val,
                                persist: false,
                              );
                            },
                            onChangeEnd: (val) {
                              _updateState(() => _volumeDragging = false);
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
      );

  Widget _buildTimestamps({required bool wide}) => ListenableBuilder(
        listenable: Listenable.merge([_positionNotifier, _durationNotifier]),
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatDuration(_positionNotifier.value),
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
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );

  Widget _buildPlayerActions(
          {required bool wide, required bool nextEpisodePlayable}) =>
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
                    // The quality playing.
                    label: _qualityLabel,
                    selected: _menuOpen('quality'),
                    onPressed: () =>
                        _toggleSettingsPanel('quality', _qualityButtonKey),
                  )),
                  // English or the original, for a
                  // title not made in English.
                  if (AudioLanguageService.appliesTo(widget.details)) ...[
                    const SizedBox(width: 10),
                    _menuButton(GlassPillButton(
                      grouped: true,
                      key: _audioButtonKey,
                      icon: Icons.record_voice_over_rounded,
                      label: 'Audio',
                      selected: _menuOpen('audio'),
                      busy: _changingAudio,
                      onPressed: () =>
                          _toggleSettingsPanel('audio', _audioButtonKey),
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
                        _toggleSettingsPanel('subtitles', _subtitlesButtonKey),
                  )),
                  const SizedBox(width: 10),
                  _menuButton(GlassPillButton(
                    grouped: true,
                    key: _videoSizeButtonKey,
                    icon: _videoFit.icon,
                    label: 'Video Size',
                    selected: _menuOpen('videoSize'),
                    onPressed: () =>
                        _toggleSettingsPanel('videoSize', _videoSizeButtonKey),
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
                        _toggleSettingsPanel('main', _settingsButtonKey),
                  )),
                if (widget.details.type == 'tv') ...[
                  const SizedBox(width: 10),
                  // In the panel's group: its own
                  // press toggles it, rather than
                  // counting as a click outside.
                  TapRegion(
                    groupId: EpisodeBrowser.panelTapGroup,
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
                    onPressed: nextEpisodePlayable ? _playNextEpisode : null,
                  ),
                ],
                if (WindowFullScreen.supported) ...[
                  const SizedBox(width: 10),
                  ValueListenableBuilder<bool>(
                    valueListenable: WindowFullScreen.state,
                    builder: (context, isFullScreen, _) => GlassCircleButton(
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
      );
}
