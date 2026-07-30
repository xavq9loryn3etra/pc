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
  double _opacity = 0.0;
  Timer? _debounce;
  String? _error;
  Movie? _selectedMovie;

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
    double newOpacity = (offset / 50).clamp(0.0, 1.0);
    if (newOpacity != _opacity) {
      setState(() => _opacity = newOpacity);
    }
  }

  @override
  void dispose() {
    MovieTabService().currentTab.removeListener(_onActiveTabChanged);
    _debounce?.cancel();
    _controller.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce?.cancel();

    // Clear results if empty
    if (query.isEmpty) {
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
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await _tmdb.searchMulti(query);
      if (mounted) {
        setState(() {
          _results = results;
          _isLoading = false;
          if (results.isEmpty) _error = "No results found.";
        });
      }
    } catch (e) {
      if (mounted) {
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
      opacity: _opacity,
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
