import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/app_mode_service.dart';
import '../services/saved_movies_service.dart';
import '../widgets/movie_poster.dart';
import 'details_screen.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/screen_shade.dart';
import '../widgets/empty_state.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/smooth_scroll_controller.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Movie> _favorites = [];
  final ScrollController _scrollController = SmoothScrollController();
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
    final latest = _mine();
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

  /// The favourites that are this mode's: anime in Ramen, the rest in
  /// Popcorn (see AppModeService.belongsIn).
  static List<Movie> _mine() => [
        for (final m in SavedMoviesService().favorites)
          if (AppModeService().shows(isAnime: m.isAnime)) m,
      ];

  void _loadFavorites() {
    setState(() {
      _favorites = _mine();
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
      glow: TabGlow.myList,
      title: const Text('My List'),
      body: (context, isDesktop, padding) {
        if (_favorites.isEmpty) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              SideColumnScope.inColumn(context)
                  ? 12
                  : ScreenScaffold.contentTop(context),
              24,
              padding.bottom,
            ),
            child: const EmptyState(
              title: 'Nothing saved yet',
              message: 'Tap the heart on any movie or series to keep it '
                  'here for later.',
            ),
          );
        }

        // A phone's margins in a wide window's side column too, as Ask's.
        final horizontalPadding = isDesktop ? 60.0 : 16.0;
        return GridView.builder(
          controller: _scrollController,
          padding: padding.copyWith(
            left: horizontalPadding,
            right: horizontalPadding,
            // In a wide window's side column, just clear of its rounded
            // top corners, which clipped the first posters.
            top: SideColumnScope.inColumn(context)
                ? 12
                : ScreenScaffold.contentTop(context),
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
