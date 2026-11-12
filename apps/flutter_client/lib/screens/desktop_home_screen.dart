import 'package:flutter/material.dart';
import '../widgets/glass_blur.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../models/movie.dart';
import '../widgets/movie_poster.dart';
import '../widgets/desktop_details_panel.dart';
import 'details_screen.dart';
import '../widgets/image_precache.dart';
import '../services/saved_movies_service.dart';
import '../services/movie_tab_service.dart';
import '../widgets/artwork_glow.dart';

class DesktopHomeScreen extends StatefulWidget {
  final Movie featuredMovie;
  final List<Movie> trendingMovies;
  final List<Movie> historyMovies;
  final List<Movie> topRatedMovies;
  /// Null hides the hero's Trailer button (no trailer for this title).
  final VoidCallback? onTrailerHero;
  final VoidCallback onInfoHero;
  final Function(Movie) onMovieTap;
  final Function(Movie)? onRemoveHistory;

  /// Where [featuredMovie] stands in TMDB's weekly trending list (1 = top),
  /// for the "#3 Trending This Week" line; 0 or less hides it.
  final int trendingRank;

  const DesktopHomeScreen({
    super.key,
    required this.featuredMovie,
    required this.trendingMovies,
    required this.historyMovies,
    required this.topRatedMovies,
    this.onTrailerHero,
    required this.onInfoHero,
    required this.onMovieTap,
    this.onRemoveHistory,
    this.trendingRank = 0,
  });

  // The hero's images and decode sizes, shared by the state's build and
  // precacheHero() so the preload warms exactly what the hero requests.
  static String? _heroBackdropUrlFor(Movie m) =>
      m.backdropHighRes ?? m.backdrop ?? m.posterUrl;
  static String? _heroLogoUrlFor(Movie m) =>
      m.logoUrl == null ? null : (m.logoHighRes ?? m.logoUrl!);
  static const double _heroLogoHeight = 150;
  // Cap the backdrop's decode to the screen width — it fills the whole
  // background, so it'd otherwise decode at the source's native resolution
  // regardless of how big the window actually is.
  static int _heroBackdropCacheWidth(BuildContext context) =>
      (MediaQuery.of(context).size.width *
              MediaQuery.of(context).devicePixelRatio)
          .toInt();

  /// Downloads and decodes [movie]'s hero backdrop and logo as the hero
  /// will request them, so they paint on its first frame.
  static Future<void> precacheHero(BuildContext context, Movie movie) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Future.wait([
      precacheNetworkImage(context, _heroBackdropUrlFor(movie),
          cacheWidth: _heroBackdropCacheWidth(context)),
      ArtworkGlow.precache(context, _heroBackdropUrlFor(movie) ?? ''),
      precacheNetworkImage(context, _heroLogoUrlFor(movie),
          cacheHeight: (_heroLogoHeight * dpr).toInt()),
    ]);
  }

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  // State for Side Panel
  Movie? _selectedMovie;

  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    if (_selectedMovie != null) MovieTabService().panelsOpen.value--;
    _scrollController.dispose();
    super.dispose();
  }

  void _onMovieSelect(Movie movie) {
    // In the side column beside the home, as on a phone (see
    // MovieTabShell); this side panel only where there's no column.
    if (MovieTabService().openInColumn(DetailsScreen(movie: movie))) return;
    if (_selectedMovie == null) MovieTabService().panelsOpen.value++;
    setState(() {
      _selectedMovie = movie;
    });
  }

  void _closeSidePanel() {
    if (_selectedMovie != null) MovieTabService().panelsOpen.value--;
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
              child: Stack(
                children: [
                  // -----------------------------
                  // 1. Hero Section (95vh)
                  // -----------------------------
                  SizedBox(
                    height: heroHeight,
                    width: double.infinity,
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Background (parallax)
                          _buildBackground(context),
                          // Gradients (stationary with the hero section so the
                          // fade to black stays anchored above the poster rows)
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
                  ),

                  // -----------------------------
                  // 2. Lists Section (Overlapping)
                  // -----------------------------
                  // Positioned via top padding inside a Stack rather than
                  // Transform.translate(offset: Offset(0, -150)) on a Column,
                  // which shifted the paint layer up by 150px while leaving
                  // 150px of dead layout space at the bottom of the scroll view.
                  Padding(
                    padding: EdgeInsets.only(
                      top: heroHeight - 150,
                      left: 60,
                      bottom: 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
      ),
    );
  }

  Widget _buildBackground(BuildContext context) {
    // accesses widget.featuredMovie
    // The desktop hero can render wider than TMDB's w1280 backdrop tier on
    // any 1080p+ display, so this one uses the full-resolution `original`
    // source instead of the standard `backdrop` field everything else uses.
    final image =
        DesktopHomeScreen._heroBackdropUrlFor(widget.featuredMovie);
    if (image == null) return const SizedBox.shrink();

    // As the phone hero (MovieHeroBanner) and the details page: the
    // picture melting into a soft wash of its own colours — and, as there,
    // moving at half the page's speed as it scrolls (parallax). The
    // subtree is built once (`child`) behind a RepaintBoundary, so
    // scrolling just moves its layer.
    final background = RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ArtworkGlow(url: image),
          ),
          FadingCoverImage(
            url: image,
            cacheWidth: DesktopHomeScreen._heroBackdropCacheWidth(context),
            alignment: Alignment.topCenter,
          ),
        ],
      ),
    );
    return ListenableBuilder(
      listenable: _scrollController,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          0,
          _scrollController.hasClients ? _scrollController.offset * 0.5 : 0,
        ),
        child: child,
      ),
      child: background,
    ).animate().fadeIn(duration: 800.ms);
  }

  Widget _buildGradients() {
    // Both gradients stay anchored to the hero's bounds while the image
    // layer beneath them moves with parallax, so the fade to black never
    // slides down behind the poster rows below.
    return const Stack(
      fit: StackFit.expand,
      children: [
        // Lighter from the left, behind the text there (it's centred on
        // the phone, so needs none).
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0x8A000000), Color(0x42000000), Colors.transparent],
              stops: [0.0, 0.35, 0.7],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.transparent,
                Color(0x73000000), // 45%
                Color(0xA6000000), // 65%
                Colors.black,
                Colors.black,
              ],
              stops: [0, 0.35, 0.62, 0.82, 0.97, 1],
            ),
          ),
        ),
      ],
    );
  }

  // Just the logo over the page: no bar or fade behind it.
  Widget _buildTopBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 24),
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
          // The tab buttons sit at the right of this row (see
          // FloatingBottomNavBar), over it.
        ],
      ),
    );
  }

  Widget _buildLogo(BuildContext context) {
    final url = DesktopHomeScreen._heroLogoUrlFor(widget.featuredMovie)!;
    const height = DesktopHomeScreen._heroLogoHeight;

    return CachedNetworkImage(
      imageUrl: url,
      height: height,
      memCacheHeight:
          (height * MediaQuery.of(context).devicePixelRatio).toInt(),
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      placeholder: (context, url) => const SizedBox(height: height),
      errorWidget: (context, url, err) => _buildHeroTitle(),
    );
  }

  Widget _buildHeroContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.featuredMovie.logoUrl != null)
          _buildLogo(context).animate().fadeIn().slideX()
        else
          _buildHeroTitle().animate().fadeIn().slideX(),
        const SizedBox(height: 16),
        // Year, what it is (as the phone hero's line) and rating
        Text(
          [
            '${widget.featuredMovie.year}',
            widget.featuredMovie.type == 'tv' ? 'TV Show' : 'Movie',
            ...?widget.featuredMovie.genres?.take(2),
            if (widget.featuredMovie.certification?.isNotEmpty ?? false)
              widget.featuredMovie.certification!,
          ].join(' • '),
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
        if (widget.trendingRank > 0) ...[
          const SizedBox(height: 6),
          Text(
            '#${widget.trendingRank} Trending This Week',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              shadows: [
                Shadow(
                  color: Colors.black45,
                  offset: Offset(0, 2),
                  blurRadius: 4,
                ),
              ],
            ),
          ).animate().fadeIn(delay: 250.ms),
        ],
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
            // The phone hero's buttons (MovieHeroBanner): a white More Info
            // pill — here opening the side details panel — then the round
            // frosted Trailer and Like.
            ElevatedButton.icon(
              onPressed: () => _onMovieSelect(widget.featuredMovie),
              icon: const Icon(
                Icons.info_outline_rounded,
                color: Colors.black,
                size: 26,
              ),
              label: const Text('More Info'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 32),
                fixedSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (widget.onTrailerHero != null) ...[
              const SizedBox(width: 12),
              GlassActionButton(
                onTap: widget.onTrailerHero!,
                child: const _HeroButtonLabel(
                  icon: Icon(Icons.movie_creation_rounded, color: Colors.white),
                  label: 'Trailer',
                ),
              ),
            ],
            const SizedBox(width: 12),
            ListenableBuilder(
              listenable: SavedMoviesService(),
              builder: (context, _) {
                final liked =
                    SavedMoviesService().isFavorite(
                          widget.featuredMovie.id,
                          type: widget.featuredMovie.type,
                        );
                return GlassActionButton(
                  onTap: () =>
                      SavedMoviesService().toggleFavorite(widget.featuredMovie),
                  child: _HeroButtonLabel(
                    icon: Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: liked ? AppTheme.primaryColor : Colors.white,
                    ),
                    label: 'My List',
                  ),
                );
              },
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

/// A hero button's icon and name: the phone hero's round Trailer and Like
/// buttons are icon-only for room, but here there's room for the name.
class _HeroButtonLabel extends StatelessWidget {
  final Widget icon;
  final String label;

  const _HeroButtonLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
