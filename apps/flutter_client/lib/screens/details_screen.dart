import 'dart:math' as math;
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import '../theme/app_theme.dart';
import '../widgets/skeletons.dart';
import '../widgets/shimmer_loader.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import '../services/scraper_service.dart';
import '../services/saved_movies_service.dart';
import '../services/feature_flags_service.dart';
import '../services/streaming_link_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/torrent/torrent_download_registry.dart';
import 'web_player/web_player.dart';
import 'player_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui'; // For BackdropFilter
import '../widgets/custom_app_bar.dart';
import '../widgets/glass_bubble_bar.dart';
import '../widgets/details_overview.dart';

class DetailsScreen extends StatefulWidget {
  final Movie movie;
  final String? heroTag;
  final VoidCallback? onClose;
  final bool isSidePanel;

  const DetailsScreen({
    super.key,
    required this.movie,
    this.heroTag,
    this.onClose,
    this.isSidePanel = false,
  });

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  Movie? _details;
  bool _loading = true;
  // Skeleton reveal stages after _loading turns false: fading out, then
  // removed (see _revealOverSkeleton).
  bool _skeletonFading = false;
  bool _skeletonDone = false;
  final ScrollController _scrollController = ScrollController();
  // The page's vertical scroll offset, for the parallax backdrop and the
  // app bar. Fed from scroll notifications rather than a _scrollController
  // listener: when the content shrinks (e.g. the synopsis collapsing) the
  // position is corrected *without* notifying controller listeners, which
  // left the backdrop frozen at its old parallax offset. Scroll-metrics
  // notifications do report those corrections.
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0);

  bool _onPageScroll(Notification notification) {
    // depth 0 = the page's own scroll view, not nested ones (the cast row).
    if (notification is ScrollUpdateNotification &&
        notification.depth == 0) {
      _scrollOffset.value = notification.metrics.pixels;
    } else if (notification is ScrollMetricsNotification &&
        notification.depth == 0) {
      _scrollOffset.value = notification.metrics.pixels;
    }
    return false;
  }
  final Dio _shareDio = Dio();
  final CancelToken _detailsCancelToken = CancelToken();

  // TV Show State
  List<Episode> _episodes = [];
  Season? _selectedSeason;
  int? _selectedEpisode;
  bool _loadingEpisodes = false;

  Future<void> _shareMovie() async {
    final m = _details ?? widget.movie;
    const downloadUrl =
        'https://drive.google.com/drive/folders/1ftzQcKIUkB2sKwInoSdMG7-SH4rPf96i?usp=sharing';
    final smartLink =
        'https://script.google.com/macros/s/AKfycbzEwmEgC4JXWXz4TPHUUxPon_56ZN4VsOKq7FAw_3rWgRi2L4KIZAx1rs_HZ94-1h6IVg/exec?id=${m.id}&type=${m.type}';

    final message = '🍿 Watch "${m.title}" on Popcorn!\n\n'
        '📲 Tap to Play: $smartLink\n\n'
        '📥 Download App: $downloadUrl';

    try {
      // 1. Get temp directory
      final temp = await getTemporaryDirectory();
      final path = '${temp.path}/poster_${m.id}.jpg';

      // 2. Download image if it doesn't exist in temp and m.image is not null
      final file = File(path);
      if (!await file.exists() && m.image != null) {
        await _shareDio.download(m.image!, path);
      }

      if (await file.exists()) {
        // 3. Share file + text
        await Share.shareXFiles(
          [XFile(path)],
          text: message,
          subject: 'Share ${m.title}',
        );
      } else {
        // Fallback to text only
        Share.share(message, subject: 'Share ${m.title}');
      }
    } catch (e) {
      // Fallback to text only if image download fails
      Share.share(message, subject: 'Share ${m.title}');
    }
  }

  @override
  void initState() {
    super.initState();
    FeatureFlagsService().hidePlayback.addListener(_onFlagsChanged);
    _loadDetails();
  }

  void _onFlagsChanged() {
    if (mounted) setState(() {});
  }

  // No local _isFavorite field/setState needed — toggleFavorite() below
  // calls notifyListeners(), and the like button already reads
  // SavedMoviesService().isFavorite(...) directly inside the
  // ListenableBuilder(listenable: SavedMoviesService()) further down, so it
  // updates on its own without a second, full-screen rebuild.
  Future<void> _toggleFavorite() async {
    await SavedMoviesService().toggleFavorite(_details ?? widget.movie);
  }

  Future<void> _openTrailer(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Opens the streaming service's page for this title — in its app when
  /// installed (Android App Links / iOS Universal Links), else the browser.
  /// Opens this title in the streaming service's own app — and nowhere
  /// else. Never falls back to TMDB, a search page or a browser: if there's
  /// no direct link for the title, or no app on the device can open it, the
  /// user is told instead.
  Future<void> _openProvider(StreamingProvider provider) async {
    final m = _details ?? widget.movie;
    // Usually already resolved and cached by the prefetch in _loadDetails.
    final url = m.wikidataId == null
        ? null
        : await StreamingLinkService()
            .directUrl(
              wikidataId: m.wikidataId!,
              providerId: provider.id,
              isTv: m.type == 'tv',
            )
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (!mounted) return;
    if (url == null) {
      _showProviderMessage("Couldn't find ${m.title} on ${provider.name}.");
      return;
    }

    var opened = false;
    try {
      // Non-browser only: the OS opens the link in the service's app, or
      // refuses (returns false / throws) rather than falling back to a
      // browser.
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalNonBrowserApplication,
      );
    } catch (e) {
      debugPrint('Failed to open ${provider.name}: $e');
    }
    if (!opened && mounted) {
      _showProviderMessage(
          "Couldn't open ${provider.name}. Make sure the app is installed.");
    }
  }

  void _showProviderMessage(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Splits the Play pill so [provider]'s logo sits at its right end,
  /// behind a thin divider; unchanged when there's no provider.
  Widget _withProviderSegment(StreamingProvider? provider, Widget play) {
    if (provider == null) return play;
    return Row(
      children: [
        Expanded(child: play),
        Container(width: 1, height: 26, color: Colors.black12),
        InkWell(
          onTap: () => _openProvider(provider),
          borderRadius:
              const BorderRadius.horizontal(right: Radius.circular(30)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
            child: _ProviderLogo(provider: provider, size: 28),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    // Aborts the in-flight TMDB request if the screen is closed before it
    // resolves, instead of letting it finish (and get silently discarded)
    // in the background — saves bandwidth/battery on a quick back-out.
    _detailsCancelToken.cancel();
    _scrollController.dispose();
    _scrollOffset.dispose();
    FeatureFlagsService().hidePlayback.removeListener(_onFlagsChanged);
    super.dispose();
  }

  // The header images, shared by build() and _preloadHeader() so the
  // preload warms exactly what the screen will request. Full-resolution
  // sources: the header is large enough that TMDB's standard tiers look soft.
  static String _backdropUrlFor(Movie m) =>
      m.backdropHighRes ?? m.backdrop ?? m.posterUrl ?? '';
  static String? _logoUrlFor(Movie m) =>
      m.logoUrl == null ? null : (m.logoHighRes ?? m.logoUrl!);

  // Longest the skeleton waits on header images / the first season before
  // showing the page anyway; anything slower finishes loading in place.
  static const _maxPreloadWait = Duration(seconds: 4);

  Future<void> _loadDetails() async {
    Movie? d;
    try {
      d = await TMDBService().getDetails(
        widget.movie.id,
        type: widget.movie.type,
        cancelToken: _detailsCancelToken,
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) return;
      rethrow;
    }
    if (!mounted) return;

    // Resolve the streaming service's direct link in the background now, so
    // it's ready (and cached) before its button is tapped — see
    // _openProvider.
    final loaded = d ?? widget.movie;
    final provider = loaded.streamingProvider;
    if (provider != null &&
        loaded.wikidataId != null &&
        StreamingLinkService().supports(provider.id)) {
      StreamingLinkService().prefetch(loaded.wikidataId!);
    }

    // Still behind the skeleton (_loading stays true): store the details
    // and pick the starting season, then keep the skeleton up while the
    // header images and first season's episodes load, so the page appears
    // complete instead of filling in piece by piece.
    setState(() {
      _details = d ?? widget.movie;

      // Init Season 1 if TV
      if (_details?.type == 'tv' &&
          _details?.seasons != null &&
          _details!.seasons!.isNotEmpty) {
        _selectedSeason = _details!.seasons!.firstWhere(
          (s) => s.seasonNumber == 1,
          orElse: () => _details!.seasons!.firstWhere(
            (s) => s.seasonNumber > 0,
            orElse: () => _details!.seasons!.first,
          ),
        );
      }
    });

    try {
      await Future.wait([
        _preloadHeader(_details!),
        if (_selectedSeason != null)
          _loadSeasonDetails(_selectedSeason!.seasonNumber),
      ]).timeout(_maxPreloadWait);
    } catch (_) {
      // Timed out or an image failed: show the page regardless.
    }

    if (!mounted) return;
    // Build the page under the skeleton, give it a few frames to settle,
    // then fade the skeleton off it (see _revealOverSkeleton).
    setState(() => _loading = false);
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _skeletonFading = true);
  }

  /// Downloads and decodes the header backdrop and logo into Flutter's
  /// image cache, keyed exactly as the CachedNetworkImage widgets in
  /// build() will look them up (same URL and memCache size), so they
  /// paint on the first frame.
  Future<void> _preloadHeader(Movie m) async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final backdrop = _backdropUrlFor(m);
    final logo = _logoUrlFor(m);
    final jobs = <Future<void>>[];
    // SVGs render through SvgPicture, not the image cache — skip them.
    if (backdrop.isNotEmpty && !backdrop.toLowerCase().endsWith('.svg')) {
      jobs.add(precacheImage(
        ResizeImage.resizeIfNeeded(
          null,
          (450 * dpr).toInt(),
          CachedNetworkImageProvider(backdrop),
        ),
        context,
      ));
    }
    if (logo != null && !logo.toLowerCase().endsWith('.svg')) {
      jobs.add(precacheImage(
        ResizeImage.resizeIfNeeded(
          (200 * dpr).toInt(),
          null,
          CachedNetworkImageProvider(logo),
        ),
        context,
      ));
    }
    await Future.wait(jobs);
  }

  Future<void> _loadSeasonDetails(int seasonNum) async {
    if (_details == null) return;
    setState(() => _loadingEpisodes = true);

    final episodes = await TMDBService().getSeasonDetails(
      _details!.id,
      seasonNum,
    );

    // Inject history progress
    final service = SavedMoviesService();

    final processedEpisodes = episodes.map((e) {
      final progress = service.getEpisodeProgress(
        widget.movie.id,
        seasonNum,
        e.episodeNumber,
      );

      if (progress != null) {
        return Episode(
          id: e.id,
          episodeNumber: e.episodeNumber,
          name: e.name,
          overview: e.overview,
          stillPath: e.stillPath,
          airDate: e.airDate,
          voteAverage: e.voteAverage,
          progress: progress,
        );
      }
      return e;
    }).toList();

    if (mounted) {
      setState(() {
        _episodes = processedEpisodes;
        _loadingEpisodes = false;
      });
    }
  }

  /// True if the movie itself, or the currently targeted TV episode, hasn't
  /// been released yet — there's no real stream to find for content like
  /// that, no matter what an indexer might claim to have.
  bool _isSelectionUnreleased() {
    if (_details == null) return false;
    if (_details!.type != 'tv') return _details!.isUnreleased;

    if (_selectedEpisode == null) return false;
    final targetEp = _episodes.firstWhere(
      (ep) => ep.episodeNumber == _selectedEpisode,
      orElse: () => Episode(
        id: -1,
        episodeNumber: -1,
        name: '',
        overview: '',
        voteAverage: 0,
      ),
    );
    return targetEp.id != -1 && targetEp.isUnreleased;
  }

  void _showNotReleasedMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: Colors.black87,
        content: Text("This hasn't been released yet."),
      ),
    );
  }

  String _formatReleaseDate(DateTime date) =>
      "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";

  void _playWithTorrent() async {
    if (_details == null) return;
    if (_isSelectionUnreleased()) {
      _showNotReleasedMessage();
      return;
    }

    final resolver = StreamResolver();
    int? s = _selectedSeason != null && _selectedSeason!.seasonNumber > 0
        ? _selectedSeason!.seasonNumber
        : null;
    int? e = _selectedEpisode;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        return TorrentQualitySelectorSheet(
          imdbId: _details!.imdbId ?? _details!.id,
          type: _details!.type,
          season: s,
          episode: e,
          resolver: resolver,
          movie: widget.movie,
          details: _details!,
          episodes: _episodes,
          onFallback: (provider) {
            _openWebPlayer(provider);
          },
        );
      },
    );
  }

  Future<void> _openWebPlayer(String provider) async {
    if (_details == null) return;
    if (_isSelectionUnreleased()) {
      _showNotReleasedMessage();
      return;
    }

    // Add to history with specific season/episode if TV
    int? s = _selectedSeason != null && _selectedSeason!.seasonNumber > 0
        ? _selectedSeason!.seasonNumber
        : null;
    int? e = _selectedEpisode;

    await SavedMoviesService().addToHistory(
      widget.movie,
      season: s,
      episode: e,
    );

    final url = ScraperService().getEmbedUrl(
      _details!.id,
      season: s,
      episode: e,
      imdbId: _details!.imdbId,
      provider: provider,
    );

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebPlayer(
          url: url,
          onClose: () => Navigator.pop(context),
          movie: widget.movie,
          season: s,
          episode: e,
          episodes: _episodes,
          seasons: _details?.seasons,
          details: _details!,
        ),
      ),
    );

    // Refresh history state on return
    if (mounted) {
      final service = SavedMoviesService();
      setState(() {
        _episodes = _episodes.map((ep) {
          final progress = service.getEpisodeProgress(
            widget.movie.id,
            s ?? 1,
            ep.episodeNumber,
          );

          if (progress != null) {
            return Episode(
              id: ep.id,
              episodeNumber: ep.episodeNumber,
              name: ep.name,
              overview: ep.overview,
              stillPath: ep.stillPath,
              airDate: ep.airDate,
              voteAverage: ep.voteAverage,
              progress: progress,
            );
          }
          return ep;
        }).toList();
      });
    }
  }

  Widget _buildAppBarTitle(Movie m) {
    if (m.logoUrl != null) {
      // Fixed width+height (not just a maxWidth cap) — CachedNetworkImage/
      // SvgPicture.network report zero size while their first frame is
      // still loading (octo_image's placeholder for the "loading" state is
      // a bare zero-size Container), so a maxWidth-only box collapsed to
      // nothing and then snapped to full size the instant the logo finished
      // decoding — only on first load, since after that it's served
      // synchronously from Flutter's image cache. A tight box keeps the
      // space stable from the very first frame, loaded or not.
      //
      // The box is sized to the logo's own aspect ratio (from TMDB) rather
      // than a flat 120 wide: the title bubble wraps this box, so a squarer
      // logo contain-fitted into 120×28 left the bubble with a long empty
      // tail. Capped at 120 wide; unknown ratio falls back to 120.
      final ratio = m.logoAspectRatio;
      final width = ratio == null ? 120.0 : math.min(120.0, 28 * ratio);
      if (m.logoUrl!.toLowerCase().endsWith('.svg')) {
        return SizedBox(
          width: width,
          height: 28,
          child: SvgPicture.network(
            m.logoUrl!,
            alignment: Alignment.centerLeft,
            fit: BoxFit.contain,
          ),
        );
      } else {
        return SizedBox(
          width: width,
          height: 28,
          child: CachedNetworkImage(
            imageUrl: m.logoUrl!,
            memCacheHeight:
                (28 * MediaQuery.of(context).devicePixelRatio).toInt(),
            alignment: Alignment.centerLeft,
            fit: BoxFit.contain,
          ),
        );
      }
    }
    return Text(
      m.title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Not wrapped in ListenableBuilder(SavedMoviesService()) anymore — the
    // only thing here that depended on it (historyMovie, for the
    // Play/Resume button) now has its own narrowly-scoped ListenableBuilder
    // further down, so a favorite/history change elsewhere in the app no
    // longer rebuilds this entire screen (title, cast, episode list, etc).
    return (() {
      final m = _details ?? widget.movie;
      final bool isTv = m.type == 'tv';
      final bool hidePlayback = FeatureFlagsService().hidePlayback.value;

      return Scaffold(
        extendBodyBehindAppBar: true,
        // Scoped to the scroll controller so the fade/sticky-title rebuild
        // on scroll stays local to the AppBar instead of the whole screen.
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: ValueListenableBuilder<double>(
            valueListenable: _scrollOffset,
            builder: (context, offset, _) {
              // Logo reveal point — unchanged from before.
              final showTitle = offset > 350;
              // No full-width bar background: the back button and the logo
              // form one frosted "water bubble" (GlassBubbleBar) — the logo's
              // bubble grows out of the back button at showTitle and
              // shrinks back into it, over 300ms.
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: showTitle ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 300),
                builder: (context, reveal, child) {
                  return CustomAppBar(
                    forceOpacity: 0,
                    automaticallyImplyLeading: false,
                    // Puts the bubble's circle exactly where the old 56px
                    // leading slot's padded back button sat.
                    titleSpacing: 8,
                    // The logo stays mounted while hidden, so its image has
                    // usually finished loading by the time it's revealed.
                    title: GlassBubbleBar(
                      reveal: reveal,
                      leading: CircleAvatar(
                        backgroundColor: Colors.transparent,
                        child: widget.isSidePanel
                            ? IconButton(
                                icon: const Icon(Icons.close,
                                    color: Colors.white),
                                onPressed: widget.onClose,
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                              )
                            : const BackButton(color: Colors.white),
                      ),
                      title: _buildAppBarTitle(m),
                    ),
                    showActions: false,
                    // Favorite/like toggle moved down to the action button row
                    // (where Share used to be), so no actions shown up here.
                    showModeSwitch: false,
                  );
                },
              );
            },
          ),
        ),
        body: _revealOverSkeleton(_loading
            ? const SizedBox.shrink()
            : Stack(
                children: [
                  // Parallax background image — kept OUTSIDE the sliver tree.
                  // A SliverToBoxAdapter stops painting its child entirely
                  // once the scroll offset passes the child's declared
                  // height, but this image's Transform.translate deliberately
                  // keeps it onscreen past that point (half-speed parallax
                  // lag). Combining the two made the sliver geometry cull the
                  // header mid-lag, which showed up as the content below it
                  // flickering in and out as the header abruptly popped in
                  // and out of existence while scrolling. Rendering it as a
                  // plain Positioned sibling — clipped by a fixed-size Stack
                  // instead of sliver geometry — keeps it continuous.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(
                      height: 450,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ValueListenableBuilder<double>(
                            // See _scrollOffset — a plain controller listener
                            // missed position corrections (e.g. after the
                            // synopsis collapses) and left this stuck.
                            valueListenable: _scrollOffset,
                            builder: (context, offset, child) {
                              return Transform.translate(
                                offset: Offset(0, -offset * 0.5),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Hero(
                                      tag: 'movie_${m.id}',
                                      // Full-width parallax header — like the
                                      // home hero banners, this renders large
                                      // enough that TMDB's standard w1280
                                      // backdrop tier can look soft, so it
                                      // uses the full-resolution source.
                                      child: _backdropUrlFor(m)
                                              .toLowerCase()
                                              .endsWith('.svg')
                                          ? SvgPicture.network(
                                              _backdropUrlFor(m),
                                              fit: BoxFit.cover,
                                            )
                                          : CachedNetworkImage(
                                              // Preloaded behind the skeleton
                                              // (_preloadHeader) — keep the URL
                                              // and memCacheHeight in sync.
                                              imageUrl: _backdropUrlFor(m),
                                              fit: BoxFit.cover,
                                              // Only constrain height, not width — specifying
                                              // both distorts the image whenever the source's
                                              // aspect ratio doesn't match this exact box
                                              // (ResizeImagePolicy.exact stretches to fit both
                                              // dimensions). One dimension lets the decoder
                                              // scale the other proportionally, matching how
                                              // BoxFit.cover actually crops at paint time.
                                              memCacheHeight: (450 *
                                                      MediaQuery.of(context)
                                                          .devicePixelRatio)
                                                  .toInt(),
                                            ),
                                    ),
                                    // Gradient moves with image
                                    Container(
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black,
                                          ],
                                          stops: [0.4, 1.0],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      // Header spacer — reserves 450px of scroll space for
                      // the background image above, and carries the
                      // logo/title/rating overlay, which (unlike the image)
                      // scrolls in lockstep with the rest of the content
                      // instead of lagging behind.
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 450,
                          child: Stack(
                            children: [
                              Positioned(
                                bottom: 20,
                                left: 24,
                                right: 24,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _logoUrlFor(m) != null
                                        ? (_logoUrlFor(m)!
                                                .toLowerCase()
                                                .endsWith('.svg')
                                            ? SvgPicture.network(
                                                _logoUrlFor(m)!,
                                                width: 200,
                                                fit: BoxFit.contain,
                                                alignment: Alignment.centerLeft,
                                              )
                                            : CachedNetworkImage(
                                                // Preloaded behind the skeleton
                                                // (_preloadHeader) — keep the
                                                // URL and memCacheWidth in sync.
                                                imageUrl: _logoUrlFor(m)!,
                                                width: 200,
                                                memCacheWidth: (200 *
                                                        MediaQuery.of(context)
                                                            .devicePixelRatio)
                                                    .toInt(),
                                                fit: BoxFit.contain,
                                                alignment: Alignment.centerLeft,
                                              ))
                                        : Text(
                                            m.title,
                                            style: const TextStyle(
                                              fontSize: 32,
                                              fontWeight: FontWeight.bold,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 10,
                                                ),
                                              ],
                                            ),
                                          ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          '${m.year}  •  ${m.certification ?? "PG-13"}  •  ${m.runtime ?? "N/A"}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const Spacer(),
                                        const Icon(
                                          Icons.star,
                                          color: Colors.amber,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          m.rating,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.amber,
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Genres as quiet metadata under the
                                    // year/rating/runtime line, the way
                                    // streaming apps show them, instead of
                                    // chips competing with the buttons.
                                    if (m.genres != null &&
                                        m.genres!.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        m.genres!.join('  ·  '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.white
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(24, 24, 24, isTv ? 0 : 24),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            // Dynamic Torrent & Web Server Play Controls.
                            // Scoped to its own ListenableBuilder — this is the
                            // only part of the screen that needs historyMovie
                            // (for the Play/Resume label), so a favorite/history
                            // change elsewhere only rebuilds this button row,
                            // not the whole details screen.
                            ListenableBuilder(
                              listenable: SavedMoviesService(),
                              builder: (context, _) {
                                final historyMovie = SavedMoviesService()
                                    .getMovieFromHistory(widget.movie.id);

                                // Whether the "quick play" target isn't out yet,
                                // so the button can look disabled instead of
                                // looking normal but silently rejecting taps.
                                final movieUnreleased = !isTv && m.isUnreleased;
                                Episode? tvTargetEpisode;
                                if (isTv) {
                                  final targetSeasonNum =
                                      historyMovie?.currentSeason ?? 1;
                                  final targetEpNum =
                                      historyMovie?.currentEpisode ?? 1;
                                  // Best-effort: only accurate once the target
                                  // season's episodes are loaded (always true
                                  // for the common S1E1 case, since season 1
                                  // loads on details-screen open).
                                  if ((_selectedSeason?.seasonNumber ?? 1) ==
                                      targetSeasonNum) {
                                    for (final ep in _episodes) {
                                      if (ep.episodeNumber == targetEpNum) {
                                        tvTargetEpisode = ep;
                                        break;
                                      }
                                    }
                                  }
                                }
                                final tvUnreleased =
                                    tvTargetEpisode?.isUnreleased ?? false;

                                String? releaseDateText(String? raw) {
                                  if (raw == null) return null;
                                  final parsed = DateTime.tryParse(raw);
                                  if (parsed == null) return null;
                                  return 'Releases ${_formatReleaseDate(parsed)}';
                                }

                                final movieReleaseText = movieUnreleased
                                    ? releaseDateText(m.releaseDateRaw)
                                    : null;
                                final tvReleaseText = tvUnreleased
                                    ? releaseDateText(tvTargetEpisode?.airDate)
                                    : null;

                                final defaultProvider =
                                    Platform.isIOS ? 'vsembed' : 'vidlink';
                                final altProvider =
                                    Platform.isIOS ? 'vidlink' : 'vsembed';
                                final altLabel =
                                    Platform.isIOS ? 'Server 1' : 'Server 4';
                                // Streaming service carrying this title in
                                // the user's country, if any: attached to
                                // the Play pill, or replacing it while
                                // playback is hidden.
                                final provider = m.streamingProvider;

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        // Hidden entirely (not just disabled) when
                                        // FeatureFlagsService.hidePlayback is on.
                                        if (!hidePlayback) ...[
                                          if (!isTv)
                                            // Premium Direct Torrent Play Button
                                            Expanded(
                                              flex: provider != null ? 4 : 3,
                                              child: Container(
                                                height: 50,
                                                decoration: BoxDecoration(
                                                  color: movieUnreleased
                                                      ? Colors.white10
                                                      : Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  boxShadow: movieUnreleased
                                                      ? null
                                                      : [
                                                          BoxShadow(
                                                            color: Colors.white
                                                                .withOpacity(
                                                                    0.15),
                                                            blurRadius: 12,
                                                            offset: const Offset(
                                                                0, 4),
                                                          ),
                                                        ],
                                                ),
                                                child: _withProviderSegment(provider, InkWell(
                                                  onTap: movieUnreleased
                                                      ? null
                                                      : _playWithTorrent,
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment.center,
                                                    children: [
                                                      Icon(
                                                        movieUnreleased
                                                            ? Icons
                                                                .event_available
                                                            : Icons
                                                                .play_arrow_rounded,
                                                        color: movieUnreleased
                                                            ? Colors.white54
                                                            : Colors.black,
                                                        size: movieUnreleased
                                                            ? 20
                                                            : 28,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: Text(
                                                          movieUnreleased
                                                              ? (movieReleaseText ??
                                                                  'Not yet released')
                                                              : (historyMovie?.progress !=
                                                                          null &&
                                                                      historyMovie!
                                                                              .progress! >
                                                                          0
                                                                  ? 'Resume'
                                                                  : 'Play Movie'),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          maxLines: 1,
                                                          style: TextStyle(
                                                            color: movieUnreleased
                                                                ? Colors.white54
                                                                : Colors.black,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize:
                                                                movieUnreleased
                                                                    ? 11
                                                                    : 16,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                ),
                                              ),
                                            )
                                          else
                                            // TV Show Play/Resume direct Button
                                            Expanded(
                                              flex: provider != null ? 4 : 3,
                                              child: Container(
                                                height: 50,
                                                decoration: BoxDecoration(
                                                  color: tvUnreleased
                                                      ? Colors.white10
                                                      : Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  boxShadow: tvUnreleased
                                                      ? null
                                                      : [
                                                          BoxShadow(
                                                            color: Colors.white
                                                                .withOpacity(
                                                                    0.15),
                                                            blurRadius: 12,
                                                            offset: const Offset(
                                                                0, 4),
                                                          ),
                                                        ],
                                                ),
                                                child: _withProviderSegment(provider, InkWell(
                                                  onTap: tvUnreleased
                                                      ? null
                                                      : () async {
                                                          int s = historyMovie
                                                                  ?.currentSeason ??
                                                              1;
                                                          int e = historyMovie
                                                                  ?.currentEpisode ??
                                                              1;
                                                          if (_details?.seasons !=
                                                                  null &&
                                                              _details!.seasons!
                                                                  .isNotEmpty) {
                                                            setState(() {
                                                              _selectedSeason =
                                                                  _details!
                                                                      .seasons!
                                                                      .firstWhere(
                                                                (sea) =>
                                                                    sea.seasonNumber ==
                                                                    s,
                                                                orElse: () =>
                                                                    _details!
                                                                        .seasons!
                                                                        .first,
                                                              );
                                                              _selectedEpisode =
                                                                  e;
                                                            });
                                                          } else {
                                                            _selectedEpisode = e;
                                                          }
  
                                                          await _loadSeasonDetails(
                                                              s);
                                                          _playWithTorrent();
                                                        },
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment.center,
                                                    children: [
                                                      Icon(
                                                        tvUnreleased
                                                            ? Icons
                                                                .event_available
                                                            : (historyMovie?.currentSeason !=
                                                                    null
                                                                ? Icons
                                                                    .play_circle_filled
                                                                : Icons
                                                                    .play_arrow_rounded),
                                                        color: tvUnreleased
                                                            ? Colors.white54
                                                            : Colors.black,
                                                        size: tvUnreleased
                                                            ? 20
                                                            : 28,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: Text(
                                                          tvUnreleased
                                                              ? (tvReleaseText ??
                                                                  'Not yet released')
                                                              : (historyMovie
                                                                          ?.currentSeason !=
                                                                      null
                                                                  ? 'Resume S${historyMovie!.currentSeason} E${historyMovie.currentEpisode}'
                                                                  : 'Play S1 E1'),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          maxLines: 1,
                                                          style: TextStyle(
                                                            color: tvUnreleased
                                                                ? Colors.white54
                                                                : Colors.black,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: tvUnreleased
                                                                ? 11
                                                                : 16,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                ),
                                              ),
                                            ),
                                          const SizedBox(width: 12),
                                        ] else if (provider != null) ...[
                                          // Playback hidden: the pill becomes
                                          // a link to the service instead.
                                          Expanded(
                                            flex: 4,
                                            child: _WatchOnProviderButton(
                                              provider: provider,
                                              onTap: () =>
                                                  _openProvider(provider),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                        ],
                                        // Trailer Button — icon-only (like the
                                        // Like button) when a streaming service
                                        // shares the row, so the Play / Watch
                                        // on pill keeps room for its label.
                                        if (m.trailerUrl != null &&
                                            provider != null)
                                          Container(
                                            height: 50,
                                            width: 50,
                                            decoration: BoxDecoration(
                                              color: Colors.white10,
                                              borderRadius:
                                                  BorderRadius.circular(30),
                                            ),
                                            child: InkWell(
                                              onTap: () =>
                                                  _openTrailer(m.trailerUrl!),
                                              borderRadius:
                                                  BorderRadius.circular(30),
                                              child: const Icon(
                                                Icons.movie_creation_outlined,
                                                color: Colors.white,
                                                semanticLabel: 'Trailer',
                                              ),
                                            ),
                                          )
                                        else if (m.trailerUrl != null)
                                          Expanded(
                                            flex: 2,
                                            child: Container(
                                              height: 50,
                                              decoration: BoxDecoration(
                                                color: Colors.white10,
                                                borderRadius:
                                                    BorderRadius.circular(30),
                                              ),
                                              child: InkWell(
                                                onTap: () =>
                                                    _openTrailer(m.trailerUrl!),
                                                borderRadius:
                                                    BorderRadius.circular(30),
                                                child: const Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Icon(
                                                      Icons
                                                          .movie_creation_outlined,
                                                      color: Colors.white,
                                                    ),
                                                    SizedBox(width: 8),
                                                    Text(
                                                      'Trailer',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 16,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (!hidePlayback || m.trailerUrl != null)
                                          const SizedBox(width: 12),
                                        // Share Button — functionality kept, just not shown right now.
                                        // Container(
                                        //   height: 50,
                                        //   width: 50,
                                        //   decoration: BoxDecoration(
                                        //     color: Colors.white10,
                                        //     borderRadius:
                                        //         BorderRadius.circular(30),
                                        //   ),
                                        //   child: InkWell(
                                        //     onTap: _shareMovie,
                                        //     borderRadius:
                                        //         BorderRadius.circular(30),
                                        //     child: const Icon(
                                        //       Icons.share_outlined,
                                        //       color: Colors.white,
                                        //     ),
                                        //   ),
                                        // ),
                                        // Like Button — moved here from the AppBar.
                                        Container(
                                          height: 50,
                                          width: 50,
                                          decoration: BoxDecoration(
                                            color: Colors.white10,
                                            borderRadius:
                                                BorderRadius.circular(30),
                                          ),
                                          child: InkWell(
                                            onTap: _toggleFavorite,
                                            borderRadius:
                                                BorderRadius.circular(30),
                                            child: Icon(
                                              SavedMoviesService()
                                                      .isFavorite(
                                                          widget.movie.id)
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              color: SavedMoviesService()
                                                      .isFavorite(
                                                          widget.movie.id)
                                                  ? AppTheme.primaryColor
                                                  : Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    // TMDB requires crediting JustWatch for
                                    // watch-provider data.
                                    if (provider != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            top: 10, left: 4),
                                        child: Text(
                                          'Streaming info by JustWatch',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white
                                                .withValues(alpha: 0.4),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 24),

                            // Series: the cast lives inside the synopsis's
                            // More, keeping the page compact above the
                            // episode list. Movies have nothing below, so
                            // everything is shown up front.
                            ExpandableSynopsis(
                              text: m.description,
                              collapsible: isTv,
                              extra: m.castMembers != null &&
                                      m.castMembers!.isNotEmpty
                                  // Bleeds 24px each side, matching this
                                  // list's horizontal padding, so it
                                  // scrolls edge to edge.
                                  ? CastRow(cast: m.castMembers!, bleed: 24)
                                  : null,
                            ),

                            // TV Show: Seasons & Episodes
                            if (isTv) ...[
                              const SizedBox(height: 40),

                              // Header + Season Selector Row
                              if (m.seasons != null && m.seasons!.isNotEmpty)
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      "Episodes",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    // Minimalist Netflix-style Season Selector
                                    Builder(
                                      builder: (btnContext) {
                                        return TextButton.icon(
                                          style: TextButton.styleFrom(
                                            backgroundColor:
                                                Colors.white.withOpacity(0.08),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 6),
                                          ),
                                          icon: const Icon(Icons.layers_rounded,
                                              color: Colors.white, size: 16),
                                          label: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                _selectedSeason?.seasonNumber ==
                                                        0
                                                    ? 'Specials'
                                                    : 'Season ${_selectedSeason?.seasonNumber ?? 1}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 11,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(
                                                  Icons.keyboard_arrow_down,
                                                  color: Colors.white54,
                                                  size: 14),
                                            ],
                                          ),
                                          onPressed: () async {
                                            final RenderBox renderBox =
                                                btnContext.findRenderObject()
                                                    as RenderBox;
                                            final offset = renderBox
                                                .localToGlobal(Offset.zero);
                                            final val = await showMenu<int>(
                                              context: context,
                                              position: RelativeRect.fromLTRB(
                                                offset.dx,
                                                offset.dy +
                                                    renderBox.size.height +
                                                    4,
                                                offset.dx +
                                                    renderBox.size.width,
                                                0,
                                              ),
                                              color: Colors.grey[900],
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8)),
                                              items: m.seasons!
                                                  .where(
                                                    (s) =>
                                                        s.seasonNumber > 0 ||
                                                        s.seasonNumber ==
                                                            _selectedSeason
                                                                ?.seasonNumber,
                                                  )
                                                  .map((s) => PopupMenuItem(
                                                        value: s.seasonNumber,
                                                        height: 40,
                                                        child: Text(
                                                          s.seasonNumber == 0
                                                              ? 'Specials'
                                                              : 'Season ${s.seasonNumber}',
                                                          style: TextStyle(
                                                            color: s.seasonNumber ==
                                                                    _selectedSeason
                                                                        ?.seasonNumber
                                                                ? AppTheme
                                                                    .primaryColor
                                                                : Colors.white,
                                                            fontSize: 13,
                                                            fontWeight: s.seasonNumber ==
                                                                    _selectedSeason
                                                                        ?.seasonNumber
                                                                ? FontWeight
                                                                    .bold
                                                                : FontWeight
                                                                    .w500,
                                                          ),
                                                        ),
                                                      ))
                                                  .toList(),
                                            );
                                            if (val != null) {
                                              setState(() {
                                                _selectedSeason =
                                                    m.seasons!.firstWhere(
                                                  (s) => s.seasonNumber == val,
                                                );
                                                _selectedEpisode =
                                                    null; // Reset episode
                                              });
                                              _loadSeasonDetails(val);
                                            }
                                          },
                                        );
                                      },
                                    ),
                                  ],
                                ),

                              const SizedBox(height: 16),
                            ],
                          ]),
                        ),
                      ),

                      // Episode list — a separate sliver (not nested inside the
                      // regular-content SliverList above) so it's genuinely lazy
                      // via SliverList.builder, instead of the old shrinkWrap:
                      // true + NeverScrollableScrollPhysics ListView.builder,
                      // which forced every episode row to build up front
                      // regardless of scroll position. Matters a lot for shows
                      // with long seasons (100+ episodes).
                      if (isTv)
                        if (_loadingEpisodes)
                          const SliverPadding(
                            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
                            sliver: SliverToBoxAdapter(child: ShimmerList()),
                          )
                        else if (_episodes.isEmpty)
                          const SliverPadding(
                            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
                            sliver: SliverToBoxAdapter(
                              child: Text(
                                "No episodes available.",
                                style: TextStyle(color: Colors.white54),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                            sliver: SliverList.builder(
                              itemCount: _episodes.length,
                              itemBuilder: (context, index) {
                                final ep = _episodes[index];
                                final currentProgress = hidePlayback
                                    ? null
                                    : SavedMoviesService().getEpisodeProgress(
                                          widget.movie.id,
                                          _selectedSeason?.seasonNumber ?? 1,
                                          ep.episodeNumber,
                                        ) ??
                                        ep.progress;

                                bool isFuture = false;
                                String? formattedDate;

                                if (ep.airDate != null) {
                                  try {
                                    final date = DateTime.parse(ep.airDate!);
                                    if (date.isAfter(DateTime.now())) {
                                      isFuture = true;
                                      formattedDate =
                                          "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
                                    }
                                  } catch (_) {}
                                }

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 16),
                                  child: InkWell(
                                    onTap: isFuture || hidePlayback
                                        ? null
                                        : () {
                                            setState(() {
                                              _selectedEpisode =
                                                  ep.episodeNumber;
                                            });
                                            _playWithTorrent();
                                          },
                                    borderRadius: BorderRadius.circular(4),
                                    child: Row(
                                      children: [
                                        // Thumbnail
                                        Container(
                                          width: 140,
                                          height: 80,
                                          margin: const EdgeInsets.only(
                                            right: 12,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            image: DecorationImage(
                                              image: CachedNetworkImageProvider(
                                                ep.stillPath ??
                                                    m.backdrop ??
                                                    '',
                                                maxWidth: (140 *
                                                        MediaQuery.of(context)
                                                            .devicePixelRatio)
                                                    .toInt(),
                                                maxHeight: (80 *
                                                        MediaQuery.of(context)
                                                            .devicePixelRatio)
                                                    .toInt(),
                                              ),
                                              fit: BoxFit.cover,
                                              colorFilter: isFuture
                                                  ? const ColorFilter.mode(
                                                      Colors.black54,
                                                      BlendMode.darken,
                                                    )
                                                  : null,
                                              opacity: isFuture ? 0.6 : 1.0,
                                            ),
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              isFuture
                                                  ? const Center(
                                                      child: Icon(
                                                        Icons.lock_clock,
                                                        color: Colors.white54,
                                                        size: 24,
                                                      ),
                                                    )
                                                  : hidePlayback
                                                      ? const SizedBox.shrink()
                                                      : Container(
                                                          color: Colors.black26,
                                                          child: const Center(
                                                            child: Icon(
                                                              Icons
                                                                  .play_circle_outline,
                                                              color: Colors.white,
                                                              size: 32,
                                                            ),
                                                          ),
                                                        ),
                                              // Progress Bar
                                              if (currentProgress != null &&
                                                  currentProgress > 0)
                                                Positioned(
                                                  bottom: 4,
                                                  left: 6,
                                                  right: 6,
                                                  child: Container(
                                                    height: 4,
                                                    decoration: BoxDecoration(
                                                      color: Colors.black54,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              4),
                                                    ),
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              4),
                                                      child:
                                                          FractionallySizedBox(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        widthFactor:
                                                            currentProgress
                                                                .clamp(
                                                                    0.0, 1.0),
                                                        child: Container(
                                                            color: AppTheme
                                                                .primaryColor),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),

                                        // Info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${ep.episodeNumber}. ${ep.name}',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: isFuture
                                                      ? Colors.white54
                                                      : Colors.white,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                ep.overview.isNotEmpty
                                                    ? ep.overview
                                                    : "No description available.",
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              isFuture && formattedDate != null
                                                  ? Text(
                                                      'Available on: $formattedDate',
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: AppTheme
                                                            .primaryColor,
                                                        fontStyle:
                                                            FontStyle.italic,
                                                      ),
                                                    )
                                                  : Text(
                                                      '${ep.voteAverage.toStringAsFixed(1)} ★',
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        color: Colors.white54,
                                                      ),
                                                    ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: MediaQuery.of(context).padding.bottom,
                        ),
                      ),
                    ],
                  ),
                ],
              )),
      );
    })();
  }

  /// Skeleton → page reveal, same approach as the startup splash in
  /// main.dart: once loaded, the page is built *underneath* the still-
  /// opaque skeleton (so its expensive first frames — layout, uploading the
  /// big header images — happen out of sight), then the skeleton fades off
  /// it, instead of hard-cutting between the two in one heavy frame.
  Widget _revealOverSkeleton(Widget page) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Catches the page scroll view's notifications (see _scrollOffset).
        NotificationListener<Notification>(
          onNotification: _onPageScroll,
          child: page,
        ),
        if (!_skeletonDone)
          IgnorePointer(
            ignoring: !_loading,
            child: AnimatedOpacity(
              opacity: _skeletonFading ? 0 : 1,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              onEnd: () {
                if (_skeletonFading && mounted) {
                  setState(() => _skeletonDone = true);
                }
              },
              child: const ColoredBox(
                color: AppTheme.scaffoldColor,
                child: SkeletonDetails(),
              ),
            ),
          ),
      ],
    );
  }
}

class TorrentQualitySelectorSheet extends StatefulWidget {
  final String imdbId;
  final String type;
  final int? season;
  final int? episode;
  final StreamResolver resolver;
  final Movie movie;
  final Movie details;
  final List<Episode> episodes;
  final Function(String) onFallback;
  final Function(TorrentStream, String resolvedUrl, int? torrentId,
      List<TorrentStream> updatedStreams)? onStreamSelected;
  final bool resolveOnSelect;

  const TorrentQualitySelectorSheet({
    required this.imdbId,
    required this.type,
    this.season,
    this.episode,
    required this.resolver,
    required this.movie,
    required this.details,
    required this.episodes,
    required this.onFallback,
    this.onStreamSelected,
    this.resolveOnSelect = true,
  });

  @override
  State<TorrentQualitySelectorSheet> createState() =>
      _TorrentQualitySelectorSheetState();
}

class _TorrentQualitySelectorSheetState
    extends State<TorrentQualitySelectorSheet> {
  List<TorrentStream>? _streams;
  bool _loading = true;
  String? _error;
  String? _resolvingMessage;
  // Why the last tapped stream failed to start. Shown inside the sheet —
  // a SnackBar would land on the details screen *behind* this modal sheet.
  String? _resolveError;
  String? _lastPlayedHash;

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  Future<void> _loadStreams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String key = widget.season != null && widget.episode != null
          ? 'last_played_torrent_${widget.imdbId}_${widget.season}_${widget.episode}'
          : 'last_played_torrent_${widget.imdbId}';
      _lastPlayedHash = prefs.getString(key);

      final list = await widget.resolver.getAvailableStreams(
        imdbId: widget.imdbId,
        type: widget.type,
        season: widget.season,
        episode: widget.episode,
      );

      if (mounted) {
        if (_lastPlayedHash != null && list.isNotEmpty) {
          final idx = list.indexWhere((s) =>
              s.infoHash.toLowerCase() == _lastPlayedHash!.toLowerCase());
          if (idx != -1) {
            final lastPlayed = list.removeAt(idx);
            list.insert(0, lastPlayed);
          }
        }

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

  void _selectStream(TorrentStream stream) async {
    if (widget.onStreamSelected != null && !widget.resolveOnSelect) {
      Navigator.pop(context);
      widget.onStreamSelected!(
        stream,
        '',
        null,
        _streams ?? [stream],
      );
      return;
    }

    setState(() {
      _resolvingMessage = 'Connecting to peers & starting stream...';
      _resolveError = null;
    });

    try {
      // Resolve the tapped stream, automatically trying the next-best
      // candidates if it fails or times out — Torrentio's seed counts are
      // often stale, so one dead pick shouldn't send the user straight to
      // the web-embed fallback when another torrent would have worked.
      final resolved = await widget.resolver
          .resolveWithFallback(stream, _streams ?? [stream]);
      final resolvedStream = resolved.stream;
      final result = resolved.result;

      // Save last played torrent infohash — the one that actually resolved,
      // not necessarily the one originally tapped.
      final prefs = await SharedPreferences.getInstance();
      final String key = widget.season != null && widget.episode != null
          ? 'last_played_torrent_${widget.imdbId}_${widget.season}_${widget.episode}'
          : 'last_played_torrent_${widget.imdbId}';
      await prefs.setString(key, resolvedStream.infoHash);

      // Record which movie/episode this download is and how big it's
      // supposed to be, so Settings > Storage can show something more
      // useful than a bare infoHash (see TorrentDownloadRegistry).
      await TorrentDownloadRegistry.save(
        resolvedStream.infoHash,
        TorrentDownloadInfo(
          movieId: widget.movie.id,
          imdbId: widget.imdbId,
          title: widget.movie.title,
          image: widget.movie.image,
          season: widget.season,
          episode: widget.episode,
          totalBytes: TorrentDownloadRegistry.parseSizeBytes(resolvedStream.size),
        ),
      );

      // Add to history
      await SavedMoviesService().addToHistory(
        widget.movie,
        season: widget.season,
        episode: widget.episode,
      );

      if (!mounted) return;
      Navigator.pop(context); // Pop bottom sheet

      if (widget.onStreamSelected != null) {
        widget.onStreamSelected!(
          resolvedStream,
          result.streamUrl,
          result.torrentId,
          _streams ?? [stream],
        );
        return;
      }

      // Navigate to premium native player
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            url: result.streamUrl,
            torrentId: result.torrentId,
            streamId: result.streamId,
            selectedStream: resolvedStream,
            availableStreams: _streams ?? [stream],
            movie: widget.movie,
            details: widget.details,
            season: widget.season,
            episode: widget.episode,
            episodes: widget.episodes,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _resolvingMessage = null;
          _resolveError = 'Couldn\'t start this source: '
              '${e.toString().replaceFirst(RegExp(r'^(Exception|Bad state): '), '')}\n'
              'Try another source, or use "Alternative Web Servers" below.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final double initialSize = isLandscape ? 0.85 : 0.6;
    final double minSize = isLandscape ? 0.45 : 0.4;
    final double maxSize = isLandscape ? 0.95 : 0.9;

    return DraggableScrollableSheet(
      initialChildSize: initialSize,
      minChildSize: minSize,
      maxChildSize: maxSize,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0C0C0C),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: Colors.white12, width: 0.5),
            ),
          ),
          padding: EdgeInsets.only(
            top: isLandscape ? 6 : 8,
            left: 20,
            right: 20,
            bottom:
                (isLandscape ? 10 : 20) + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: isLandscape ? 8 : 16),

              // Header Text
              Row(
                children: [
                  Icon(Icons.bolt, color: AppTheme.primaryColor, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _resolvingMessage != null
                          ? 'Preparing Playback'
                          : 'Select Stream Quality',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (_resolvingMessage == null)
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white38, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                ],
              ),
              SizedBox(height: isLandscape ? 8 : 16),

              if (_resolveError != null && _resolvingMessage == null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                  decoration: BoxDecoration(
                    color: Colors.red[900]!.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.error_outline_rounded,
                            color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _resolveError!,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13, height: 1.35),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white70, size: 18),
                        onPressed: () => setState(() => _resolveError = null),
                      ),
                    ],
                  ),
                ),

              if (_resolvingMessage != null)
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: isLandscape ? 12 : 24),
                        const Center(child: ShimmerLoader(size: 90)),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            _resolvingMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 14),
                          ),
                        ),
                        SizedBox(height: isLandscape ? 16 : 32),
                      ],
                    ),
                  ),
                )
              else if (_loading)
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: isLandscape ? 20 : 40),
                        const Center(child: ShimmerLoader(size: 90)),
                        const SizedBox(height: 16),
                        const Center(
                          child: Text(
                            'Searching peer networks for torrents...',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                        ),
                        SizedBox(height: isLandscape ? 20 : 40),
                      ],
                    ),
                  ),
                )
              else if (_error != null)
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: isLandscape ? 10 : 20),
                        Center(
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                        SizedBox(height: isLandscape ? 10 : 20),
                      ],
                    ),
                  ),
                )
              else if (_streams == null || _streams!.isEmpty)
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: isLandscape ? 10 : 20),
                        const Center(
                          child: Text(
                            'No direct torrent streams available.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            'Try "Alternative Web Servers" below instead.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.3),
                                fontSize: 12),
                          ),
                        ),
                        SizedBox(height: isLandscape ? 10 : 20),
                      ],
                    ),
                  ),
                )
              else ...[
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _streams!.length,
                    itemBuilder: (context, index) {
                      final stream = _streams![index];
                      final isLastPlayed = _lastPlayedHash != null &&
                          stream.infoHash.toLowerCase() ==
                              _lastPlayedHash!.toLowerCase();
                      final isRecommended = index == 0 && !isLastPlayed;
                      final isHighlighted = isLastPlayed || isRecommended;

                      return Card(
                        color: Colors.white.withOpacity(0.03),
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isHighlighted
                                ? (isLastPlayed
                                        ? AppTheme.primaryColor
                                        : Colors.amber)
                                    .withOpacity(0.4)
                                : Colors.white.withOpacity(0.05),
                            width: isHighlighted ? 1.5 : 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: () => _selectStream(stream),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    // Quality Badge
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: stream.quality == '4K'
                                            ? Colors.amber.withOpacity(0.15)
                                            : AppTheme.primaryColor
                                                .withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        stream.quality ?? '1080p',
                                        style: TextStyle(
                                          color: stream.quality == '4K'
                                              ? Colors.amber
                                              : AppTheme.primaryColor,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Size Badge
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        stream.size ?? 'Unknown size',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    if (isLastPlayed) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.primaryColor,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Text(
                                          'LAST PLAYED',
                                          style: TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 9,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                    ] else if (isRecommended) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.amber,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Text(
                                          'RECOMMENDED',
                                          style: TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 9,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    // Seeders
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.speed,
                                          size: 14,
                                          color: Colors.green,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${stream.seeders ?? 0} seeds',
                                          style: const TextStyle(
                                            color: Colors.green,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // Name of the torrent release
                                Text(
                                  stream.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    height: 1.3,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Provider/Source
                                Text(
                                  'Source: ${stream.source ?? "P2P"}',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.3),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              SizedBox(height: isLandscape ? 8 : 16),
              // Alternate Web Servers Dropdown
              Center(
                child: PopupMenuButton<String>(
                  offset: const Offset(0, -150),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  color: Colors.grey[950],
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.language,
                            size: 16, color: Colors.white.withOpacity(0.5)),
                        const SizedBox(width: 6),
                        Text(
                          'Alternative Web Servers (No Torrenting)',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_drop_up,
                            size: 16, color: Colors.white.withOpacity(0.5)),
                      ],
                    ),
                  ),
                  itemBuilder: (context) {
                    final defaultProvider =
                        Platform.isIOS ? 'vsembed' : 'vidlink';
                    final altProvider = Platform.isIOS ? 'vidlink' : 'vsembed';
                    final altLabel = Platform.isIOS ? 'Server 1' : 'Server 4';
                    return [
                      PopupMenuItem(
                        value: defaultProvider,
                        child: Text(
                          Platform.isIOS ? 'Server 4' : 'Server 1',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'moviesapi',
                        child: Text(
                          'Server 2',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const PopupMenuItem(
                        value: '2embed',
                        child: Text(
                          'Server 3',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      PopupMenuItem(
                        value: altProvider,
                        child: Text(
                          altLabel,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ];
                  },
                  onSelected: (val) {
                    Navigator.pop(context);
                    widget.onFallback(val);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A streaming service's square app-icon logo, rounded like an app icon:
/// bundled for the major services (instant), otherwise loaded from TMDB,
/// falling back to its initial if the image can't load.
class _ProviderLogo extends StatelessWidget {
  final StreamingProvider provider;
  final double size;

  const _ProviderLogo({required this.provider, required this.size});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: Colors.black,
      child: Text(
        provider.name.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: size * 0.5,
        ),
      ),
    );
    final asset = provider.bundledLogoAsset;
    final logo = provider.logoUrl;
    final Widget image;
    if (asset != null) {
      image = Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    } else if (logo != null) {
      image = CachedNetworkImage(
        imageUrl: logo,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      );
    } else {
      image = fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: image,
    );
  }
}

/// Stand-in for the Play pill while playback is hidden: same white pill,
/// with the service's logo and "Watch on {service}".
class _WatchOnProviderButton extends StatelessWidget {
  final StreamingProvider provider;
  final VoidCallback onTap;

  const _WatchOnProviderButton({required this.provider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ProviderLogo(provider: provider, size: 26),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Watch on ${provider.name}',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
