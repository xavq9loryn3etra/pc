import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import 'episode_card.dart';
import 'glass_blur.dart';
import 'quality_option_list.dart';
import 'season_picker.dart';

/// YouTube-style, full-screen episode browser for the in-player "Episodes"
/// button. Two states:
///  - Grid: a 4-column vertical grid of episode thumbnails for the season
///    being browsed.
///  - Detail + source: after tapping an episode, splits into the episode's
///    thumbnail/details on the left and a live-fetched list of torrent
///    qualities + web player servers on the right.
///
/// This widget never resolves a stream itself — it only reports the user's
/// *choice* (a [TorrentStream] or a web player provider string) via
/// [onTorrentChosen]/[onWebPlayerChosen], so the caller (PlayerScreen) can
/// reuse its existing resolve + loading-overlay flow.
class EpisodeBrowser extends StatefulWidget {
  final List<Episode> episodes;
  final List<Season>? seasons;
  final Movie movie;
  final Movie details;
  final String imdbId;
  /// The season currently being browsed (may differ from what's playing).
  final int currentSeason;
  final int playingSeason;
  final int playingEpisode;
  final StreamResolver resolver;
  final ValueChanged<int> onSeasonChanged;
  final VoidCallback onClose;

  /// [stream] is the chosen quality's best torrent; [allStreams] is every
  /// torrent found for the episode (for falling back and for the player's
  /// Quality menu).
  final void Function(Episode episode, int season, TorrentStream stream,
      List<TorrentStream> allStreams) onTorrentChosen;
  final void Function(Episode episode, int season, String provider)
      onWebPlayerChosen;

  const EpisodeBrowser({
    super.key,
    required this.episodes,
    this.seasons,
    required this.movie,
    required this.details,
    required this.imdbId,
    required this.currentSeason,
    required this.playingSeason,
    required this.playingEpisode,
    required this.resolver,
    required this.onSeasonChanged,
    required this.onClose,
    required this.onTorrentChosen,
    required this.onWebPlayerChosen,
  });

  @override
  State<EpisodeBrowser> createState() => _EpisodeBrowserState();
}

class _EpisodeBrowserState extends State<EpisodeBrowser> {
  Episode? _selectedEpisode;
  final ScrollController _gridScrollController = ScrollController();
  bool _hasScrolled = false;

  static const int _crossAxisCount = 4;
  static const double _gridPadding = 24.0;
  // The details screen's card gap.
  static const double _gap = 12.0;

  double _itemWidthFor(double gridWidth) {
    final availableWidth = gridWidth - _gridPadding * 2;
    return (availableWidth - _gap * (_crossAxisCount - 1)) / _crossAxisCount;
  }

  // EpisodeCards are a fixed height for their width.
  double _itemHeightFor(double gridWidth) => EpisodeCard.heightFor(
        _itemWidthFor(gridWidth),
        MediaQuery.textScalerOf(context),
      );

  void _scrollToCurrentEpisode(double gridWidth) {
    if (_hasScrolled) return;
    if (widget.currentSeason != widget.playingSeason) return;
    final index = widget.episodes
        .indexWhere((e) => e.episodeNumber == widget.playingEpisode);
    if (index <= 0) return; // already on row 0, no scroll needed
    _hasScrolled = true;
    final row = index ~/ _crossAxisCount;
    final offset = (row * (_itemHeightFor(gridWidth) + _gap) - _gridPadding / 2)
        .clamp(0.0, _gridScrollController.position.maxScrollExtent);
    _gridScrollController.jumpTo(offset);
  }

  @override
  void dispose() {
    _gridScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Edge to edge, behind a camera cutout like the video: the grid sits in
    // a SafeArea, and the episode view keeps its own content clear of it
    // (see _buildDetailAndSource) so its backdrop can still fill the screen.
    return Material(
      color: Colors.black,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.04, 0.0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: _selectedEpisode == null
            ? KeyedSubtree(
                key: const ValueKey('grid_view'),
                // On the show's blurred backdrop, like the details
                // screen's popups, edge to edge.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    EpisodeBackdrop(
                      image: widget.details.backdrop ?? widget.movie.backdrop,
                      dim: 0.6,
                    ),
                    SafeArea(child: _buildGrid()),
                  ],
                ),
              )
            : KeyedSubtree(
                key: ValueKey('detail_view_${_selectedEpisode!.episodeNumber}'),
                child: _buildDetailAndSource(_selectedEpisode!),
              ),
      ),
    );
  }

  // ─────────────────────────── Grid view ───────────────────────────

  Widget _buildGrid() {
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _gridScrollController.hasClients) {
                  _scrollToCurrentEpisode(constraints.maxWidth);
                }
              });
              return GridView.builder(
                controller: _gridScrollController,
                padding: const EdgeInsets.all(_gridPadding),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _crossAxisCount,
                  crossAxisSpacing: _gap,
                  mainAxisSpacing: _gap,
                  mainAxisExtent: _itemHeightFor(constraints.maxWidth),
                ),
                itemCount: widget.episodes.length,
                itemBuilder: (context, index) =>
                    _buildGridCard(widget.episodes[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Row(
        children: [
          if (widget.movie.logoUrl != null)
            SizedBox(
              height: 40,
              width: 100,
              child: CachedNetworkImage(
                imageUrl: widget.movie.logoUrl!,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                memCacheHeight:
                    (40 * MediaQuery.of(context).devicePixelRatio).toInt(),
              ),
            )
          else
            Expanded(
              child: Text(
                widget.movie.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (widget.movie.logoUrl != null) const Spacer(),
          const SizedBox(width: 12),
          if (widget.seasons != null)
            SeasonPicker(
              seasons: widget.seasons!
                  .where((s) => s.seasonNumber > 0)
                  .toList(),
              current: widget.currentSeason,
              onSelected: widget.onSeasonChanged,
            ),
          const SizedBox(width: 10),
          GlassCircleButton(
            icon: Icons.close_rounded,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// The details screen's episode card (see EpisodeCard) — unaired
  /// episodes greyed out and inert, the playing one marked.
  Widget _buildGridCard(Episode ep) {
    final progress = SavedMoviesService().getEpisodeProgress(
          widget.movie.id,
          widget.currentSeason,
          ep.episodeNumber,
        ) ??
        ep.progress;
    return EpisodeCard(
      episode: ep,
      fallbackImage: widget.details.backdrop ?? widget.movie.backdrop,
      progress: progress,
      playing: widget.currentSeason == widget.playingSeason &&
          ep.episodeNumber == widget.playingEpisode,
      onTap: () => setState(() => _selectedEpisode = ep),
    );
  }

  // ─────────────────────── Detail + source view ───────────────────────

  /// The details screen's episode popup (EpisodeSheetFrame +
  /// EpisodeDetailHeader + the qualities), laid out sideways: on the
  /// episode's blurred still, its header on the left and the qualities on
  /// the right, with frosted back / close buttons over the top corners.
  ///
  /// The backdrop and the still run edge to edge, under a camera cutout,
  /// like the video does; the text, buttons and qualities keep clear of it.
  Widget _buildDetailAndSource(Episode ep) {
    final safe = MediaQuery.paddingOf(context);
    final fallback = widget.details.backdrop ?? widget.movie.backdrop;
    final progress = SavedMoviesService().getEpisodeProgress(
          widget.movie.id,
          widget.currentSeason,
          ep.episodeNumber,
        ) ??
        ep.progress;

    return Stack(
      children: [
        Positioned.fill(
          child: EpisodeBackdrop(image: ep.stillPath ?? fallback, dim: 0.6),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: EpisodeDetailHeader(
                  episode: ep,
                  fallbackImage: fallback,
                  progress: progress,
                  sideways: true,
                  textInset: EdgeInsets.only(
                    left: safe.left,
                    bottom: safe.bottom,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Padding(
                // Clear of the close button, and of a cutout on the right.
                padding: EdgeInsets.only(top: 52 + safe.top, right: safe.right),
                child: _EpisodeSourcePicker(
                  key: ValueKey(
                      '${widget.currentSeason}_${ep.episodeNumber}'),
                  resolver: widget.resolver,
                  imdbId: widget.imdbId,
                  details: widget.details,
                  season: widget.currentSeason,
                  episode: ep.episodeNumber,
                  onTorrentChosen: (stream, allStreams) =>
                      widget.onTorrentChosen(
                          ep, widget.currentSeason, stream, allStreams),
                  onWebPlayerChosen: (provider) => widget.onWebPlayerChosen(
                      ep, widget.currentSeason, provider),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          top: 12 + safe.top,
          left: 16 + safe.left,
          child: GlassCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onPressed: () => setState(() => _selectedEpisode = null),
          ),
        ),
        Positioned(
          top: 12 + safe.top,
          right: 16 + safe.right,
          child: GlassCircleButton(
            icon: Icons.close_rounded,
            onPressed: widget.onClose,
          ),
        ),
      ],
    );
  }
}

/// Right-panel source list: fetches available torrent streams for one
/// episode and lets the user pick a quality (or, when [_showWebServers] is
/// on, a web player server) — purely a picker, it never resolves anything
/// itself.
class _EpisodeSourcePicker extends StatefulWidget {
  final StreamResolver resolver;
  final String imdbId;
  final Movie details;
  final int season;
  final int episode;
  final void Function(TorrentStream stream, List<TorrentStream> allStreams)
      onTorrentChosen;
  final ValueChanged<String> onWebPlayerChosen;

  /// The web player servers are hidden for now, like the Play popup's
  /// (see TorrentQualitySelectorSheet.showWebServers).
  static const bool _showWebServers = false;

  const _EpisodeSourcePicker({
    super.key,
    required this.resolver,
    required this.imdbId,
    required this.details,
    required this.season,
    required this.episode,
    required this.onTorrentChosen,
    required this.onWebPlayerChosen,
  });

  @override
  State<_EpisodeSourcePicker> createState() => _EpisodeSourcePickerState();
}

class _EpisodeSourcePickerState extends State<_EpisodeSourcePicker> {
  List<TorrentStream>? _streams;
  List<QualityOption>? _options;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.resolver.getAvailableStreams(
        imdbId: widget.imdbId,
        type: 'tv',
        season: widget.season,
        episode: widget.episode,
        title: widget.details,
      );
      if (mounted) {
        setState(() {
          _streams = list;
          _options = StreamResolver.qualityOptions(list);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to find torrent sources.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 24, 24),
      child: ListView(
        children: [
          const QualitySectionLabel('Choose quality'),
          const SizedBox(height: 10),
          if (_loading)
            const QualityOptionListSkeleton(compact: true)
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.white54))
          else if (_options == null || _options!.isEmpty)
            const Text(
              'Not available to stream right now.',
              style: TextStyle(color: Colors.white54),
            )
          else
            _buildOptionList(_options!),
          if (_EpisodeSourcePicker._showWebServers) ...[
            const SizedBox(height: 24),
            const Text(
              'Web Player',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildWebPlayerOptions(),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionList(List<QualityOption> options) {
    // The resolver sorts its overall pick first (see getAvailableStreams).
    final recommendedTier = StreamResolver.tierOf(_streams!.first);
    return QualityOptionList(
      options: options,
      compact: true,
      tagFor: (option) => option.tier == recommendedTier ? 'Recommended' : null,
      isPrimary: (option) => option.tier == recommendedTier,
      onSelected: (option) => widget.onTorrentChosen(option.best, _streams!),
    );
  }

  Widget _buildWebPlayerOptions() {
    final defaultProvider = Platform.isIOS ? 'vsembed' : 'vidlink';
    final altProvider = Platform.isIOS ? 'vidlink' : 'vsembed';
    final servers = <String, String>{
      defaultProvider: Platform.isIOS ? 'Server 4' : 'Server 1',
      'moviesapi': 'Server 2',
      '2embed': 'Server 3',
      altProvider: Platform.isIOS ? 'Server 1' : 'Server 4',
    };

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: servers.entries
          .map(
            (entry) => OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => widget.onWebPlayerChosen(entry.key),
              child: Text(entry.value),
            ),
          )
          .toList(),
    );
  }
}
