import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'floating_bottom_nav_bar.dart' show playerIsWide;
import 'glass_blur.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import 'quality_option_list.dart';
import '../services/subtitle_service.dart';
import '../models/movie.dart';
import '../services/audio_language_service.dart';
import '../services/gemini_key_service.dart';

/// How the video is scaled to the screen.
enum VideoFit {
  fit(BoxFit.contain, 'Fit', 'Whole picture, with black bars',
      Icons.fit_screen_rounded),
  fill(BoxFit.cover, 'Fill', 'Fill the screen, cropping the edges',
      Icons.crop_free_rounded);

  final BoxFit boxFit;
  final String label;
  final String description;
  final IconData icon;

  const VideoFit(this.boxFit, this.label, this.description, this.icon);
}

/// A premium, sliding right-side panel for unified player settings (Quality,
/// Audio, Subtitles and Video size).
///
/// Provides a sleek settings-menu style interface with sliding animated transitions
/// and a high-end semi-transparent glassmorphic look.
class PlayerSettingsPanel extends StatefulWidget {
  final List<SubtitleTrackData> availableSubtitles;
  final SubtitleTrackData? selectedSubtitle;
  final bool isLoadingSubtitles;
  final ValueChanged<SubtitleTrackData?> onSubtitleSelected;
  final String Function(String) getLanguageName;

  /// How far Sinhala made from English has got (0 to 1), and why it
  /// stopped if it did; null when none's being made.
  final double? sinhalaProgress;
  final String? sinhalaProblem;

  final List<TorrentStream> availableStreams;
  final TorrentStream currentStream;
  final ValueChanged<TorrentStream> onStreamSelected;

  final VideoFit videoFit;
  final ValueChanged<VideoFit> onVideoFitSelected;

  /// The title playing, when it gets a choice of audio language (one not
  /// made in English — see AudioLanguageService); null hides Audio.
  final Movie? audioTitle;
  final ValueChanged<AudioLanguage>? onAudioLanguageSelected;

  /// A change of audio language is being carried out: no other meanwhile.
  final bool audioChanging;

  final double subtitleDelaySeconds;
  final ValueChanged<double> onSubtitleDelayChanged;
  final double subtitleSpeed;
  final ValueChanged<double> onSubtitleSpeedChanged;

  /// A quiet word under the timing on Auto Sync ("Synced"), or null — see
  /// PlayerScreen._subtitleSyncNote.
  final String? subtitleSyncNote;

  /// The subtitles shown are being synced: their timing's controls are
  /// covered (and can't be used) until that's done.
  final bool subtitleSyncing;
  final double? anchorCenterX;

  final VoidCallback onClose;
  final String initialView; // 'main', 'subtitles', 'quality', 'audio', 'videoSize'

  /// Closes the popup (animated) each time it notifies — the player's way
  /// to close it: its menu button pressed again, or Esc.
  final Listenable? closeRequests;

  /// The popup's TapRegion group. The player's menu buttons join it, so a
  /// click on one isn't "outside" the popup: the button decides (closes its
  /// own menu, or opens another in its place).
  static const Object tapGroup = #playerSettingsMenu;

  /// Where the popup's bottom sits, up from the screen's: on a computer's
  /// wide window, just above the whole bottom bar (seek bar and all), level
  /// with the episode panel's foot. Null: just over the bar's buttons.
  final double? bottom;

  const PlayerSettingsPanel({
    super.key,
    required this.availableSubtitles,
    required this.selectedSubtitle,
    required this.isLoadingSubtitles,
    required this.onSubtitleSelected,
    required this.getLanguageName,
    this.sinhalaProgress,
    this.sinhalaProblem,
    required this.availableStreams,
    required this.currentStream,
    required this.onStreamSelected,
    required this.videoFit,
    required this.onVideoFitSelected,
    this.audioTitle,
    this.onAudioLanguageSelected,
    this.audioChanging = false,
    this.subtitleDelaySeconds = 0.0,
    required this.onSubtitleDelayChanged,
    this.subtitleSpeed = 1.0,
    required this.onSubtitleSpeedChanged,
    this.subtitleSyncNote,
    this.subtitleSyncing = false,
    this.anchorCenterX,
    required this.onClose,
    this.initialView = 'main',
    this.closeRequests,
    this.bottom,
  });

  @override
  State<PlayerSettingsPanel> createState() => _PlayerSettingsPanelState();
}

class _PlayerSettingsPanelState extends State<PlayerSettingsPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;
  late String _currentView;

  @override
  void initState() {
    super.initState();
    _currentView = widget.initialView;

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _scaleAnimation = Tween<double>(
      begin: 0.94,
      end: 1.0,
    ).animate(_fadeAnimation);

    _slideController.forward();
    widget.closeRequests?.addListener(_close);
  }

  @override
  void didUpdateWidget(covariant PlayerSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialView != widget.initialView) {
      _currentView = widget.initialView;
    }
    if (oldWidget.closeRequests != widget.closeRequests) {
      oldWidget.closeRequests?.removeListener(_close);
      widget.closeRequests?.addListener(_close);
    }
  }

  @override
  void dispose() {
    widget.closeRequests?.removeListener(_close);
    _slideController.dispose();
    super.dispose();
  }

  bool _closing = false;

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    _slideController.reverse().then((_) {
      if (mounted) widget.onClose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final wide = playerIsWide(context);
    final double panelWidth =
        wide ? 340.0 : (size.width * 0.42).clamp(280.0, 330.0);
    final double maxPanelHeight =
        (size.height * (wide ? 0.62 : 0.72)).clamp(220.0, 480.0);
    final double minLeft = (wide ? 32 : 24) + safe.left;
    final double maxLeft =
        (size.width - (wide ? 32 : 24) - safe.right - panelWidth)
            .clamp(minLeft, size.width);
    final double? anchoredLeft = widget.anchorCenterX != null
        ? (widget.anchorCenterX! - panelWidth / 2).clamp(minLeft, maxLeft)
        : null;

    return Stack(
      children: [
        // No backdrop: a tap or click anywhere outside the popup closes it
        // (TapRegion below) and still lands where it was aimed — Episodes,
        // Next, the seek bar work in one click, not one to close the popup
        // and another. (On the video itself the player ignores it while
        // the popup's open, so it doesn't also pause.) Nothing dims the
        // controls either, or the open menu's lit-up button.
        // Compact floating popup anchored directly above the clicked button
        Positioned(
          left: anchoredLeft,
          right: anchoredLeft == null ? (wide ? 32 : 24) + safe.right : null,
          bottom: widget.bottom ?? (wide ? 88 : 72) + safe.bottom,
          child: TapRegion(
            groupId: PlayerSettingsPanel.tapGroup,
            onTapOutside: (_) => _close(),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                alignment: anchoredLeft != null
                    ? Alignment.bottomCenter
                    : Alignment.bottomRight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  // Its own 85% tint needs no extra when the blur is reduced.
                  child: GlassBlur(
                    sigma: 16,
                    reducedTint: Colors.transparent,
                    child: Container(
                      width: panelWidth,
                      constraints: BoxConstraints(maxHeight: maxPanelHeight),
                      decoration: BoxDecoration(
                        color: kGlassSheetTint,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: kGlassEdge, width: 0.5),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(),
                          const Divider(color: Colors.white12, height: 1),
                          Flexible(
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  );
                                },
                                child: _buildCurrentView(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    String title = 'Player Settings';
    if (_currentView == 'subtitles') {
      title = 'Subtitles';
    } else if (_currentView == 'quality') {
      title = 'Quality';
    } else if (_currentView == 'videoSize') {
      title = 'Video Size';
    } else if (_currentView == 'audio') {
      title = 'Audio';
    }

    final Widget? leftButton =
        (widget.initialView == 'main' && _currentView != 'main')
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: Colors.white70, size: 16),
                onPressed: () => setState(() => _currentView = 'main'),
              )
            : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (leftButton != null) ...[
            leftButton,
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: Colors.white60, size: 20),
            onPressed: _close,
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentView() {
    switch (_currentView) {
      case 'subtitles':
        return _buildSubtitlesView();
      case 'quality':
        return _buildQualityView();
      case 'videoSize':
        return _buildVideoSizeView();
      case 'audio':
        return _buildAudioView();
      case 'main':
      default:
        return _buildMainMenuView();
    }
  }

  Widget _buildMainMenuView() {
    final activeSubtitleLabel = widget.selectedSubtitle != null
        ? widget.getLanguageName(widget.selectedSubtitle!.lang)
        : (widget.isLoadingSubtitles ? 'Loading…' : 'Off');
    const chevron =
        Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20);

    return ListView(
      key: const ValueKey('main-settings'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      children: [
        _buildGroup([
          _buildRow(
            icon: Icons.hd_rounded,
            title: 'Quality',
            subtitle: QualityOption(
              StreamResolver.tierOf(widget.currentStream),
              [widget.currentStream],
            ).name,
            trailing: chevron,
            onTap: () => setState(() => _currentView = 'quality'),
          ),
          if (widget.audioTitle != null)
            _buildRow(
              icon: Icons.record_voice_over_rounded,
              title: 'Audio',
              subtitle: AudioLanguageService()
                  .languageFor(widget.audioTitle!)
                  .name,
              trailing: chevron,
              onTap: () => setState(() => _currentView = 'audio'),
            ),
          _buildRow(
            icon: Icons.subtitles_rounded,
            title: 'Subtitles',
            subtitle: activeSubtitleLabel,
            trailing: chevron,
            onTap: () => setState(() => _currentView = 'subtitles'),
          ),
          _buildRow(
            icon: widget.videoFit.icon,
            title: 'Video Size',
            subtitle: widget.videoFit.label,
            trailing: chevron,
            onTap: () => setState(() => _currentView = 'videoSize'),
          ),
        ]),
      ],
    );
  }

  /// English or the original soundtrack — saved for the whole series.
  Widget _buildAudioView() {
    final title = widget.audioTitle;
    if (title == null) return const SizedBox.shrink();
    final current = AudioLanguageService().of(title);
    final original = AudioLanguageService.originalOf(title);
    Widget row(AudioLanguage choice, String name, String description) =>
        _buildRow(
          title: name,
          subtitle: description,
          trailing: choice == current
              ? (widget.audioChanging
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white70),
                    )
                  : _check)
              : null,
          onTap: () {
            if (widget.audioChanging || choice == current) return;
            widget.onAudioLanguageSelected?.call(choice);
          },
        );
    return ListView(
      key: const ValueKey('audio-settings'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      children: [
        _buildGroup([
          row(AudioLanguage.original, original.name, 'Original soundtrack'),
          row(AudioLanguage.english, 'English', 'Dubbed, where available'),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            'Kept for the whole series.',
            style: TextStyle(color: Colors.white38, fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoSizeView() {
    return ListView(
      key: const ValueKey('video-size-settings'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      children: [
        _buildGroup([
          for (final fit in VideoFit.values)
            _buildRow(
              title: fit.label,
              subtitle: fit.description,
              trailing: fit == widget.videoFit ? _check : null,
              // Stays open, like Subtitles, so the change can be seen
              // behind the panel.
              onTap: () => widget.onVideoFitSelected(fit),
            ),
        ]),
      ],
    );
  }

  static const _check =
      Icon(Icons.check_rounded, color: Colors.white, size: 20);
  static const _groupRadius = BorderRadius.all(Radius.circular(16));

  /// The panel's lists, in the quality list's style (see
  /// QualityOptionList): one rounded panel with a faint edge, its rows
  /// split by hairlines.
  Widget _buildGroup(List<Widget> rows) {
    return ClipRRect(
      borderRadius: _groupRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: _groupRadius,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Container(
                    height: 0.5,
                    margin: const EdgeInsets.only(left: 16),
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow({
    IconData? icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final row = InkWell(
      mouseCursor: enabled
          ? WidgetStateMouseCursor.clickable
          : SystemMouseCursors.basic,
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white70, size: 20),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing,
            ],
          ],
        ),
      ),
    );
    return enabled ? row : Opacity(opacity: 0.4, child: row);
  }

  Widget _buildSubtitlesView() {
    // Several external tracks often share a language — number those so they
    // can be told apart. Embedded tracks keep their track title/tag.
    final perLanguage = <String, int>{};
    for (final t in widget.availableSubtitles) {
      if (t.isEmbedded) continue;
      final name = widget.getLanguageName(t.lang);
      perLanguage[name] = (perLanguage[name] ?? 0) + 1;
    }
    final seen = <String, int>{};

    if (widget.availableSubtitles.isEmpty && !widget.isLoadingSubtitles) {
      return const Padding(
        key: ValueKey('subtitle-settings-empty'),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 28),
        child: Center(
          child: Text(
            'No subtitles found for this media',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    final delay = widget.subtitleDelaySeconds;
    final delayText = delay.abs() < 0.05
        ? '0.0s'
        : '${delay > 0 ? "+" : ""}${delay.toStringAsFixed(1)}s';
    final speed = widget.subtitleSpeed;

    // The timing card stays put at the top while the tracks under it
    // scroll — it's adjusted while watching, often with a long list open.
    final timingCard = widget.selectedSubtitle == null
        ? null
        : _buildGroup([
            _syncCover(Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Timing Offset',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      _buildMiniActionChip(
                        label: '−0.5s',
                        onTap: () => widget.onSubtitleDelayChanged(delay - 0.5),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                          onTap: () => widget.onSubtitleDelayChanged(0.0),
                          child: Text(
                            delayText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        ),
                      ),
                      _buildMiniActionChip(
                        label: '+0.5s',
                        onTap: () => widget.onSubtitleDelayChanged(delay + 0.5),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text(
                        'Speed (FPS)',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      _buildMiniActionChip(
                        label: 'Slow −4%',
                        active: (speed - (23.976 / 25.0)).abs() < 0.005,
                        onTap: () =>
                            widget.onSubtitleSpeedChanged(23.976 / 25.0),
                      ),
                      const SizedBox(width: 6),
                      _buildMiniActionChip(
                        label: '1.0×',
                        active: (speed - 1.0).abs() < 0.005,
                        onTap: () => widget.onSubtitleSpeedChanged(1.0),
                      ),
                      const SizedBox(width: 6),
                      _buildMiniActionChip(
                        label: 'Fast +4%',
                        active: (speed - (25.0 / 23.976)).abs() < 0.005,
                        onTap: () =>
                            widget.onSubtitleSpeedChanged(25.0 / 23.976),
                      ),
                    ],
                  ),
                  if (widget.subtitleSyncNote == 'Synced') ...[
                    const SizedBox(height: 8),
                    const Row(
                      children: [
                        Icon(Icons.check_circle_rounded,
                            size: 14, color: Colors.white54),
                        SizedBox(width: 6),
                        Text(
                          'Synced automatically',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            )),
          ]);

    return Column(
      key: const ValueKey('subtitle-settings'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (timingCard != null)
          Padding(
            // A gap under it, above where the tracks' list scrolls under.
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: timingCard,
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding:
                EdgeInsets.fromLTRB(14, timingCard == null ? 10 : 0, 14, 14),
            children: [
              _buildGroup([
                _buildRow(
                  title: 'Off',
                  trailing: widget.selectedSubtitle == null ? _check : null,
                  onTap: () => widget.onSubtitleSelected(null),
                ),
                for (final track in widget.availableSubtitles)
                  () {
                    final name = widget.getLanguageName(track.lang);
                    // Sinhala made from English with the viewer's Gemini
                    // key: greyed out until there's a key.
                    if (track.translatedFrom != null) {
                      final hasKey = GeminiKeyService().hasKey;
                      final chosen = widget.selectedSubtitle?.id == track.id;
                      final progress = widget.sinhalaProgress;
                      final String note;
                      if (!hasKey) {
                        note = 'Add your Gemini key in Settings to use';
                      } else if (chosen && widget.sinhalaProblem != null) {
                        note = widget.sinhalaProblem!;
                      } else if (chosen && progress != null && progress < 1) {
                        note = 'Translating… ${(progress * 100).floor()}%';
                      } else {
                        note = 'Auto-translated from English';
                      }
                      return _buildRow(
                        title: name,
                        subtitle: note,
                        enabled: hasKey,
                        trailing: chosen ? _check : null,
                        onTap: () => widget.onSubtitleSelected(track),
                      );
                    }
                    if (track.isEmbedded) {
                      final sub = (track.label != null &&
                              track.label!.isNotEmpty &&
                              track.label!.toLowerCase() != name.toLowerCase())
                          ? 'Embedded · ${track.label}'
                          : 'Embedded in video (Best sync)';
                      return _buildRow(
                        title: name,
                        subtitle: sub,
                        trailing: widget.selectedSubtitle?.id == track.id
                            ? _check
                            : null,
                        onTap: () => widget.onSubtitleSelected(track),
                      );
                    }
                    final n = seen[name] = (seen[name] ?? 0) + 1;
                    return _buildRow(
                      title: (perLanguage[name] ?? 1) > 1 ? '$name $n' : name,
                      trailing: widget.selectedSubtitle?.id == track.id
                          ? _check
                          : null,
                      onTap: () => widget.onSubtitleSelected(track),
                    );
                  }(),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  /// [controls] (the subtitles' timing), covered while they're being synced
  /// (see PlayerSettingsPanel.subtitleSyncing): faded and blurred under
  /// Ask's orb, as on the Subtitles button, saying so — and out of reach,
  /// so a nudge can't fight the sync. Uncovered smoothly when it's done.
  Widget _syncCover(Widget controls) {
    final syncing = widget.subtitleSyncing;
    return Stack(
      alignment: Alignment.center,
      children: [
        AbsorbPointer(
          absorbing: syncing,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: syncing ? 1 : 0),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            child: controls,
            builder: (context, v, child) => v == 0
                ? child!
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 3 * v, sigmaY: 3 * v),
                    child: Opacity(opacity: 1 - 0.75 * v, child: child),
                  ),
          ),
        ),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: syncing ? 1 : 0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: BusyOrb(on: syncing)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.subtitles_rounded,
                          color: Colors.white,
                          size: 16,
                          shadows: kOnOrbShadows),
                      SizedBox(width: 8),
                      Text(
                        'Syncing subtitles…',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          shadows: kOnOrbShadows,
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
    );
  }

  Widget _buildMiniActionChip({
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Material(
      color: active
          ? Colors.white.withValues(alpha: 0.24)
          : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white70,
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQualityView() {
    final options = StreamResolver.qualityOptions(
      widget.availableStreams,
      preferHash: widget.currentStream.infoHash,
    );
    final currentTier = StreamResolver.tierOf(widget.currentStream);

    if (options.isEmpty) {
      return const Padding(
        key: ValueKey('quality-settings-empty'),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 28),
        child: Center(
          child: Text(
            'No other qualities available',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    return ListView(
      key: const ValueKey('quality-settings'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      children: [
        QualityOptionList(
          options: options,
          compact: true,
          isCurrent: (option) => option.tier == currentTier,
          tagFor: (option) => option.tier == currentTier ? 'Playing' : null,
          onSelected: (option) {
            // Picking the quality that's already playing just
            // closes the menu instead of restarting the video.
            if (option.tier != currentTier) {
              widget.onStreamSelected(option.best);
            }
            _close();
          },
        ),
      ],
    );
  }
}
