import 'dart:ui';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import 'details_screen.dart';
import '../widgets/hero_banner.dart';
import '../widgets/movie_poster.dart';
import '../services/saved_movies_service.dart';
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

      if (mounted) {
        setState(() {
          _trendingMovies = trending;
          _topRatedMovies = topRated;
          if (resolvedFeatured != null) {
            _featuredMovie = resolvedFeatured;
          }
          _loading = false;
        });
      }
    } catch (e) {
      print('Error loading home data: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 800) {
            return const Scaffold(body: DesktopSkeletonHome());
          }
          // FloatingBottomNavBar is deliberately absent here (unlike the
          // loaded Stack below) — it plays a staggered pop-in entrance the
          // first time it's actually built, so it should only get built
          // once the shimmer is done, not sit there statically the whole
          // time it's loading.
          return const Scaffold(body: SkeletonHome());
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Scoped to SavedMoviesService so Continue Watching (and the
        // desktop panel's historyMovies prop) only refresh when history
        // actually changes, instead of after every single navigation
        // return regardless of whether anything changed.
        return ListenableBuilder(
          listenable: SavedMoviesService(),
          builder: (context, _) => _buildContent(context, constraints),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, BoxConstraints constraints) {
    if (constraints.maxWidth > 800 && _featuredMovie != null) {
      return DesktopHomeScreen(
        featuredMovie: _featuredMovie!,
        trendingMovies: _trendingMovies,
        historyMovies: SavedMoviesService().history,
        topRatedMovies: _topRatedMovies,
        onPlayHero: () {
          SavedMoviesService().addToHistory(_featuredMovie!);
          _navigateToDetails(
            _featuredMovie!,
            heroTag: 'hero_${_featuredMovie!.id}',
          );
        },
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
      // Scoped to the scroll controller so the AppBar's scroll-fade rebuilds
      // on its own — the rest of the screen (hero banner, carousels) no
      // longer rebuilds on every scroll frame just to update this fade.
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ListenableBuilder(
          listenable: _scrollController,
          builder: (context, _) => CustomAppBar(
            scrollOffset: _scrollController.hasClients
                ? _scrollController.offset
                : 0.0,
            showActions: false,
            showModeSwitch: false,
          ),
        ),
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          children: [
            // Hero Banner
            if (_featuredMovie != null)
              MovieHeroBanner(
                scrollController: _scrollController,
                movie: _featuredMovie!,
                onPlay: () {
                  SavedMoviesService().addToHistory(_featuredMovie!);
                  _navigateToDetails(
                    _featuredMovie!,
                    heroTag: 'hero_${_featuredMovie!.id}',
                  );
                },
                onInfo: () => _navigateToDetails(
                  _featuredMovie!,
                  heroTag: 'hero_${_featuredMovie!.id}',
                ),
              ),

            const SizedBox(height: 20),

            // Continue Watching (History)
            if (SavedMoviesService().history.isNotEmpty)
              _buildSection(
                title: "Continue Watching",
                movies: SavedMoviesService().history,
                heroPrefix: "history",
              ),

            if (SavedMoviesService().history.isNotEmpty)
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
      ),
    );

    return Stack(
      children: [
        scaffold,
        const FloatingBottomNavBar(activeTab: BottomNavTab.home),
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
