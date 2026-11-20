import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../enums/app_mode.dart';
import '../models/movie.dart';
import '../services/app_mode_service.dart';
import '../services/tmdb_service.dart';
import '../widgets/smooth_scroll_controller.dart';

import 'details_screen.dart';
import '../widgets/movie_poster.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/screen_shade.dart';
import '../widgets/empty_state.dart';
import 'package:shimmer/shimmer.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/glass_blur.dart';
import '../services/movie_tab_service.dart';
import '../services/search_history_service.dart';
import '../services/tv_device.dart';
import '../widgets/tv_focus.dart';

class SearchScreen extends StatefulWidget {
  /// Whose search: Popcorn's, or Ramen's (anime only).
  final AppMode mode;

  const SearchScreen({super.key, this.mode = AppMode.movies});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = SmoothScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  // On a TV, the search bar round the field: what the remote selects (see
  // TvTextField).
  final FocusNode _barFocus = FocusNode(debugLabel: 'Search bar');
  // On a TV, the whole bar as one item (see _searchBar).
  final FocusNode _groupFocus = FocusNode(debugLabel: 'Search bar group');
  final TMDBService _tmdb = TMDBService();

  List<Movie> _results = [];
  // What the search found that's the other mode's (anime in Popcorn, the
  // rest in Ramen): shown under the results, opened in that mode.
  List<Movie> _elsewhere = [];
  // A title to open once the results are up: one carried over from the
  // other mode's search (MovieTabService.handOff).
  Movie? _pendingOpen;
  bool _isLoading = false;
  Timer? _debounce;
  String? _error;
  Movie? _selectedMovie;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    // SearchScreen stays mounted (offscreen) for the whole movies-mode
    // session as one of MovieTabShell's tabs. On a computer the field's
    // focused on arriving at the tab, ready to type into, as Ask's is; on
    // a phone or tablet only when it's tapped (focusing it there opened the
    // keyboard over the page). Unfocused when they switch away.
    MovieTabService().currentTab.addListener(_onActiveTabChanged);
    SearchHistoryService().load();
    // A search carried over from the other mode, with a title from it to
    // open (see _openInOtherMode).
    final handOff = MovieTabService().handOff;
    if (handOff != null && handOff.mode == widget.mode) {
      MovieTabService().handOff = null;
      _controller.text = handOff.query;
      _pendingOpen = handOff.movie;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performSearch(handOff.query);
      });
    }
  }

  bool get _isRamen => widget.mode == AppMode.anime;

  bool _belongs(Movie m) =>
      AppModeService.belongsIn(widget.mode, isAnime: m.isAnime);

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
    // On a TV: the keyboard closes and the remote is back on the bar, a
    // press of up from the results.
    if (TvDevice.isTv) _barFocus.requestFocus();
  }

  void _onActiveTabChanged() {
    if (MovieTabService().currentTab.value != BottomNavTab.search) {
      _searchFocusNode.unfocus();
    } else if (isComputer) {
      _searchFocusNode.requestFocus();
    } else if (TvDevice.isTv) {
      // On a TV the remote starts on the search bar: searching is what the
      // tab's for. After the frame, once the tab is no longer hidden from
      // the remote (see MovieTabShell).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _groupFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    MovieTabService().currentTab.removeListener(_onActiveTabChanged);
    _debounce?.cancel();
    _controller.dispose();
    _searchFocusNode.dispose();
    _barFocus.dispose();
    _groupFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce?.cancel();

    // Emptied: no results, and no longer loading — the search under way
    // is dropped (its answer's ignored), so it wouldn't end the loading
    // itself: the placeholders shimmered on for good.
    if (query.trim().isEmpty) {
      _searchRequestId++; // invalidate any in-flight request
      setState(() {
        _results = [];
        _elsewhere = [];
        _error = null;
        _isLoading = false;
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
      final found = await _tmdb.searchMulti(query);
      // Ramen finds anime only; Popcorn, where there's Ramen, the rest.
      // The other mode's are kept, to open there.
      final results = found.where(_belongs).toList();
      final elsewhere = found.where((m) => !_belongs(m)).toList();
      // Response times vary enough that an older query's request can
      // resolve after a newer one already has — only apply this response
      // if nothing newer has been fired since, otherwise it'd silently
      // clobber the correct, more recent results.
      if (mounted && requestId == _searchRequestId) {
        setState(() {
          _results = results;
          _elsewhere = elsewhere;
          _isLoading = false;
          if (found.isEmpty) _error = _noResults;
        });
      }
    } catch (e) {
      if (mounted && requestId == _searchRequestId) {
        setState(() {
          _isLoading = false;
          _error = _searchFailed;
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
    // The field's at the foot, as Ask's is (see _searchBar); the top has
    // the tab's name alone, as Settings' does (no back button: Home is a
    // tap away in the tab bar).
    // The keyboard covers the bottom nav bar, which isn't moved up with
    // this tab's content; the field then sits just above the keyboard.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return ScreenScaffold(
      bottomNavTab: BottomNavTab.search,
      glow: TabGlow.search,
      title: const Text('Search'),
      body: (context, isDesktop, padding) {
        // A phone's margin in a wide window's side column too, as Ask's
        // field has (its glow needs the room).
        final side = isDesktop ? 60.0 : 16.0;
        // Where Ask's field is: just above the bottom nav bar's buttons
        // (padding.bottom keeps clear of its whole fade); with no bar at
        // the foot (a wide window's, at the top; the side column), just
        // above the safe area.
        final barAtFoot =
            !navBarAtTop(context) && !SideColumnScope.inColumn(context);
        final fieldBottom = keyboardOpen
            ? 8.0
            : barAtFoot
                ? padding.bottom - 34
                // 16px up, in the side column too, as Ask's field.
                : padding.bottom + 16;
        return ValueListenableBuilder<List<String>>(
          valueListenable: SearchHistoryService().entries,
          builder: (context, history, _) {
            // Recent searches: a row of pills just above the bar, before
            // a search.
            final recents = history.isNotEmpty && _controller.text.isEmpty;
            // On a TV, the field's at the top (the keyboard comes up over
            // the bottom of the screen and hid it), the pills under it.
            if (TvDevice.isTv && SideColumnScope.inColumn(context)) {
              const fieldTop = 12.0;
              _tvContentTop = fieldTop +
                  _fieldHeight +
                  (recents ? 10 + _recentsHeight : 0) +
                  20;
              return Stack(
                children: [
                  Positioned.fill(
                    key: const ValueKey('body'),
                    child: _buildBody(context, isDesktop,
                        padding.copyWith(bottom: padding.bottom + 16)),
                  ),
                  Positioned(
                    key: const ValueKey('bar'),
                    left: side,
                    right: side,
                    top: fieldTop,
                    child: _searchBar(),
                  ),
                  if (recents)
                    Positioned(
                      key: const ValueKey('recents'),
                      left: 0,
                      right: 0,
                      top: fieldTop + _fieldHeight + 10,
                      child: _recentSearches(history, side),
                    ),
                ],
              );
            }
            // Room for the field (and the pills), and a gap so a poster's
            // title isn't right against it.
            final contentBottom = fieldBottom +
                _fieldHeight +
                (recents ? _recentsHeight + 10 : 0) +
                24;
            // Each layer keyed: unkeyed, the pills going (the first letter's
            // search starting) left the field's layer matched to theirs, and
            // the field was built anew — the phone's keyboard closed, and a
            // computer stopped taking what was typed.
            return Stack(
              children: [
                Positioned.fill(
                  key: const ValueKey('body'),
                  child: _buildBody(context, isDesktop,
                      padding.copyWith(bottom: contentBottom)),
                ),
                if (recents)
                  Positioned(
                    key: const ValueKey('recents'),
                    left: 0,
                    right: 0,
                    bottom: fieldBottom + _fieldHeight + 10,
                    child: _recentSearches(history, side),
                  ),
                Positioned(
                  key: const ValueKey('bar'),
                  left: side,
                  right: side,
                  bottom: fieldBottom,
                  child: _searchBar(),
                ),
              ],
            );
          },
        );
      },
      selectedMovie: _selectedMovie,
      onCloseSidePanel: _closeSidePanel,
    );
  }

  static const double _fieldHeight = 52;

  /// The search box at the foot, as Ask's text bar: frosted glass, the
  /// field, ✕ to clear once there's text, and a round white search button
  /// at the right, where Ask's send is.
  Widget _searchBar() {
    // On a TV, as Ask's bar: one item for the remote first (TvGroup); OK
    // goes in, to the field with its keyboard open, and the arrows then
    // reach ✕ and search too.
    return TvGroup(
      focusNode: _groupFocus,
      borderRadius: _fieldHeight / 2,
      enterOn: () => _searchFocusNode,
      child: _searchBarContent(),
    );
  }

  Widget _searchBarContent() {
    return SizedBox(
      height: _fieldHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_fieldHeight / 2),
        child: GlassBlur(
          grouped: true,
          reducedTint: Colors.black,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: glassTint(context),
              shape: StadiumBorder(side: BorderSide(color: kGlassEdge)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 7, 7, 7),
              child: Row(
                children: [
                  Expanded(
                    // On a TV: the remote selects the field's bar and opens
                    // the keyboard from it (see TvTextField).
                    child: TvTextField(
                    field: _searchFocusNode,
                    barFocus: _barFocus,
                    borderRadius: 19,
                    child: TextField(
                      controller: _controller,
                      focusNode: _searchFocusNode,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: _isRamen ? 'Anime' : 'Movies & TV shows',
                        hintStyle: const TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      ),
                      textInputAction: TextInputAction.search,
                      onChanged: _onSearchChanged,
                      onSubmitted: _searchNow,
                    ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white70, size: 18),
                            tooltip: 'Clear',
                            onPressed: () {
                              _controller.clear();
                              _onSearchChanged('');
                              // On a TV, back to typing (the ✕ is gone).
                              if (TvDevice.isTv) _barFocus.requestFocus();
                            },
                          ),
                  ),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) => IconButton(
                      tooltip: 'Search',
                      onPressed: value.text.trim().isEmpty
                          ? null
                          : () => _searchNow(_controller.text),
                      icon: const Icon(Icons.search_rounded, size: 20),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(38, 38),
                        minimumSize: const Size(38, 38),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: Colors.white24,
                      ),
                    ),
                  ),
                ],
              ),
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

  // Under the app bar, as the other tabs' content (the field's at the
  // foot now). In a wide window's side column, just clear of its rounded
  // top corners, which clipped what was right against them.
  double _topPadding(BuildContext context) => SideColumnScope.inColumn(context)
      ? (TvDevice.isTv ? _tvContentTop : 12)
      : ScreenScaffold.contentTop(context);

  // On a TV, below the field and pills at the top (see build).
  double _tvContentTop = 12;

  EdgeInsets _resultsPadding(
      BuildContext context, bool isDesktop, EdgeInsets padding) {
    // A phone's margins in a wide window's side column too, as Ask's: the
    // posters ran to its glowing panel's edges.
    final horizontal = isDesktop ? 60.0 : 16.0;
    return padding.copyWith(
      left: horizontal,
      right: horizontal,
      top: _topPadding(context),
    );
  }

  /// Poster-and-title placeholders in the results' own grid, shimmering —
  /// the app's skeleton style (as on Home and the details page), for while
  /// a fresh search loads.
  Widget _buildResultsSkeleton(
      BuildContext context, bool isDesktop, EdgeInsets padding) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: _resultsPadding(context, isDesktop, padding),
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
      return _buildResultsSkeleton(context, isDesktop, padding);
    }

    if (_error != null) {
      return _centred(
        context,
        padding,
        _error == _noResults
            ? const EmptyState(
                title: 'Nothing found',
                message: 'Try another name, or check the spelling.',
              )
            : const EmptyState(
                title: "Couldn't search",
                message: 'Check your internet connection and try again.',
              ),
      );
    }

    // Before a search: a line on what to do, nothing else — no trending
    // lists, no posters.
    if (_results.isEmpty && _controller.text.isEmpty) {
      return _centred(
        context,
        padding,
        _isRamen
            ? const EmptyState(
                title: 'Find your next anime',
                message: 'Search for any anime series or film by its name.',
              )
            : const EmptyState(
                title: 'Find something to watch',
                message: 'Search for any movie or series by its name.',
              ),
      );
    }

    // A title carried over from the other mode's search: opened once its
    // results are here.
    final pending = _pendingOpen;
    if (pending != null && !_isLoading) {
      _pendingOpen = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(pending, isDesktop);
      });
    }

    Widget grid(List<Movie> titles, void Function(Movie) onTap) =>
        SliverGrid.builder(
          gridDelegate: _resultsGrid(isDesktop),
          itemCount: titles.length,
          itemBuilder: (context, index) => MoviePoster(
            movie: titles[index],
            width: double.infinity,
            height: double.infinity,
            showTitle: true,
            onTap: () => onTap(titles[index]),
          ),
        );
    final pad = _resultsPadding(context, isDesktop, padding);
    const headingInset = 0.0;
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: pad,
          sliver: SliverMainAxisGroup(slivers: [
            grid(_results, (movie) {
              // Opening a result marks the query as a real search.
              SearchHistoryService().add(_controller.text);
              _open(movie, isDesktop);
            }),
            // The other mode's: tapped, opened there.
            if (_elsewhere.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: headingInset,
                    top: _results.isEmpty ? 0 : 28,
                    bottom: 12,
                  ),
                  child: Text(
                    _isRamen ? 'IN POPCORN' : 'IN RAMEN',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              grid(_elsewhere, _openInOtherMode),
            ],
          ]),
        ),
      ],
    );
  }

  /// Opens [movie], the other mode's (anime in Popcorn, the rest in
  /// Ramen), in that mode: switches to it, its search carrying on with
  /// this query, and the title's page opens over it (Back is the results).
  void _openInOtherMode(Movie movie) {
    final query = _controller.text.trim();
    SearchHistoryService().add(query);
    final other = movie.isAnime ? AppMode.anime : AppMode.movies;
    MovieTabService().handOff = (mode: other, query: query, movie: movie);
    AppModeService().setMode(other);
    // setMode opens the mode's home: its search instead.
    MovieTabService().currentTab.value = BottomNavTab.search;
  }

  /// Opens [movie]: beside the results on a wide window, else its page.
  void _open(Movie movie, bool isDesktop) {
    if (isDesktop) {
      setState(() => _selectedMovie = movie);
    } else {
      Navigator.push(
        context,
        CupertinoPageRoute(builder: (context) => DetailsScreen(movie: movie)),
      );
    }
  }

  static const _noResults = 'No results';
  static const _searchFailed = 'Search failed';

  /// [child] in the middle of the space between the title and the search
  /// bar (and its recent searches).
  Widget _centred(BuildContext context, EdgeInsets padding, Widget child) =>
      Padding(
        padding: EdgeInsets.fromLTRB(
            24, _topPadding(context), 24, padding.bottom),
        child: child,
      );

  static const double _recentsHeight = 36;

  /// Recent searches as a row of pills over the search bar: tap one to
  /// search it again, its ✕ to forget it. Latest first; scrolls sideways.
  Widget _recentSearches(List<String> history, double side) {
    return SizedBox(
      height: _recentsHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: side),
        itemCount: history.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final query = history[i];
          return ClipRRect(
            borderRadius: BorderRadius.circular(_recentsHeight / 2),
            child: GlassBlur(
              grouped: true,
              reducedTint: Colors.black,
              child: Material(
                color: glassTint(context),
                shape: StadiumBorder(side: BorderSide(color: kGlassEdge)),
                child: InkWell(
                  mouseCursor: WidgetStateMouseCursor.clickable,
                  customBorder: const StadiumBorder(),
                  onTap: () => _searchNow(query),
                  // The pill's full height, so its text and ✕ sit in the
                  // middle (the glass under it lets it shrink, and the
                  // row then sat at the top).
                  child: Container(
                    height: _recentsHeight,
                    padding: EdgeInsets.only(
                        left: 14, right: TvDevice.isTv ? 14 : 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            query,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14),
                          ),
                        ),
                        // Not on a TV: the remote could select only the ✕
                        // inside the pill, never the pill itself.
                        if (!TvDevice.isTv)
                          SizedBox.square(
                          dimension: 28,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white54, size: 16),
                            onPressed: () =>
                                SearchHistoryService().remove(query),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
