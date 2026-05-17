import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/torrent/torrent_index_service.dart';
import '../theme/app_theme.dart';
import '../services/subtitle_service.dart';

/// A premium, sliding right-side panel for unified player settings (Subtitles and Quality Selection).
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

  final VoidCallback onClose;
  final String initialView; // 'main', 'subtitles', 'quality'

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
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  width: panelWidth,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C0C0C).withOpacity(0.85),
                    border: const Border(
                      left: BorderSide(color: Colors.white12, width: 0.5),
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
      case 'main':
      default:
        return _buildMainMenuView();
    }
  }

  Widget _buildMainMenuView() {
    final activeSubtitleLabel = widget.selectedSubtitle != null
        ? widget.getLanguageName(widget.selectedSubtitle!.lang)
        : (widget.isLoadingSubtitles ? 'Loading...' : 'Off');

    return ListView(
      key: const ValueKey('main-settings'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _buildMenuTile(
          icon: Icons.hd_rounded,
          title: 'Quality',
          subtitle: widget.currentStream.quality ?? 'Auto',
          onTap: () => setState(() => _currentView = 'quality'),
        ),
        const SizedBox(height: 12),
        _buildMenuTile(
          icon: Icons.subtitles_rounded,
          title: 'Subtitles',
          subtitle: activeSubtitleLabel,
          onTap: () => setState(() => _currentView = 'subtitles'),
        ),
      ],
    );
  }

  Widget _buildMenuTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(icon, color: AppTheme.primaryColor, size: 22),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 12,
          ),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: Colors.white38,
          size: 20,
        ),
      ),
    );
  }

  Widget _buildSubtitlesView() {
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
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: widget.availableSubtitles.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      final isSelected = widget.selectedSubtitle == null;
                      return _buildSelectionTile(
                        title: 'Subtitles Off',
                        isSelected: isSelected,
                        onTap: () => widget.onSubtitleSelected(null),
                      );
                    }

                    final track = widget.availableSubtitles[index - 1];
                    final isSelected = widget.selectedSubtitle?.id == track.id;
                    final langName = widget.getLanguageName(track.lang);

                    return _buildSelectionTile(
                      title: langName,
                      subtitle: 'Track $index',
                      isSelected: isSelected,
                      onTap: () => widget.onSubtitleSelected(track),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildQualityView() {
    return Column(
      key: const ValueKey('quality-settings'),
      children: [
        Expanded(
          child: widget.availableStreams.isEmpty
              ? const Center(
                  child: Text(
                    'No quality streams available',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: widget.availableStreams.length,
                  itemBuilder: (context, index) {
                    final stream = widget.availableStreams[index];
                    final isSelected =
                        stream.infoHash == widget.currentStream.infoHash;

                    // Display details about the stream
                    final infoParts = <String>[];
                    if (stream.size != null) infoParts.add(stream.size!);
                    if (stream.seeders != null) {
                      infoParts.add('🚀 ${stream.seeders}');
                    }

                    return _buildSelectionTile(
                      title: stream.quality ?? 'Unknown Quality',
                      subtitle: infoParts.isNotEmpty
                          ? infoParts.join(' • ')
                          : stream.name,
                      isSelected: isSelected,
                      onTap: () {
                        widget.onStreamSelected(stream);
                        _close();
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSelectionTile({
    required String title,
    String? subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? AppTheme.primaryColor.withOpacity(0.12)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? AppTheme.primaryColor : Colors.transparent,
          width: 1,
        ),
      ),
      child: ListTile(
        dense: true,
        onTap: onTap,
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 10,
                ),
              )
            : null,
        trailing: isSelected
            ? const Icon(Icons.check_circle_rounded,
                color: AppTheme.primaryColor, size: 18)
            : null,
      ),
    );
  }
}
