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
  // Scroll-driven app-bar fade. A ValueNotifier instead of a setState field
  // — ScreenScaffold scopes it to just the AppBar via ValueListenableBuilder,
  // so scrolling doesn't force this screen's build() (and the poster grid's
  // itemBuilder for every visible cell) to re-run on every scroll tick.
  final ValueNotifier<double> _opacityNotifier = ValueNotifier(0.0);
  Movie? _selectedMovie;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFavorites();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final newOpacity = (offset / 50).clamp(0.0, 1.0);
    if (newOpacity != _opacityNotifier.value) {
      _opacityNotifier.value = newOpacity;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _opacityNotifier.dispose();
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
      opacityListenable: _opacityNotifier,
      selectedMovie: _selectedMovie,
      onCloseSidePanel: _closeSidePanel,
    );
  }
}
