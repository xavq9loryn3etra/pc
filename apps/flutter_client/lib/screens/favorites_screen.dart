import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../widgets/movie_poster.dart';
import 'details_screen.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/floating_bottom_nav_bar.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Movie> _favorites = [];
  final ScrollController _scrollController = ScrollController();
  Movie? _selectedMovie;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    // This screen stays mounted as a MovieTabShell tab, so a one-off read
    // went stale: titles liked from Home/Search/Details never showed up
    // until it happened to reload. Follow the service's changes instead.
    SavedMoviesService().addListener(_onSavedMoviesChanged);
  }

  void _onSavedMoviesChanged() {
    // The service also notifies for watch-history updates; only rebuild
    // when the favorites themselves changed.
    final latest = SavedMoviesService().favorites;
    final changed = latest.length != _favorites.length ||
        Iterable.generate(latest.length)
            .any((i) => latest[i].id != _favorites[i].id);
    if (changed && mounted) _loadFavorites();
  }

  @override
  void dispose() {
    SavedMoviesService().removeListener(_onSavedMoviesChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _loadFavorites() {
    setState(() {
      _favorites = SavedMoviesService().favorites;
    });
  }

  void _navigateToDetails(Movie movie, bool isDesktop) async {
    if (isDesktop) {
      // Open side panel on desktop
      setState(() {
        _selectedMovie = movie;
      });
    } else {
      // Navigate to full screen on mobile
      await Navigator.push(
        context,
        CupertinoPageRoute(builder: (_) => DetailsScreen(movie: movie)),
      );
      // Refresh list on return (in case item was removed)
      _loadFavorites();
    }
  }

  void _closeSidePanel() {
    setState(() {
      _selectedMovie = null;
    });
    _loadFavorites(); // Refresh in case item was removed
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      bottomNavTab: BottomNavTab.favorites,
      title: const Text('My List'),
      body: (context, isDesktop, padding) {
        if (_favorites.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border,
                  size: 64,
                  color: Colors.white24,
                ),
                const SizedBox(height: 16),
                const Text(
                  "No favorites yet",
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }

        final horizontalPadding = isDesktop ? 60.0 : 16.0;
        return GridView.builder(
          controller: _scrollController,
          padding: padding.copyWith(
            left: horizontalPadding,
            right: horizontalPadding,
            top: 100,
          ),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: isDesktop ? 200 : 150,
            childAspectRatio: isDesktop ? (200 / 340) : 0.58,
            crossAxisSpacing: isDesktop ? 16 : 12,
            mainAxisSpacing: isDesktop ? 16 : 12,
          ),
          itemCount: _favorites.length,
          itemBuilder: (context, index) {
            final movie = _favorites[index];
            return MoviePoster(
              movie: movie,
              showTitle: true,
              height: double.infinity,
              width: double.infinity,
              onTap: () => _navigateToDetails(movie, isDesktop),
            );
          },
        );
      },
      selectedMovie: _selectedMovie,
      onCloseSidePanel: _closeSidePanel,
    );
  }
}
