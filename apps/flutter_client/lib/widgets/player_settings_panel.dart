import 'package:flutter/material.dart';
import 'glass_blur.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import 'quality_option_list.dart';
import '../services/subtitle_service.dart';

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
/// Subtitles and Video size).
///
/// Provides a sleek settings-menu style interface with sliding animated transitions
/// and a high-end semi-transparent glassmorphic look.
class PlayerSettingsPanel extends StatefulWidget {
  final List<SubtitleTrackData> availableSubtitles;
  final SubtitleTrackData? selectedSubtitle;
  final bool isLoadingSubtitles;
  final ValueChanged<SubtitleTrackData?> onSubtitleSelected;
  final String Function(String) getLanguageName;

  final List<TorrentStream> availableStreams;
  final TorrentStream currentStream;
  final ValueChanged<TorrentStream> onStreamSelected;

  final VideoFit videoFit;
  final ValueChanged<VideoFit> onVideoFitSelected;

  final VoidCallback onClose;
  final String initialView; // 'main', 'subtitles', 'quality', 'videoSize'

  const PlayerSettingsPanel({
    super.key,
    required this.availableSubtitles,
    required this.selectedSubtitle,
    required this.isLoadingSubtitles,
    required this.onSubtitleSelected,
    required this.getLanguageName,
    required this.availableStreams,
    required this.currentStream,
    required this.onStreamSelected,
    required this.videoFit,
    required this.onVideoFitSelected,
    required this.onClose,
    this.initialView = 'main',
  });

  @override
  State<PlayerSettingsPanel> createState() => _PlayerSettingsPanelState();
}

class _PlayerSettingsPanelState extends State<PlayerSettingsPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;
  late String _currentView;

  @override
  void initState() {
    super.initState();
    _currentView = widget.initialView;

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(1.0, 0.0), // Start fully off-screen to the right
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));

    _slideController.forward();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  void _close() {
    _slideController.reverse().then((_) => widget.onClose());
  }

  @override
  Widget build(BuildContext context) {
    final double panelWidth =
        (MediaQuery.of(context).size.width * 0.35).clamp(290.0, 360.0);

    return Stack(
      children: [
        // Dimmed backdrop tap detector
        GestureDetector(
          onTap: _close,
          child: Container(
            color: Colors.black45,
          ),
        ),
        // Sliding Panel
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          child: SlideTransition(
            position: _slideAnimation,
            child: ClipRect(
              // Its own 85% tint needs no extra when the blur is reduced.
              child: GlassBlur(
                sigma: 16,
                reducedTint: Colors.transparent,
                child: Container(
                  width: panelWidth,
                  decoration: BoxDecoration(
                    color: kGlassSheetTint,
                    border: Border(
                      left: BorderSide(color: kGlassEdge, width: 0.5),
                    ),
                  ),
                  child: SafeArea(
                    left: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(),
                        const Divider(color: Colors.white12, height: 1),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0.08, 0.0),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              );
                            },
                            child: _buildCurrentView(),
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
      ],
    );
  }

  Widget _buildHeader() {
    String title = 'Player Settings';
    Widget? leftButton;

    if (_currentView == 'subtitles') {
      title = 'Subtitles';
      leftButton = IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            color: Colors.white70, size: 16),
        onPressed: () => setState(() => _currentView = 'main'),
      );
    } else if (_currentView == 'quality') {
      title = 'Quality';
      leftButton = IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            color: Colors.white70, size: 16),
        onPressed: () => setState(() => _currentView = 'main'),
      );
    } else if (_currentView == 'videoSize') {
      title = 'Video Size';
      leftButton = IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            color: Colors.white70, size: 16),
        onPressed: () => setState(() => _currentView = 'main'),
      );
    }

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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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

  Widget _buildVideoSizeView() {
    return ListView(
      key: const ValueKey('video-size-settings'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
  }) {
    return InkWell(
      onTap: onTap,
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
  }

  Widget _buildSubtitlesView() {
    // Several tracks often share a language — number those so they can
    // be told apart.
    final perLanguage = <String, int>{};
    for (final t in widget.availableSubtitles) {
      final name = widget.getLanguageName(t.lang);
      perLanguage[name] = (perLanguage[name] ?? 0) + 1;
    }
    final seen = <String, int>{};

    return Column(
      key: const ValueKey('subtitle-settings'),
      children: [
        Expanded(
          child: widget.availableSubtitles.isEmpty && !widget.isLoadingSubtitles
              ? const Center(
                  child: Text(
                    'No subtitles found for this media',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                )
              : ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: [
                    _buildGroup([
                      _buildRow(
                        title: 'Off',
                        trailing:
                            widget.selectedSubtitle == null ? _check : null,
                        onTap: () => widget.onSubtitleSelected(null),
                      ),
                      for (final track in widget.availableSubtitles)
                        () {
                          final name = widget.getLanguageName(track.lang);
                          final n = seen[name] = (seen[name] ?? 0) + 1;
                          return _buildRow(
                            title: perLanguage[name]! > 1 ? '$name $n' : name,
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

  Widget _buildQualityView() {
    final options = StreamResolver.qualityOptions(
      widget.availableStreams,
      preferHash: widget.currentStream.infoHash,
    );
    final currentTier = StreamResolver.tierOf(widget.currentStream);

    return Column(
      key: const ValueKey('quality-settings'),
      children: [
        Expanded(
          child: options.isEmpty
              ? const Center(
                  child: Text(
                    'No other qualities available',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                )
              : ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: [
                    QualityOptionList(
                      options: options,
                      compact: true,
                      isCurrent: (option) => option.tier == currentTier,
                      tagFor: (option) =>
                          option.tier == currentTier ? 'Playing' : null,
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
                ),
        ),
      ],
    );
  }

}
