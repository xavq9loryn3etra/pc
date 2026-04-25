import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../services/saved_movies_service.dart';

/// YouTube-style bottom panel for browsing episodes while watching.
///
/// Designed to be placed OUTSIDE the [PlayerGestureOverlay] in the widget tree
/// so that touches on this panel do NOT trigger volume/brightness gestures.
/// Uses a slide-up animation with a fixed height instead of DraggableScrollableSheet.
class EpisodeDrawer extends StatefulWidget {
  final List<Episode> episodes;
  final List<Season>? seasons;
  final Movie movie;
  /// The season currently being browsed in the drawer (may differ from playing).
  final int currentSeason;
  /// The season+episode actually loaded in the player.
  final int playingSeason;
  final int playingEpisode;
  final String movieId;
  final ValueChanged<int> onEpisodeTap;
  final ValueChanged<int> onSeasonChanged;
  final VoidCallback onClose;

  const EpisodeDrawer({
    super.key,
    required this.episodes,
    this.seasons,
    required this.movie,
    required this.currentSeason,
    required this.playingSeason,
    required this.playingEpisode,
    required this.movieId,
    required this.onEpisodeTap,
    required this.onSeasonChanged,
    required this.onClose,
  });

  @override
  State<EpisodeDrawer> createState() => _EpisodeDrawerState();
}

class _EpisodeDrawerState extends State<EpisodeDrawer>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  // Full screen drawer for immersive browsing

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1), // starts off-screen below
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));

    // Slide in
    _slideController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _scrollToCurrent() {
    // Only scroll to the playing episode if we're browsing the same season
    if (widget.currentSeason != widget.playingSeason) return;
    final index = widget.episodes
        .indexWhere((e) => e.episodeNumber == widget.playingEpisode);
    if (index != -1 && _scrollController.hasClients) {
      _scrollController.animateTo(
        index * 340.0, // card width (320) + margin (20)
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _dismiss() async {
    await _slideController.reverse();
    widget.onClose();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _dismiss,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          // Full screen semi-transparent background
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.8),
            ),
          ),

          // Slide-up content
          SlideTransition(
            position: _slideAnimation,
            child: GestureDetector(
              onTap: () {}, // swallow taps
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: SafeArea(
                  child: Column(
                    children: [
                      // Header: Series Logo & Name
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                        child: Row(
                          children: [
                            if (widget.movie.logoUrl != null)
                              SizedBox(
                                height: 50,
                                width: 120,
                                child: CachedNetworkImage(
                                  imageUrl: widget.movie.logoUrl!,
                                  fit: BoxFit.contain,
                                  alignment: Alignment.centerLeft,
                                  placeholder: (context, url) => Container(color: Colors.white10),
                                ),
                              )
                            else if (widget.movie.image != null)
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  image: DecorationImage(
                                    image: CachedNetworkImageProvider(widget.movie.image!),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.movie.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  Text(
                                    "Season ${widget.currentSeason}",
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (widget.seasons != null)
                              _buildSeasonSelector(),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.white, size: 28),
                              onPressed: _dismiss,
                            ),
                          ],
                        ),
                      ),

                      const Spacer(),

                      // Large Horizontal Episode List
                      SizedBox(
                        height: 280, // Optimized height for landscape mobile screens
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.episodes.length,
                          itemBuilder: (context, index) {
                            return _buildEpisodeCard(widget.episodes[index]);
                          },
                        ),
                      ),

                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonSelector() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: widget.currentSeason,
          dropdownColor: Colors.grey[900],
          icon: const Icon(Icons.keyboard_arrow_down,
              color: Colors.white, size: 18),
          isDense: true,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
          items: widget.seasons!
              .where((s) => s.seasonNumber > 0)
              .map((s) => DropdownMenuItem(
                    value: s.seasonNumber,
                    child: Text("Season ${s.seasonNumber}"),
                  ))
              .toList(),
          onChanged: (val) {
            if (val != null) widget.onSeasonChanged(val);
          },
        ),
      ),
    );
  }

  Widget _buildEpisodeCard(Episode ep) {
    // Only highlight as "current" if this season is the one actually playing
    final bool isCurrent = widget.currentSeason == widget.playingSeason &&
        ep.episodeNumber == widget.playingEpisode;
    final double? progress = SavedMoviesService().getEpisodeProgress(
          widget.movieId,
          widget.currentSeason,
          ep.episodeNumber,
        ) ??
        ep.progress;

    final bool isWatched = (progress ?? 0) > 0.95;

    // Check if episode is in the future
    bool isFuture = false;
    if (ep.airDate != null) {
      try {
        final date = DateTime.parse(ep.airDate!);
        if (date.isAfter(DateTime.now())) {
          isFuture = true;
        }
      } catch (_) {}
    }

    return GestureDetector(
      onTap: (isFuture || isCurrent)
          ? null
          : () => widget.onEpisodeTap(ep.episodeNumber),
      child: Container(
        width: 320,
        margin: const EdgeInsets.only(right: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main Card Image (Episode Thumbnail)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: isCurrent
                      ? Border.all(color: AppTheme.primaryColor, width: 3)
                      : Border.all(color: Colors.white.withOpacity(0.1), width: 1),
                  image: ep.stillPath != null
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(ep.stillPath!),
                          fit: BoxFit.cover,
                          opacity: (isWatched || isFuture) ? 0.4 : 1.0,
                        )
                      : null,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isFuture)
                      const Center(
                          child: Icon(Icons.lock_outline,
                              color: Colors.white54, size: 32))
                    else if (isWatched)
                      const Center(
                          child: Icon(Icons.check_circle_outline,
                              color: Colors.white54, size: 32))
                    else if (!isCurrent)
                      Center(
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 32),
                        ),
                      ),

                    // Progress Bar
                    if (progress != null && progress > 0)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 5,
                          decoration: const BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
                          ),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: progress.clamp(0.0, 1.0),
                              child: Container(
                                  color: isCurrent
                                      ? AppTheme.primaryColor
                                      : Colors.white70),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Title
            Text(
              "${ep.episodeNumber}. ${ep.name}",
              style: TextStyle(
                fontSize: 15,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                color: isCurrent
                    ? Colors.white
                    : (isWatched || isFuture)
                        ? Colors.white38
                        : Colors.white.withOpacity(0.9),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(Icons.equalizer, color: AppTheme.primaryColor, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      "NOW PLAYING",
                      style: TextStyle(
                        color: AppTheme.primaryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
