import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';

import 'details_screen.dart';
import '../widgets/movie_poster.dart';
import '../widgets/screen_scaffold.dart';
import 'package:shimmer/shimmer.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/glass_blur.dart';
import '../services/movie_tab_service.dart';
import '../services/search_history_service.dart';

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
  Timer? _debounce;
  String? _error;
  Movie? _selectedMovie;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    // SearchScreen stays mounted (offscreen) for the whole movies-mode
    // session as one of MovieTabShell's tabs, so `autofocus` would pop the
    // keyboard the instant the app opens rather than when this tab is
    // actually shown. Focus only on the transitions that matter: opening
    // the keyboard when the user switches to Search, dismissing it when
    // they switch away.
    MovieTabService().currentTab.addListener(_onActiveTabChanged);
    SearchHistoryService().load();
  }

  /// Runs [query] right away (no debounce) and records it as a deliberate
  /// search — used for keyboard submit and tapping a recent search.
  void _searchNow(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    if (_controller.text != q) {
      _controller.value = TextEditingValue(
        text: q,
        selection: TextSelection.collapsed(offset: q.length),
      );
    }
    SearchHistoryService().add(q);
    _performSearch(q);
  }

  void _onActiveTabChanged() {
    if (MovieTabService().currentTab.value == BottomNavTab.search) {
      _searchFocusNode.requestFocus();
    } else {
      _searchFocusNode.unfocus();
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
      leading: Center(
        child: GlassCircleButton(
          icon: GlassCircleButton.backIcon,
          iconSize: GlassCircleButton.backIconSize,
          // Search is a bottom-nav tab, not a pushed route, so there's no
          // route to pop — "back" here means returning to the Home tab,
          // same as tapping the Home icon in FloatingBottomNavBar.
          onPressed: () =>
              MovieTabService().currentTab.value = BottomNavTab.home,
        ),
      ),
      title: _buildSearchField(),
      actions: const [SizedBox(width: 16)],
      body: _buildBody,
      selectedMovie: _selectedMovie,
      onCloseSidePanel: _closeSidePanel,
    );
  }

  /// The search box as a frosted pill, like the bottom nav bar's Search
  /// button it's opened from: a search icon, the field, and ✕ to clear
  /// once there's text.
  Widget _buildSearchField() {
    return SizedBox(
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: GlassBlur(
          reducedTint: Colors.black.withValues(alpha: 0.45),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: kGlassTint,
              shape: StadiumBorder(side: BorderSide(color: kGlassEdge)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 14),
                const Icon(Icons.search_rounded,
                    color: Colors.white70, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _searchFocusNode,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: Colors.white,
                    decoration: const InputDecoration(
                      hintText: 'Movies & TV shows',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: _onSearchChanged,
                    onSubmitted: _searchNow,
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox(width: 14)
                      : IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white70, size: 18),
                          tooltip: 'Clear',
                          onPressed: () {
                            _controller.clear();
                            _onSearchChanged('');
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The results grid's layout, shared with its placeholder so they match.
  SliverGridDelegate _resultsGrid(bool isDesktop) =>
      SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: isDesktop ? 200 : 150,
        childAspectRatio: isDesktop ? (200 / 340) : 0.58,
        crossAxisSpacing: isDesktop ? 16 : 12,
        mainAxisSpacing: isDesktop ? 16 : 12,
      );

  EdgeInsets _resultsPadding(bool isDesktop, EdgeInsets padding) {
    final horizontal = isDesktop ? 60.0 : 16.0;
    return padding.copyWith(left: horizontal, right: horizontal, top: 100);
  }

  /// Poster-and-title placeholders in the results' own grid, shimmering —
  /// the app's skeleton style (as on Home and the details page), for while
  /// a fresh search loads.
  Widget _buildResultsSkeleton(bool isDesktop, EdgeInsets padding) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: _resultsPadding(isDesktop, padding),
        gridDelegate: _resultsGrid(isDesktop),
        itemCount: 12,
        itemBuilder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FractionallySizedBox(
              widthFactor: 0.75,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool isDesktop, EdgeInsets padding) {
    // While a refined query loads, the current results stay up (below) and
    // are swapped when the new ones arrive — wiping them on every letter
    // typed made the screen flash. Placeholders only for a fresh search.
    if (_isLoading && _results.isEmpty) {
      return _buildResultsSkeleton(isDesktop, padding);
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_results.isEmpty && _controller.text.isEmpty) {
      return ValueListenableBuilder<List<String>>(
        valueListenable: SearchHistoryService().entries,
        builder: (context, history, _) {
          if (history.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search_rounded, size: 64, color: Colors.white12),
                  SizedBox(height: 16),
                  Text(
                    'Find your next favorite.',
                    style: TextStyle(color: Colors.white24),
                  ),
                ],
              ),
            );
          }
          return _buildRecentSearches(history, isDesktop, padding);
        },
      );
    }

    return GridView.builder(
      controller: _scrollController,
      padding: _resultsPadding(isDesktop, padding),
      gridDelegate: _resultsGrid(isDesktop),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final movie = _results[index];
        return MoviePoster(
          movie: movie,
          width: double.infinity,
          height: double.infinity,
          showTitle: true,
          onTap: () {
            // Opening a result marks the query as a real search.
            SearchHistoryService().add(_controller.text);
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

  /// "Recent" list shown while the search box is empty: tap to search
  /// again, ✕ to forget.
  Widget _buildRecentSearches(
    List<String> history,
    bool isDesktop,
    EdgeInsets padding,
  ) {
    final horizontalPadding = isDesktop ? 60.0 : 8.0;
    return ListView(
      padding: padding.copyWith(
        left: horizontalPadding,
        right: horizontalPadding,
        top: 100,
      ),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'RECENT SEARCHES',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ),
        for (final query in history)
          InkWell(
            onTap: () => _searchNow(query),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, color: Colors.white38, size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      query,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white38, size: 18),
                    tooltip: 'Remove',
                    onPressed: () => SearchHistoryService().remove(query),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
