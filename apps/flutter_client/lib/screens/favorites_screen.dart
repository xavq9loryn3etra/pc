import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/saved_movies_service.dart';
import '../widgets/movie_poster.dart';
import 'details_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_details_panel.dart';
import 'package:flutter_animate/flutter_animate.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Movie> _favorites = [];
  final ScrollController _scrollController = ScrollController();
  double _opacity = 0.0;
  Movie? _selectedMovie;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFavorites();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    double newOpacity = (offset / 50).clamp(0.0, 1.0);
    if (newOpacity != _opacity) {
      setState(() => _opacity = newOpacity);
    }
  }

  @override
  void dispose() {
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth > 800;
        final horizontalPadding = isDesktop ? 60.0 : 16.0;

        return Stack(
          children: [
            Scaffold(
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                title: const Text('My List'),
                backgroundColor: Colors.transparent,
                flexibleSpace: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 15 * _opacity,
                      sigmaY: 15 * _opacity,
                    ),
                    child: Container(
                      color: Colors.black.withOpacity(_opacity * 0.7),
                    ),
                  ),
                ),
              ),
              body: _favorites.isEmpty
                  ? Center(
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
                    )
                  : GridView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        100,
                        horizontalPadding,
                        16,
                      ),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: isDesktop ? 200 : 150,
                        childAspectRatio: isDesktop ? (200 / 340) : 0.6,
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
                    ),
            ),

            // Side panel overlay for desktop
            if (isDesktop && _selectedMovie != null)
              Positioned.fill(
                child: Stack(
                  children: [
                    // Darkened background overlay
                    GestureDetector(
                      onTap: _closeSidePanel,
                      child: Container(color: Colors.black.withOpacity(0.6)),
                    ).animate().fadeIn(duration: 200.ms),

                    // Side panel
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      child: DesktopDetailsPanel(
                        movie: _selectedMovie!,
                        onClose: _closeSidePanel,
                      )
                          .animate()
                          .slideX(
                            begin: 1.0,
                            end: 0.0,
                            duration: 300.ms,
                            curve: Curves.easeOutCubic,
                          )
                          .fadeIn(duration: 200.ms),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
