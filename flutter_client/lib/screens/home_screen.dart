import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../enums/app_mode.dart';
import '../models/movie.dart';
import '../services/app_mode_service.dart';
import '../services/tmdb_service.dart';
import 'quick_play.dart';
import 'details_screen.dart';
import '../widgets/hero_banner.dart';
import '../widgets/movie_poster.dart';
import '../services/saved_movies_service.dart';
import '../services/feature_flags_service.dart';
import '../services/tv_device.dart';
import '../widgets/skeletons.dart';
import 'desktop_home_screen.dart';
import '../widgets/desktop_skeletons.dart';
import '../widgets/custom_app_bar.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/smooth_scroll_controller.dart';

/// A video mode's home: Popcorn's ([AppMode.movies]) or Ramen's
/// ([AppMode.anime]), the same page with each one's own lists.
class MovieHomeScreen extends StatefulWidget {
  final AppMode mode;

  const MovieHomeScreen({super.key, this.mode = AppMode.movies});

  /// True once the home has loaded and its skeleton started fading, for
  /// MovieTabShell's bottom nav bar to make its entrance then. Stays true
  /// for the rest of the session, like the home's cached data.
  static final revealed = ValueNotifier<bool>(false);

  @override
  State<MovieHomeScreen> createState() => _MovieHomeScreenState();
}

class _MovieHomeScreenState extends State<MovieHomeScreen> {
  // The bottom nav bar swaps tabs via pushReplacement (to avoid back-stack
  // buildup), which tears down and recreates this widget on every visit to
  // the Home tab. Caching the loaded data at the class level survives that
  // recreation, so we only hit the network once per app session instead of
  // re-fetching every time.
  // Per mode: Popcorn's and Ramen's homes each load their own.
  static final Map<AppMode, _HomeData> _cache = {};

  AppMode get _mode => widget.mode;
  bool get _isRamen => _mode == AppMode.anime;
  String get _rankLabel =>
      _isRamen ? 'Popular Right Now' : 'Trending This Week';

  final TMDBService _tmdb = TMDBService();
  final ScrollController _scrollController = SmoothScrollController();

  List<Movie> _trendingMovies = [];
  List<Movie> _topRatedMovies = [];
  // Ramen's rows between those two: this season's series, then films.
  List<Movie> _newSeries = [];
  List<Movie> _films = [];
  // The hero slideshow's titles (see HeroCarousel): the top of the
  // trending list, the first's details loaded.
  List<Movie> _heroMovies = [];
  static const _heroCount = 10;

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
    final cached = _cache[_mode];
    if (cached != null) {
      _trendingMovies = cached.trending;
      _topRatedMovies = cached.topRated;
      _newSeries = cached.newSeries;
      _films = cached.films;
      _heroMovies = cached.heroes;
      _loading = false;
      _skeletonDone = true;
      MovieHomeScreen.revealed.value = true;
    } else {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    try {
      final List<Movie> trending;
      final List<Movie> topRated;
      var newSeries = const <Movie>[];
      var films = const <Movie>[];
      if (_isRamen) {
        final lists = await Future.wait([
          _tmdb.popularAnimeSeries(),
          _tmdb.topRatedAnimeSeries(),
          _tmdb.newAnimeSeries(),
          _tmdb.popularAnimeFilms(),
        ]);
        trending = lists[0];
        topRated = lists[1];
        newSeries = lists[2];
        films = lists[3];
      } else {
        // Anime is Ramen's, where there's Ramen.
        trending = (await _tmdb.getTrending())
            .where((m) => AppModeService.belongsIn(_mode, isAnime: m.isAnime))
            .toList();
        // Simulate "Top Rated" for now by fetching action movies or similar
        // Ideally we add a getTopRated() method to TMDBService later
        topRated = trending.reversed.toList();
      }

      // The hero's slideshow: the top ten with a picture to show, from
      // the top. The first's details (its logo, genres, trailer) before
      // the page shows; the rest's load as it runs (see HeroCarousel).
      final heroes = trending
          .where((m) => m.backdrop != null)
          .take(_heroCount)
          .toList();
      if (heroes.isNotEmpty) {
        try {
          final first =
              await _tmdb.getDetails(heroes.first.id, type: heroes.first.type);
          if (first != null) heroes[0] = first;
        } catch (_) {}
      }

      _cache[_mode] = _HomeData(
        trending: trending,
        topRated: topRated,
        newSeries: newSeries,
        films: films,
        heroes: heroes,
      );

      if (!mounted) return;
      // Still behind the skeleton (_loading stays true).
      setState(() {
        _trendingMovies = trending;
        _topRatedMovies = topRated;
        _newSeries = newSeries;
        _films = films;
        _heroMovies = heroes;
      });

      // Keep the skeleton up until the hero's backdrop and logo are
      // decoded, so the page doesn't appear with an empty black hero that
      // its artwork then pops into.
      if (heroes.isNotEmpty) {
        try {
          await _precacheHero(heroes.first).timeout(_maxPreloadWait);
        } catch (_) {
          // Timed out: show the page regardless.
        }
      }
    } catch (e) {
      print('Error loading home data: $e');
    }
    await _reveal();
    // The hero's More Info is the likeliest first tap: have its page ready.
    final first = _heroMovies.firstOrNull;
    if (first != null && mounted) DetailsScreen.prefetch(context, first);
  }

  /// The wide (desktop) home, or the phone's. On a TV, still the wide one
  /// beside the side column (about 760 of its 1280): the phone's took its
  /// place as the column opened, back at its top, the remote's selection
  /// on a poster lost with it.
  static bool _isWide(double width) => width > (TvDevice.isTv ? 600 : 800);

  Future<void> _precacheHero(Movie movie) {
    // Same breakpoint as build(): the desktop hero requests its images at
    // different sizes.
    return _isWide(MediaQuery.sizeOf(context).width)
        ? DesktopHomeScreen.precacheHero(context, movie)
        : MovieHeroBanner.precache(context, movie);
  }

  /// Builds the page under the still-opaque skeleton, gives it a few
  /// frames to settle, then fades the skeleton off it (see
  /// _revealOverSkeleton).
  Future<void> _reveal() async {
    if (!mounted) return;
    setState(() => _loading = false);
    MovieHomeScreen.revealed.value = true;
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _skeletonFading = true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = _isWide(constraints.maxWidth);
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
            // The bottom nav bar is MovieTabShell's, over this.
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
    // Each mode's own: anime in Ramen, the rest in Popcorn.
    final history = hidePlayback
        ? const <Movie>[]
        : SavedMoviesService()
            .history
            .where((m) => AppModeService.belongsIn(_mode, isAnime: m.isAnime))
            .toList();
    // The hero shows More Info + Trailer (no Play button); Trailer only on
    // titles with one.
    void onTrailer(Movie movie) => _openTrailer(movie.trailerUrl!);

    if (_isWide(constraints.maxWidth) && _heroMovies.isNotEmpty) {
      return DesktopHomeScreen(
        heroMovies: _heroMovies,
        trendingMovies: _trendingMovies,
        historyMovies: history,
        topRatedMovies: _topRatedMovies,
        rankLabel: _rankLabel,
        newSeries: _newSeries,
        films: _films,
        topRatedTitle: _isRamen ? 'Top Rated of All Time' : 'Top Rated',
        ramen: _isRamen,
        onTrailerHero: onTrailer,
        onMovieTap: (movie) => _navigateToDetails(
          movie,
          heroTag: 'desktop_trending_${movie.id}',
        ),
        onRemoveHistory: (movie) => _confirmRemoveHistory(movie),
      );
    }

    final scaffold = Scaffold(
      extendBodyBehindAppBar: true,
      // No glass bar or top fade: once scrolled, the logo sits on a
      // frosted island of its own (see CustomAppBar.logoIslandScroll).
      appBar: CustomAppBar(
        forceOpacity: 0,
        showActions: false,
        showModeSwitch: false,
        logoIslandScroll: _scrollController,
        // The island's padding (14) then puts the logo in line with the
        // rows' titles (24 in).
        titleSpacing: 10,
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          children: [
            // Hero Banner
            if (_heroMovies.isNotEmpty)
              MovieHeroBanner(
                scrollController: _scrollController,
                movies: _heroMovies,
                // Where each stands in TMDB's weekly trending list.
                rankOf: (movie) =>
                    _trendingMovies.indexWhere((m) => m.id == movie.id) + 1,
                rankLabel: _rankLabel,
                onTrailer: onTrailer,
                onInfo: (movie) =>
                    _navigateToDetails(movie, heroTag: 'hero_${movie.id}'),
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
              title: _isRamen ? "Popular Right Now" : "Trending This Week",
              movies: _trendingMovies,
              heroPrefix: "trending",
            ),

            const SizedBox(height: 24),

            if (_newSeries.isNotEmpty) ...[
              _buildSection(
                title: "New This Season",
                movies: _newSeries,
                heroPrefix: "new",
              ),
              const SizedBox(height: 24),
            ],

            if (_films.isNotEmpty) ...[
              _buildSection(
                title: "Anime Movies",
                movies: _films,
                heroPrefix: "films",
              ),
              const SizedBox(height: 24),
            ],

            // Top Rated Section
            _buildSection(
              title: _isRamen ? "Top Rated of All Time" : "Top Rated",
              movies: _topRatedMovies,
              heroPrefix: "top",
            ),

            SizedBox(height: 110 + MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
    );

    // FloatingBottomNavBar is added over this (and the skeleton) in build.
    return scaffold;
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
    final confirmed = await showGlassConfirm(
      context,
      title: 'Remove from Continue Watching?',
      message: '"${movie.title}" and your progress in it will be removed.',
      confirmLabel: 'Remove',
      destructive: true,
    );

    if (confirmed) {
      // removeFromHistory() calls notifyListeners() itself — the
      // ListenableBuilder(SavedMoviesService()) around _buildContent picks
      // it up without a manual setState here.
      await SavedMoviesService().removeFromHistory(movie.id, type: movie.type);
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
                type: movie.type,
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
                // Continue Watching: straight back into it.
                onPlay: heroPrefix == 'history'
                    ? () => quickPlay(context, movieDisplay)
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One mode's loaded home, kept for the session (see _cache).
class _HomeData {
  final List<Movie> trending;
  final List<Movie> topRated;
  final List<Movie> newSeries;
  final List<Movie> films;
  final List<Movie> heroes;

  const _HomeData({
    required this.trending,
    required this.topRated,
    required this.newSeries,
    required this.films,
    required this.heroes,
  });
}
