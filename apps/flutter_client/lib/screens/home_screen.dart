import 'dart:ui';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import 'details_screen.dart';
import '../widgets/hero_banner.dart';
import '../widgets/movie_poster.dart';
import '../services/saved_movies_service.dart';
import '../services/feature_flags_service.dart';
import '../widgets/skeletons.dart';
import 'desktop_home_screen.dart';
import '../widgets/desktop_skeletons.dart';
import '../widgets/custom_app_bar.dart';
import '../widgets/floating_bottom_nav_bar.dart';

class MovieHomeScreen extends StatefulWidget {
  const MovieHomeScreen({super.key});

  @override
  State<MovieHomeScreen> createState() => _MovieHomeScreenState();
}

class _MovieHomeScreenState extends State<MovieHomeScreen> {
  // The bottom nav bar swaps tabs via pushReplacement (to avoid back-stack
  // buildup), which tears down and recreates this widget on every visit to
  // the Home tab. Caching the loaded data at the class level survives that
  // recreation, so we only hit the network once per app session instead of
  // re-fetching (and re-rolling the random featured movie) every time.
  static List<Movie>? _cachedTrending;
  static List<Movie>? _cachedTopRated;
  static Movie? _cachedFeatured;

  final TMDBService _tmdb = TMDBService();
  final ScrollController _scrollController = ScrollController();

  List<Movie> _trendingMovies = [];
  List<Movie> _topRatedMovies = [];
  Movie? _featuredMovie;

  bool _loading = true;
  // Skeleton reveal stages after _loading turns false: fading out, then
  // removed (see _revealOverSkeleton).
  bool _skeletonFading = false;
  bool _skeletonDone = false;

  // Longest the skeleton waits on the hero's images before showing the
  // page anyway; anything slower finishes loading in place.
  static const _maxPreloadWait = Duration(seconds: 4);

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (_cachedTrending != null) {
      _trendingMovies = _cachedTrending!;
      _topRatedMovies = _cachedTopRated!;
      _featuredMovie = _cachedFeatured;
      _loading = false;
      _skeletonDone = true;
    } else {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    try {
      final trending = await _tmdb.getTrending();

      // Simulate "Top Rated" for now by fetching action movies or similar
      // Ideally we add a getTopRated() method to TMDBService later
      final topRated = trending.reversed.toList();

      // Fetch details for featured movie (for logo)
      Movie? featured;
      if (trending.isNotEmpty) {
        try {
          final randomIndex =
              Random().nextInt(min(trending.length, 5)); // Pick from top 5
          final basic = trending[randomIndex];
          featured = await _tmdb.getDetails(basic.id, type: basic.type);
        } catch (_) {}
      }

      final resolvedFeatured =
          trending.isNotEmpty ? (featured ?? trending.first) : null;

      _cachedTrending = trending;
      _cachedTopRated = topRated;
      _cachedFeatured = resolvedFeatured;

      if (!mounted) return;
      // Still behind the skeleton (_loading stays true).
      setState(() {
        _trendingMovies = trending;
        _topRatedMovies = topRated;
        if (resolvedFeatured != null) {
          _featuredMovie = resolvedFeatured;
        }
      });

      // Keep the skeleton up until the hero's backdrop and logo are
      // decoded, so the page doesn't appear with an empty black hero that
      // its artwork then pops into.
      if (resolvedFeatured != null) {
        try {
          await _precacheHero(resolvedFeatured).timeout(_maxPreloadWait);
        } catch (_) {
          // Timed out: show the page regardless.
        }
      }
    } catch (e) {
      print('Error loading home data: $e');
    }
    await _reveal();
  }

  Future<void> _precacheHero(Movie movie) {
    // Same breakpoint as build(): the desktop hero requests its images at
    // different sizes.
    return MediaQuery.sizeOf(context).width > 800
        ? DesktopHomeScreen.precacheHero(context, movie)
        : MovieHeroBanner.precache(context, movie);
  }

  /// Builds the page under the still-opaque skeleton, gives it a few
  /// frames to settle, then fades the skeleton off it (see
  /// _revealOverSkeleton).
  Future<void> _reveal() async {
    if (!mounted) return;
    setState(() => _loading = false);
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _skeletonFading = true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 800;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (!_loading)
              // Scoped to SavedMoviesService so Continue Watching (and the
              // desktop panel's historyMovies prop) only refresh when
              // history actually changes, instead of after every single
              // navigation return regardless of whether anything changed.
              ListenableBuilder(
                listenable: Listenable.merge([
                  SavedMoviesService(),
                  FeatureFlagsService().hidePlayback,
                ]),
                builder: (context, _) => _buildContent(context, constraints),
              ),
            if (!_skeletonDone) _revealOverSkeleton(wide: wide),
            // Above the skeleton, and only built once loaded: it plays a
            // staggered pop-in entrance the first time it's built, which
            // should show as the skeleton fades rather than happen out of
            // sight or sit there statically while loading. The desktop
            // layout has no bottom nav.
            if (!_loading && !(wide && _featuredMovie != null))
              const FloatingBottomNavBar(activeTab: BottomNavTab.home),
          ],
        );
      },
    );
  }

  /// Skeleton → page reveal, as on DetailsScreen: once loaded, the page is
  /// built *underneath* the still-opaque skeleton (so its expensive first
  /// frames — layout, uploading the hero images — happen out of sight),
  /// then the skeleton fades off it instead of hard-cutting in one frame.
  Widget _revealOverSkeleton({required bool wide}) {
    return IgnorePointer(
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
        child: Scaffold(
          body: wide ? const DesktopSkeletonHome() : const SkeletonHome(),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, BoxConstraints constraints) {
    final hidePlayback = FeatureFlagsService().hidePlayback.value;
    final history =
        hidePlayback ? const <Movie>[] : SavedMoviesService().history;
    // The hero shows More Info + Trailer (no Play button).
    final trailerUrl = _featuredMovie?.trailerUrl;
    final VoidCallback? onTrailer =
        trailerUrl != null ? () => _openTrailer(trailerUrl) : null;

    if (constraints.maxWidth > 800 && _featuredMovie != null) {
      return DesktopHomeScreen(
        featuredMovie: _featuredMovie!,
        trendingMovies: _trendingMovies,
        historyMovies: history,
        topRatedMovies: _topRatedMovies,
        onTrailerHero: onTrailer,
        onInfoHero: () => _navigateToDetails(
          _featuredMovie!,
          heroTag: 'hero_${_featuredMovie!.id}',
        ),
        onMovieTap: (movie) => _navigateToDetails(
          movie,
          heroTag: 'desktop_trending_${movie.id}',
        ),
        onRemoveHistory: (movie) => _confirmRemoveHistory(movie),
      );
    }

    final scaffold = Scaffold(
      extendBodyBehindAppBar: true,
      // No glass background: the bar stays transparent and the top edge
      // gets a scroll-in fade instead (see _withTopFade).
      appBar: const CustomAppBar(
        forceOpacity: 0,
        showActions: false,
        showModeSwitch: false,
      ),
      body: _withTopFade(SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          children: [
            // Hero Banner
            if (_featuredMovie != null)
              MovieHeroBanner(
                scrollController: _scrollController,
                movie: _featuredMovie!,
                onTrailer: onTrailer,
                onInfo: () => _navigateToDetails(
                  _featuredMovie!,
                  heroTag: 'hero_${_featuredMovie!.id}',
                ),
              ),

            const SizedBox(height: 20),

            // Continue Watching (History)
            if (history.isNotEmpty)
              _buildSection(
                title: "Continue Watching",
                movies: history,
                heroPrefix: "history",
              ),

            if (history.isNotEmpty)
              const SizedBox(height: 24),

            // Trending Section
            _buildSection(
              title: "Trending This Week",
              movies: _trendingMovies,
              heroPrefix: "trending",
            ),

            const SizedBox(height: 24),

            // Top Rated Section
            _buildSection(
              title: "Top Rated",
              movies: _topRatedMovies,
              heroPrefix: "top",
            ),

            SizedBox(height: 110 + MediaQuery.of(context).padding.bottom),
          ],
        ),
      )),
    );

    // FloatingBottomNavBar is added over this (and the skeleton) in build.
    return scaffold;
  }

  /// Top-edge fade over the scrolling content — the floating nav bar's
  /// bottom fade mirrored — fading in over the first 200px of scroll (the
  /// old glass app bar's timing) so the hero stays clear at the top. It's
  /// part of the body, so the Scaffold still paints the app bar's logo on
  /// top of it.
  Widget _withTopFade(Widget scrollView) {
    return Stack(
      children: [
        scrollView,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: _scrollController,
              builder: (context, _) {
                final offset =
                    _scrollController.hasClients ? _scrollController.offset : 0.0;
                return Opacity(
                  opacity: (offset / 200).clamp(0.0, 1.0),
                  child: Container(
                    height: MediaQuery.paddingOf(context).top +
                        kToolbarHeight +
                        40,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // FloatingBottomNavBar's [transparent, black] at
                        // [0.0, 0.6], flipped.
                        colors: [Colors.black, Colors.transparent],
                        stops: [0.4, 1.0],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _navigateToDetails(Movie movie, {String? heroTag}) async {
    // No manual refresh needed on return — _buildContent is wrapped in a
    // ListenableBuilder(SavedMoviesService()), so it already reacts on its
    // own if history actually changed (and skips a rebuild entirely for
    // the common case of just glancing at a title and backing out).
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => DetailsScreen(movie: movie, heroTag: heroTag),
      ),
    );
  }

  Future<void> _openTrailer(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _confirmRemoveHistory(Movie movie) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'Remove from History?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Are you sure you want to remove "${movie.title}" from your continue watching list?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // removeFromHistory() calls notifyListeners() itself — the
      // ListenableBuilder(SavedMoviesService()) around _buildContent picks
      // it up without a manual setState here.
      await SavedMoviesService().removeFromHistory(movie.id);
    }
  }

  Widget _buildSection({
    required String title,
    required List<Movie> movies,
    required String heroPrefix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        SizedBox(
          height: 220, // Height for poster + title generic
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            scrollDirection: Axis.horizontal,
            itemCount: movies.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final movie = movies[index];
              // Check if we have fresher data in history (for progress bar)
              final historyMovie = SavedMoviesService().getMovieFromHistory(
                movie.id,
              );
              final movieDisplay = historyMovie ?? movie;

              final tag = "${heroPrefix}_${movie.id}_$index";
              return MoviePoster(
                movie: movieDisplay,
                showTitle: true,
                heroTag: tag,
                onTap: () => _navigateToDetails(movieDisplay, heroTag: tag),
                onLongPress: heroPrefix == 'history'
                    ? () => _confirmRemoveHistory(movieDisplay)
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
