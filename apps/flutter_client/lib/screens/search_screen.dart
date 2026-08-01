import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';

import 'details_screen.dart';
import '../widgets/movie_poster.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/shimmer_loader.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../services/movie_tab_service.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  final TMDBService _tmdb = TMDBService();

  List<Movie> _results = [];
  bool _isLoading = false;
  // Scroll-driven app-bar fade. A ValueNotifier instead of a setState field
  // — ScreenScaffold scopes it to just the AppBar via ValueListenableBuilder,
  // so scrolling doesn't force this screen's build() (and the poster grid's
  // itemBuilder for every visible cell) to re-run on every scroll tick.
  final ValueNotifier<double> _opacityNotifier = ValueNotifier(0.0);
  Timer? _debounce;
  String? _error;
  Movie? _selectedMovie;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // SearchScreen stays mounted (offscreen) for the whole movies-mode
    // session as one of MovieTabShell's tabs, so `autofocus` would pop the
    // keyboard the instant the app opens rather than when this tab is
    // actually shown. Focus only on the transitions that matter: opening
    // the keyboard when the user switches to Search, dismissing it when
    // they switch away.
    MovieTabService().currentTab.addListener(_onActiveTabChanged);
  }

  void _onActiveTabChanged() {
    if (MovieTabService().currentTab.value == BottomNavTab.search) {
      _searchFocusNode.requestFocus();
    } else {
      _searchFocusNode.unfocus();
    }
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
    MovieTabService().currentTab.removeListener(_onActiveTabChanged);
    _debounce?.cancel();
    _controller.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    _opacityNotifier.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce?.cancel();

    // Clear results if empty
    if (query.isEmpty) {
      _searchRequestId++; // invalidate any in-flight request
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }

    // Debounce API calls (500ms)
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    final requestId = ++_searchRequestId;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await _tmdb.searchMulti(query);
      // Response times vary enough that an older query's request can
      // resolve after a newer one already has — only apply this response
      // if nothing newer has been fired since, otherwise it'd silently
      // clobber the correct, more recent results.
      if (mounted && requestId == _searchRequestId) {
        setState(() {
          _results = results;
          _isLoading = false;
          if (results.isEmpty) _error = "No results found.";
        });
      }
    } catch (e) {
      if (mounted && requestId == _searchRequestId) {
        setState(() {
          _isLoading = false;
          _error = "Search failed. Please check your connection.";
        });
      }
    }
  }

  void _closeSidePanel() {
    setState(() {
      _selectedMovie = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      bottomNavTab: BottomNavTab.search,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        // Search is a bottom-nav tab, not a pushed route, so there's no
        // route to pop — "back" here means returning to the Home tab,
        // same as tapping the Home icon in FloatingBottomNavBar.
        onPressed: () =>
            MovieTabService().currentTab.value = BottomNavTab.home,
      ),
      title: TextField(
        controller: _controller,
        focusNode: _searchFocusNode,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        decoration: const InputDecoration(
          hintText: 'Search movies & TV shows...',
          hintStyle: TextStyle(color: Colors.white54),
          border: InputBorder.none,
        ),
        onChanged: _onSearchChanged,
      ),
      actions: [
        if (_controller.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear, color: Colors.white54),
            onPressed: () {
              _controller.clear();
              _onSearchChanged('');
            },
          ),
      ],
      body: _buildBody,
      opacityListenable: _opacityNotifier,
      selectedMovie: _selectedMovie,
      onCloseSidePanel: _closeSidePanel,
    );
  }

  Widget _buildBody(BuildContext context, bool isDesktop, EdgeInsets padding) {
    if (_isLoading) {
      return const Center(
        child: ShimmerLoader(),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_results.isEmpty && _controller.text.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.white12),
            SizedBox(height: 16),
            Text(
              'Find your next favorite.',
              style: TextStyle(color: Colors.white24),
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
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final movie = _results[index];
        return MoviePoster(
          movie: movie,
          width: double.infinity,
          height: double.infinity,
          showTitle: true,
          onTap: () {
            if (isDesktop) {
              setState(() {
                _selectedMovie = movie;
              });
            } else {
              Navigator.push(
                context,
                CupertinoPageRoute(
                  builder: (context) => DetailsScreen(movie: movie),
                ),
              );
            }
          },
        );
      },
    );
  }
}
