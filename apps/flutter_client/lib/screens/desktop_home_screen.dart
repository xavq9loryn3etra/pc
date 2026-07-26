import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../models/movie.dart';
import '../widgets/movie_poster.dart';
import '../widgets/desktop_details_panel.dart';
import 'search_screen.dart';
import 'favorites_screen.dart';

class DesktopHomeScreen extends StatefulWidget {
  final Movie featuredMovie;
  final List<Movie> trendingMovies;
  final List<Movie> historyMovies;
  final List<Movie> topRatedMovies;
  final VoidCallback onPlayHero;
  final VoidCallback onInfoHero;
  final Function(Movie) onMovieTap;
  final Function(Movie)? onRemoveHistory;

  const DesktopHomeScreen({
    super.key,
    required this.featuredMovie,
    required this.trendingMovies,
    required this.historyMovies,
    required this.topRatedMovies,
    required this.onPlayHero,
    required this.onInfoHero,
    required this.onMovieTap,
    this.onRemoveHistory,
  });

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  // State for Side Panel
  Movie? _selectedMovie;

  // Scroll tracking for top bar glass effect
  final ScrollController _scrollController = ScrollController();
  double _topBarOpacity = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    double newOpacity = (offset / 50).clamp(0.0, 1.0);
    if (newOpacity != _topBarOpacity) {
      setState(() => _topBarOpacity = newOpacity);
    }
  }

  void _onMovieSelect(Movie movie) {
    setState(() {
      _selectedMovie = movie;
    });
  }

  void _closeSidePanel() {
    setState(() {
      _selectedMovie = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.of(context).size.height;
    final double heroHeight = screenHeight * 0.95; // 95vh

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              physics: const BouncingScrollPhysics(),
            ),
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Column(
                children: [
                  // -----------------------------
                  // 1. Hero Section (95vh)
                  // -----------------------------
                  SizedBox(
                    height: heroHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Background
                        _buildBackground(context),
                        // Gradients
                        _buildGradients(),
                        // Hero Content (Positioned from bottom to avoid overlap)
                        // The overlapping lists start at heroHeight - 150.
                        // We position this content to end at bottom: 180 (150 + 30px padding)
                        Positioned(
                          left: 60,
                          bottom: 180,
                          child: SizedBox(
                            width: MediaQuery.of(context).size.width * 0.4,
                            child: _buildHeroContent(context),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // -----------------------------
                  // 2. Lists Section (Overlapping)
                  // -----------------------------
                  Transform.translate(
                    offset: const Offset(0, -150),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 60),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Trending List
                          _buildSectionList(
                            context,
                            title: "Trending This Week",
                            movies: widget.trendingMovies,
                            heroPrefix: "desktop_trending",
                            posterHeight: 300,
                            posterWidth: 200,
                            onTap: _onMovieSelect,
                          ),
                          const SizedBox(height: 40),

                          if (widget.historyMovies.isNotEmpty) ...[
                            _buildSectionList(
                              context,
                              title: "Continue Watching",
                              movies: widget.historyMovies,
                              heroPrefix: "desktop_history",
                              onLongPress: widget.onRemoveHistory,
                              posterHeight: 300,
                              posterWidth: 200,
                              onTap: _onMovieSelect,
                            ),
                            const SizedBox(height: 40),
                          ],

                          _buildSectionList(
                            context,
                            title: "Top Rated",
                            movies: widget.topRatedMovies,
                            heroPrefix: "desktop_top_rated",
                            posterHeight: 300,
                            posterWidth: 200,
                            onTap: _onMovieSelect,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // -----------------------------
          // 3. Top Bar (Fixed)
          // -----------------------------
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar(context)),

          // -----------------------------
          // 4. Side Panel Overlay
          // -----------------------------
          if (_selectedMovie != null)
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
                    child:
                        DesktopDetailsPanel(
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
      ),
    );
  }

  Widget _buildBackground(BuildContext context) {
    // accesses widget.featuredMovie
    final image =
        widget.featuredMovie.backdrop ?? widget.featuredMovie.posterUrl;
    if (image == null) return const SizedBox.shrink();

    return CachedNetworkImage(
      imageUrl: image,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(color: Colors.black),
      errorWidget: (context, url, error) => Container(color: Colors.black),
    ).animate().fadeIn(duration: 800.ms);
  }

  Widget _buildGradients() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Top-down gradient
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 200,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.black54, Colors.transparent],
                stops: [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),
        // Bottom-up gradient
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black45,
                Colors.black87,
                Colors.black,
              ],
              stops: [0.0, 0.5, 0.8, 1.0],
            ),
          ),
        ),
        // Left-to-right gradient
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Colors.black87, Colors.black54, Colors.transparent],
                stops: [0.0, 0.3, 0.8],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 15 * _topBarOpacity,
          sigmaY: 15 * _topBarOpacity,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 24),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(_topBarOpacity * 0.7),
          ),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/logo.svg',
                height: 32,
                colorFilter: const ColorFilter.mode(
                  AppTheme.primaryColor,
                  BlendMode.srcIn,
                ),
              ),
              const Spacer(),
              // Search Icon
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SearchScreen(),
                      ),
                    );
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.search,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const FavoritesScreen(),
                      ),
                    );
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.favorite_border,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuLink(BuildContext context, String title, bool isActive) {
    return Text(
      title,
      style: TextStyle(
        color: isActive ? Colors.white : Colors.white60,
        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
        fontSize: 14,
      ),
    );
  }

  Widget _buildHeroContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.featuredMovie.logoUrl != null)
          CachedNetworkImage(
            imageUrl: widget.featuredMovie.logoUrl!,
            height: 150,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            placeholder: (context, url) => const SizedBox(height: 150),
            errorWidget: (context, url, err) => _buildHeroTitle(),
          ).animate().fadeIn().slideX()
        else
          _buildHeroTitle().animate().fadeIn().slideX(),
        const SizedBox(height: 16),
        // Year and Rating
        Text(
          '${widget.featuredMovie.year} • ${widget.featuredMovie.certification ?? "PG-13"}',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            shadows: [
              Shadow(
                color: Colors.black45,
                offset: Offset(0, 2),
                blurRadius: 4,
              ),
            ],
          ),
        ).animate().fadeIn(delay: 200.ms),
        const SizedBox(height: 16),
        SizedBox(
          width: 600,
          child: Text(
            widget.featuredMovie.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              height: 1.5,
            ),
          ),
        ).animate().fadeIn(delay: 200.ms),
        const SizedBox(height: 32),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Play Button
            ElevatedButton.icon(
              onPressed: widget.onPlayHero,
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.black,
                size: 28,
              ),
              label: const Text("Play"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 20,
                ),
                fixedSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 16),
            // Info Button
            ElevatedButton.icon(
              onPressed: () => _onMovieSelect(widget.featuredMovie),
              icon: const Icon(Icons.info_outline, color: Colors.white),
              label: const Text("More Info"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromRGBO(109, 109, 109, 0.7),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32, // Match Play button
                  vertical: 20,
                ),
                fixedSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ).animate().fadeIn(delay: 400.ms),
      ],
    );
  }

  Widget _buildHeroTitle() {
    return Text(
      widget.featuredMovie.title.toUpperCase(),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 64,
        fontWeight: FontWeight.w900,
        height: 0.9,
      ),
    );
  }

  Widget _buildSectionList(
    BuildContext context, {
    required String title,
    required List<Movie> movies,
    required String heroPrefix,
    Function(Movie)? onLongPress,
    Function(Movie)? onTap,
    double posterHeight = 220,
    double posterWidth = 145,
  }) {
    return _DesktopSectionList(
      title: title,
      movies: movies,
      heroPrefix: heroPrefix,
      onLongPress: onLongPress,
      onTap: onTap != null ? onTap : (movie) => widget.onMovieTap(movie),
      posterHeight: posterHeight,
      posterWidth: posterWidth,
    );
  }
}

class _DesktopSectionList extends StatefulWidget {
  final String title;
  final List<Movie> movies;
  final String heroPrefix;
  final Function(Movie)? onLongPress;
  final Function(Movie) onTap;
  final double posterHeight;
  final double posterWidth;

  const _DesktopSectionList({
    super.key,
    required this.title,
    required this.movies,
    required this.heroPrefix,
    this.onLongPress,
    required this.onTap,
    required this.posterHeight,
    required this.posterWidth,
  });

  @override
  State<_DesktopSectionList> createState() => _DesktopSectionListState();
}

class _DesktopSectionListState extends State<_DesktopSectionList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ).animate().fadeIn(delay: 600.ms),
        const SizedBox(height: 32),
        SizedBox(
          height: widget.posterHeight + 60,
          child: Stack(
            children: [
              RawScrollbar(
                controller: _scrollController,
                thumbColor: Colors.grey[800],
                radius: const Radius.circular(6),
                thickness: 12, // Increased thickness
                thumbVisibility: true,
                trackVisibility: true,
                trackColor: Colors.black45,
                trackBorderColor: Colors.transparent,
                padding: const EdgeInsets.only(left: 0, right: 0, bottom: 0),
                child: ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  itemCount: widget.movies.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 16),
                  itemBuilder: (context, index) {
                    final movie = widget.movies[index];
                    return MoviePoster(
                      movie: movie,
                      showTitle: true,
                      heroTag: '${widget.heroPrefix}_${movie.id}',
                      onTap: () => widget.onTap(movie),
                      onLongPress: widget.onLongPress != null
                          ? () => widget.onLongPress!(movie)
                          : null,
                      width: widget.posterWidth,
                      height: widget.posterHeight,
                    );
                  },
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 14,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  hitTestBehavior: HitTestBehavior.translucent,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
