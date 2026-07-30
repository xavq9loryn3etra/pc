import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';
import '../services/saved_movies_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import 'shimmer_loader.dart';

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
  final void Function(Episode episode, int season, TorrentStream stream)
      onTorrentChosen;
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
  static const double _mainAxisSpacing = 20.0;
  static const double _crossAxisSpacing = 16.0;
  static const double _childAspectRatio = 1.25;

  void _scrollToCurrentEpisode(double gridWidth) {
    if (_hasScrolled) return;
    if (widget.currentSeason != widget.playingSeason) return;
    final index = widget.episodes
        .indexWhere((e) => e.episodeNumber == widget.playingEpisode);
    if (index <= 0) return; // already on row 0, no scroll needed
    _hasScrolled = true;
    final row = index ~/ _crossAxisCount;
    final availableWidth = gridWidth - _gridPadding * 2;
    final itemWidth =
        (availableWidth - _crossAxisSpacing * (_crossAxisCount - 1)) /
            _crossAxisCount;
    final itemHeight = itemWidth / _childAspectRatio;
    final offset =
        (row * (itemHeight + _mainAxisSpacing) - _gridPadding / 2)
            .clamp(0.0, _gridScrollController.position.maxScrollExtent);
    _gridScrollController.jumpTo(offset);
  }

  @override
  void dispose() {
    _gridScrollController.dispose();
    super.dispose();
  }

  bool _isFuture(Episode ep) {
    if (ep.airDate == null) return false;
    final date = DateTime.tryParse(ep.airDate!);
    return date != null && date.isAfter(DateTime.now());
  }

  String? _formattedAirDate(Episode ep) {
    if (ep.airDate == null) return null;
    final date = DateTime.tryParse(ep.airDate!);
    if (date == null) return null;
    return "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: SafeArea(
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
                  child: _buildGrid(),
                )
              : KeyedSubtree(
                  key: ValueKey('detail_view_${_selectedEpisode!.episodeNumber}'),
                  child: _buildDetailAndSource(_selectedEpisode!),
                ),
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
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _crossAxisCount,
                  crossAxisSpacing: _crossAxisSpacing,
                  mainAxisSpacing: _mainAxisSpacing,
                  childAspectRatio: _childAspectRatio,
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
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(width: 12),
          if (widget.seasons != null) _buildSeasonSelector(),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 26),
            onPressed: widget.onClose,
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
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          icon: const Icon(Icons.layers_rounded,
              color: Colors.white, size: 16),
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
              const Icon(Icons.keyboard_arrow_down,
                  color: Colors.white54, size: 14),
            ],
          ),
          onPressed: () async {
            final renderBox =
                btnContext.findRenderObject() as RenderBox;
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
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

  Widget _buildGridCard(Episode ep) {
    final bool isCurrent = widget.currentSeason == widget.playingSeason &&
        ep.episodeNumber == widget.playingEpisode;
    final double? progress = SavedMoviesService().getEpisodeProgress(
          widget.movie.id,
          widget.currentSeason,
          ep.episodeNumber,
        ) ??
        ep.progress;
    final bool isWatched = (progress ?? 0) > 0.95;
    final bool isFuture = _isFuture(ep);
    final String? formattedDate = _formattedAirDate(ep);

    return GestureDetector(
      onTap: isFuture
          ? null
          : () => setState(() => _selectedEpisode = ep),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ep.stillPath != null)
                    CachedNetworkImage(
                      imageUrl: ep.stillPath!,
                      fit: BoxFit.cover,
                      memCacheWidth: 400,
                      color: isFuture || isWatched
                          ? Colors.black.withOpacity(0.4)
                          : null,
                      colorBlendMode:
                          isFuture || isWatched ? BlendMode.darken : null,
                    )
                  else
                    Container(color: Colors.grey[900]),
                  if (isFuture)
                    const Center(
                      child: Icon(Icons.lock_clock,
                          color: Colors.white54, size: 26),
                    )
                  else if (isWatched)
                    const Center(
                      child: Icon(Icons.check_circle_outline,
                          color: Colors.white54, size: 26),
                    )
                  else if (!isCurrent)
                    Center(
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  if (progress != null && progress > 0)
                    Positioned(
                      bottom: 4,
                      left: 6,
                      right: 6,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          height: 3,
                          color: Colors.black54,
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: progress.clamp(0.0, 1.0),
                            child: Container(
                              color: isCurrent
                                  ? AppTheme.primaryColor
                                  : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (isCurrent)
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppTheme.primaryColor,
                            width: 3,
                            strokeAlign: BorderSide.strokeAlignInside,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "${ep.episodeNumber}. ${ep.name}",
            style: TextStyle(
              fontSize: 12,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
              color: isCurrent
                  ? Colors.white
                  : (isWatched || isFuture)
                      ? Colors.white38
                      : Colors.white.withOpacity(0.9),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (isFuture && formattedDate != null)
            Text(
              'Available on: $formattedDate',
              style: const TextStyle(color: Colors.white54, fontSize: 9),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          else if (isCurrent)
            const Text(
              'NOW PLAYING',
              style: TextStyle(
                color: AppTheme.primaryColor,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────── Detail + source view ───────────────────────

  Widget _buildDetailAndSource(Episode ep) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => setState(() => _selectedEpisode = null),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  "Season ${widget.currentSeason} · Episode ${ep.episodeNumber}",
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 24),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: thumbnail + details
              Expanded(
                flex: 4,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: ep.stillPath != null
                              ? CachedNetworkImage(
                                  imageUrl: ep.stillPath!,
                                  fit: BoxFit.cover,
                                )
                              : Container(color: Colors.grey[900]),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "${ep.episodeNumber}. ${ep.name}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        ep.overview.isNotEmpty
                            ? ep.overview
                            : "No description available.",
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.star,
                              color: Colors.amber, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            ep.voteAverage.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (ep.airDate != null) ...[
                            const SizedBox(width: 12),
                            Text(
                              _formattedAirDate(ep) ?? ep.airDate!,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Right: source picker
              Expanded(
                flex: 5,
                child: _EpisodeSourcePicker(
                  key: ValueKey(
                      '${widget.currentSeason}_${ep.episodeNumber}'),
                  resolver: widget.resolver,
                  imdbId: widget.imdbId,
                  season: widget.currentSeason,
                  episode: ep.episodeNumber,
                  onTorrentChosen: (stream) =>
                      widget.onTorrentChosen(ep, widget.currentSeason, stream),
                  onWebPlayerChosen: (provider) => widget.onWebPlayerChosen(
                      ep, widget.currentSeason, provider),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Right-panel source list: fetches available torrent streams for one
/// episode and lets the user pick a quality, or a web player server —
/// purely a picker, it never resolves anything itself.
class _EpisodeSourcePicker extends StatefulWidget {
  final StreamResolver resolver;
  final String imdbId;
  final int season;
  final int episode;
  final ValueChanged<TorrentStream> onTorrentChosen;
  final ValueChanged<String> onWebPlayerChosen;

  const _EpisodeSourcePicker({
    super.key,
    required this.resolver,
    required this.imdbId,
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
      );
      if (mounted) {
        setState(() {
          _streams = list;
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
          const Text(
            'Torrent Streams',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: ShimmerLoader(size: 70)),
            )
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.white54))
          else if (_streams == null || _streams!.isEmpty)
            const Text(
              "No direct torrent streams available.",
              style: TextStyle(color: Colors.white54),
            )
          else
            ..._streams!.map(_buildStreamTile),
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
      ),
    );
  }

  Widget _buildStreamTile(TorrentStream stream) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onTorrentChosen(stream),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  stream.quality ?? 'HD',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stream.name,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${stream.size ?? "Unknown size"} · ${stream.seeders ?? 0} seeds',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_outline,
                  color: AppTheme.primaryColor, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebPlayerOptions() {
    final defaultProvider = Platform.isIOS ? 'vsembed' : 'vidlink';
    final altProvider = Platform.isIOS ? 'vidlink' : 'vsembed';
    final servers = <String, String>{
      defaultProvider: Platform.isIOS ? 'Server 4' : 'Server 1',
      'moviesapi': 'Server 2',
      'vidking': 'Server 3',
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
