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

  double _getListHeight(BuildContext context) {
    final double screenHeight = MediaQuery.of(context).size.height;
    final double paddingTop = MediaQuery.of(context).padding.top;
    final double paddingBottom = MediaQuery.of(context).padding.bottom;
    final double availableHeight = screenHeight - paddingTop - paddingBottom;
    return (availableHeight - 110).clamp(160.0, 280.0);
  }

  double _getImageHeight(double listHeight) {
    return (listHeight - 80).clamp(90.0, 180.0);
  }

  double _getCardWidth(double imageHeight) {
    return imageHeight * (16 / 9);
  }

  void _scrollToCurrent() {
    // Only scroll to the playing episode if we're browsing the same season
    if (widget.currentSeason != widget.playingSeason) return;
    final index = widget.episodes
        .indexWhere((e) => e.episodeNumber == widget.playingEpisode);
    if (index != -1 && _scrollController.hasClients) {
      final double listHeight = _getListHeight(context);
      final double imageHeight = _getImageHeight(listHeight);
      final double cardWidth = _getCardWidth(imageHeight);
      _scrollController.animateTo(
        index * (cardWidth + 20.0), // card width + margin (20)
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
                                  memCacheHeight:
                                      (50 * MediaQuery.of(context).devicePixelRatio)
                                          .toInt(),
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
                      (() {
                        final double listHeight = _getListHeight(context);
                        final double imageHeight = _getImageHeight(listHeight);
                        final double cardWidth = _getCardWidth(imageHeight);
                        return SizedBox(
                          height: listHeight,
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            scrollDirection: Axis.horizontal,
                            itemCount: widget.episodes.length,
                            itemBuilder: (context, index) {
                              return _buildEpisodeCard(
                                widget.episodes[index],
                                listHeight,
                                cardWidth,
                                imageHeight,
                              );
                            },
                          ),
                        );
                      }()),

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
    return Builder(
      builder: (btnContext) {
        return TextButton.icon(
          style: TextButton.styleFrom(
            backgroundColor: Colors.white.withOpacity(0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          icon: const Icon(Icons.layers_rounded, color: Colors.white, size: 16),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Season ${widget.currentSeason}",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 14),
            ],
          ),
          onPressed: () async {
            final RenderBox renderBox = btnContext.findRenderObject() as RenderBox;
            final offset = renderBox.localToGlobal(Offset.zero);
            final val = await showMenu<int>(
              context: context,
              position: RelativeRect.fromLTRB(
                offset.dx,
                offset.dy + renderBox.size.height + 4,
                offset.dx + renderBox.size.width,
                0,
              ),
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              items: widget.seasons!
                  .where((s) => s.seasonNumber > 0)
                  .map((s) => PopupMenuItem(
                        value: s.seasonNumber,
                        height: 40,
                        child: Text(
                          "Season ${s.seasonNumber}",
                          style: TextStyle(
                            color: s.seasonNumber == widget.currentSeason
                                ? AppTheme.primaryColor
                                : Colors.white,
                            fontSize: 13,
                            fontWeight: s.seasonNumber == widget.currentSeason
                                ? FontWeight.bold
                                : FontWeight.w500,
                          ),
                        ),
                      ))
                  .toList(),
            );
            if (val != null) widget.onSeasonChanged(val);
          },
        );
      },
    );
  }

  Widget _buildEpisodeCard(Episode ep, double listHeight, double cardWidth, double imageHeight) {
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
    String? formattedDate;
    if (ep.airDate != null) {
      try {
        final date = DateTime.parse(ep.airDate!);
        if (date.isAfter(DateTime.now())) {
          isFuture = true;
          formattedDate = "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
        }
      } catch (_) {}
    }

    return GestureDetector(
      onTap: (isFuture || isCurrent)
          ? null
          : () => widget.onEpisodeTap(ep.episodeNumber),
      child: Container(
        width: cardWidth,
        margin: const EdgeInsets.only(right: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main Card Image (Episode Thumbnail)
            SizedBox(
              width: cardWidth,
              height: imageHeight,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isFuture && (widget.movie.backdrop != null || widget.movie.posterUrl != null))
                      CachedNetworkImage(
                        imageUrl: (widget.movie.backdrop ?? widget.movie.posterUrl)!,
                        fit: BoxFit.cover,
                        color: Colors.black.withOpacity(0.6),
                        colorBlendMode: BlendMode.darken,
                        memCacheWidth: (cardWidth *
                                MediaQuery.of(context).devicePixelRatio)
                            .toInt(),
                      )
                    else if (ep.stillPath != null)
                      CachedNetworkImage(
                        imageUrl: ep.stillPath!,
                        fit: BoxFit.cover,
                        color: isWatched ? Colors.black.withOpacity(0.6) : null,
                        colorBlendMode: isWatched ? BlendMode.darken : null,
                        memCacheWidth: (cardWidth *
                                MediaQuery.of(context).devicePixelRatio)
                            .toInt(),
                      )
                    else
                      Container(color: Colors.grey[900]),

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
                        bottom: 6,
                        left: 12,
                        right: 12,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
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

                    // Border ring overlay on top of thumbnail and icons
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: isCurrent
                              ? Border.all(
                                  color: AppTheme.primaryColor,
                                  width: 3,
                                  strokeAlign: BorderSide.strokeAlignInside,
                                )
                              : Border.all(
                                  color: Colors.white.withOpacity(0.1),
                                  width: 1,
                                  strokeAlign: BorderSide.strokeAlignInside,
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
                    const Text(
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
              )
            else if (isFuture && formattedDate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, color: Colors.white54, size: 12),
                    const SizedBox(width: 6),
                    Text(
                      "Available on: $formattedDate",
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
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
