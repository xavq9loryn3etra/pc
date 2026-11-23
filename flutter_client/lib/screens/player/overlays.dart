part of '../player_screen.dart';

extension _PlayerOverlays on _PlayerScreenState {
  /// In the subtitles' place while they can't be shown yet (see
  /// _subtitleActivityLabel): a quiet grey bar saying why, with a slow
  /// shimmer across its words — where the subtitles sit, moving with them.
  Widget _buildSubtitleActivity(TextScaler textScaler, String label) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<double>(
          valueListenable: _subtitleBottom,
          builder: (context, bottom, child) => AnimatedPadding(
            padding: EdgeInsets.only(bottom: bottom),
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 250),
            child: Align(alignment: Alignment.bottomCenter, child: child),
          ),
          child: _SubtitleActivityBar(
            label: label,
            // A third smaller than a subtitle line: a note, not dialogue.
            fontSize: textScaler.scale(38) * 0.62,
            // Out of sight while paused, as the subtitles are.
            visible: _isPlaying,
          ),
        ),
      ),
    );
  }

  Widget _buildPlaybackFlash({required bool wide}) => IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: _playPauseFlash,
            builder: (context, child) {
              final t = _playPauseFlash.value;
              final fade = t < 0.3 ? 1.0 : 1 - (t - 0.3) / 0.7;
              return Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.85 + 0.3 * Curves.easeOut.transform(t),
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
              child:
                  Icon(_flashIcon, color: Colors.white, size: wide ? 56 : 48),
            ),
          ),
        ),
      );

  Widget _buildSwitchingOverlay() => ColoredBox(
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
      );

  List<Widget> _buildControlGradients() => [
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
                Colors.black.withOpacity(_isPlaying ? 0.8 : 0.92),
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
      ];

  Widget _buildPausedDetails(
          {required bool wide, required EdgeInsets safe, required Size size}) =>
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
              opacity: (!_isPlaying && _controlsVisible) ? 1.0 : 0.0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title or Logo
                  if (widget.details.logoUrl != null &&
                      widget.details.logoUrl!.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: wide ? 10 : 6),
                      child: CachedNetworkImage(
                        imageUrl: widget.details.logoUrl!,
                        height: wide ? 120 : 64,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                        errorWidget: (context, url, error) {
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
                    if (_playingEpisode?.name case final name?
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
                    (_playingEpisode?.overview ?? '').isNotEmpty
                        ? _playingEpisode!.overview
                        : widget.movie.description,
                    maxLines: wide ? 4 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: wide ? Colors.white70 : Colors.white60,
                      fontSize: wide ? 18 : 13,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  List<Widget> _buildPlaybackBadges({required EdgeInsets safe}) => [
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
            Text('Reconnecting…', style: _PlayerScreenState._badgeTextStyle),
          ],
        ),

        // "Resumed from 12:34" for a moment after picking up
        // where the viewer left off (see _showResumeBadge).
        _glassBadge(
          top: 16 + safe.top,
          visible: _resumeBadge != null && !_speedBoost,
          children: [
            const Icon(Icons.replay_rounded, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(_resumeBadge ?? '', style: _PlayerScreenState._badgeTextStyle),
          ],
        ),

        // "2× ⏩" while a press-and-hold speeds playback up
        // (see _startSpeedBoost) — shown whether or not the
        // controls are.
        _glassBadge(
          top: 16 + safe.top,
          visible: _speedBoost,
          children: const [
            Text('2×', style: _PlayerScreenState._badgeTextStyle),
            SizedBox(width: 6),
            Icon(Icons.fast_forward_rounded, color: Colors.white, size: 16),
          ],
        ),
      ];

  Widget _buildSkipOrUpNext({required bool wide, required EdgeInsets safe}) =>
      ListenableBuilder(
        listenable: Listenable.merge(
            [_activeSkipSegmentNotifier, _upNextShown, _upNextStage]),
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
                            // The credits, a preview after
                            // them: on to it. During the
                            // preview: Next Episode alone.
                            // Otherwise: Watch Credits.
                            if (_upNextStage.value == UpNextStage.credits) ...[
                              GlassPillButton(
                                grouped: true,
                                label: 'Skip Credits',
                                onPressed: () {
                                  final to = UpNextPlan.at(_skipSegments,
                                          _duration, _currentPosition)
                                      .previewStart;
                                  if (to != null) {
                                    _skipCreditsToPreview(to);
                                  }
                                },
                              ),
                              const SizedBox(width: 10),
                            ] else if (_upNextStage.value !=
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
                          label: segment?.type.buttonLabel ?? 'Skip Intro',
                          onPressed: segment == null
                              ? null
                              : () => _skipActiveSegment(segment),
                        ),
                ),
              ),
            ),
          );
        },
      );

  Widget _buildSettingsPanel(BuildContext context) => Positioned.fill(
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
          // A language, or off: which copy of it is the app's to pick
          // (the best timed one), and to swap if another fits better.
          subtitleSyncing: _resyncing != null ||
              _subtitleTiming == _SubtitleTiming.checking,
          onResyncSubtitles:
              _selectedSubtitle == null || _selectedSubtitle!.isEmbedded
                  ? null
                  : _resyncSubtitles,
          onSubtitleSelected: (track) {
            final copy = track == null
                ? null
                : _bestSubtitleIn(_getLanguageName(track.lang)) ?? track;
            if (copy == null || copy.id != _selectedSubtitle?.id) {
              _selectSubtitle(copy);
            }
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
          unavailableAudio: _noAudioIn,
          audioChanging: _changingAudio,
          subtitleSyncNote: _subtitleSyncNote,
          subtitleFitNote: _subtitleFitNote,
          subtitleFollows: _subtitleFollows,
          anchorCenterX: _settingsPanelAnchorX,
          initialView: _settingsPanelInitialView,
          closeRequests: _settingsCloseRequests,
          // Level with the episode panel's foot on a wide window.
          bottom: playerIsWide(context)
              ? _bottomBarClearance(MediaQuery.sizeOf(context))
              : null,
          onClose: () {
            _updateState(() {
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
      );
}

/// The bar of _buildSubtitleActivity: shown only after a few seconds (a
/// short wait flashes nothing), faded in and out.
class _SubtitleActivityBar extends StatefulWidget {
  final String label;
  final double fontSize;
  final bool visible;

  const _SubtitleActivityBar({
    required this.label,
    required this.fontSize,
    required this.visible,
  });

  @override
  State<_SubtitleActivityBar> createState() => _SubtitleActivityBarState();
}

class _SubtitleActivityBarState extends State<_SubtitleActivityBar>
    with SingleTickerProviderStateMixin {
  static const _after = Duration(seconds: 3);
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  Timer? _wait;
  bool _due = false;

  @override
  void initState() {
    super.initState();
    _wait = Timer(_after, () {
      if (mounted) setState(() => _due = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sinhala = RegExp(r'[\u0D80-\u0DFF]').hasMatch(widget.label);
    final style = TextStyle(
      fontSize: widget.fontSize,
      height: 1.3,
      fontWeight: FontWeight.w500,
      color: Colors.white,
      fontFamily: sinhala ? 'NotoSansSinhala' : null,
    );
    final text = Text(
      widget.label,
      textScaler: TextScaler.noScaling,
      style: style,
    );
    return Semantics(
      label: widget.label,
      liveRegion: true,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: _due && widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 400),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x66000000),
            borderRadius: BorderRadius.circular(widget.fontSize * 0.4),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.fontSize * 0.7,
              vertical: widget.fontSize * 0.25,
            ),
            child: AnimatedBuilder(
              animation: _shimmer,
              child: text,
              builder: (context, child) {
                // Grey words, a soft lighter band passing across them.
                final x = _shimmer.value * 3 - 1;
                return ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) => LinearGradient(
                    begin: Alignment(x - 0.6, 0),
                    end: Alignment(x + 0.6, 0),
                    colors: const [
                      Color(0x80FFFFFF),
                      Color(0xD9FFFFFF),
                      Color(0x80FFFFFF),
                    ],
                  ).createShader(bounds),
                  child: child,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
