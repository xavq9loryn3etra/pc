import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import 'details_screen.dart';
import '../widgets/hero_banner.dart';
import '../widgets/movie_poster.dart';
import '../services/saved_movies_service.dart';
import '../widgets/skeletons.dart';
import 'search_screen.dart';
import 'desktop_home_screen.dart';
import 'favorites_screen.dart';
import '../widgets/desktop_skeletons.dart';
import '../widgets/custom_app_bar.dart';

class MovieHomeScreen extends StatefulWidget {
  const MovieHomeScreen({super.key});

  @override
  State<MovieHomeScreen> createState() => _MovieHomeScreenState();
}

class _MovieHomeScreenState extends State<MovieHomeScreen> {
  final TMDBService _tmdb = TMDBService();
  final ScrollController _scrollController = ScrollController();

  List<Movie> _trendingMovies = [];
  List<Movie> _topRatedMovies = [];
  Movie? _featuredMovie;

  double _opacity = 0.0;
  bool _loading = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadData();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    double newOpacity = (offset / 200).clamp(0.0, 1.0);
    // print("HomeScroll: offset=\${offset.toStringAsFixed(1)} opacity=\${newOpacity.toStringAsFixed(2)}");
    if (newOpacity != _opacity) {
      setState(() => _opacity = newOpacity);
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
          final basic = trending.first;
          featured = await _tmdb.getDetails(basic.id, type: basic.type);
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _trendingMovies = trending;
          _topRatedMovies = topRated;
          if (trending.isNotEmpty) {
            _featuredMovie = featured ?? trending.first;
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
          return const Scaffold(body: SkeletonHome());
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
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

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: CustomAppBar(
            scrollOffset:
                _scrollController.hasClients ? _scrollController.offset : 0.0,
            onSearchTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchScreen()),
              );
            },
            onFavoritesTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FavoritesScreen()),
              );
            },
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

                // Trending Section
                _buildSection(
                  title: "Trending This Week",
                  movies: _trendingMovies,
                  heroPrefix: "trending",
                ),

                const SizedBox(height: 24),

                // Continue Watching (History)
                if (SavedMoviesService().history.isNotEmpty)
                  _buildSection(
                    title: "Continue Watching",
                    movies: SavedMoviesService().history,
                    heroPrefix: "history",
                  ),

                if (SavedMoviesService().history.isNotEmpty)
                  const SizedBox(height: 24),

                // Top Rated Section
                _buildSection(
                  title: "Top Rated",
                  movies: _topRatedMovies,
                  heroPrefix: "top",
                ),

                SizedBox(height: 24 + MediaQuery.of(context).padding.bottom),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _navigateToDetails(Movie movie, {String? heroTag}) async {
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => DetailsScreen(movie: movie, heroTag: heroTag),
      ),
    );
    if (mounted) setState(() {});
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
      await SavedMoviesService().removeFromHistory(movie.id);
      if (mounted) {
        setState(() {}); // Refresh logic will pick up the change
      }
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
