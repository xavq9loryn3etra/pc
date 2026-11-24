import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/movie.dart';
import '../services/movie_tab_service.dart';
import '../services/tmdb_service.dart';
import '../services/tv_device.dart';
import 'floating_bottom_nav_bar.dart' show BottomNavTab;

/// What a hero slide's builder knows about the slide it's building.
class HeroSlide {
  /// Where it is among the carousel's movies (0 = first).
  final int index;

  /// For the slide's main button (More Info): a TV remote's selection
  /// follows the slideshow onto the next slide's.
  final FocusNode primaryFocus;

  /// True for the slide the carousel opened on, until it first moves: its
  /// logo and buttons make their entrance. Any other slide's arrive with it.
  final bool entrance;

  const HeroSlide({
    required this.index,
    required this.primaryFocus,
    required this.entrance,
  });
}

/// The home hero as a slideshow, Apple TV style: [movies] one after
/// another, on their own every few seconds and round again after the last,
/// or swiped (dragged, with a mouse) by hand.
///
/// Everything moves with the finger: a slide's logo, text and buttons
/// ([content]) and the pictures behind ([background]), joined edge to edge
/// in a strip. Inside its frame, each picture moves at half that speed
/// (parallax, see [_pictureParallax]), so the pictures seem to move slowly
/// behind the text — without ever moving against it.
///
/// It holds still while a finger's on it, the hero's scrolled out of view
/// ([scrollController] past [pauseAfterScroll]), its page is covered or the
/// app's in the background (on a computer, minimized: not just another
/// window selected), a title's open beside the home, or [paused].
///
/// Each slide's details (logo, genres, trailer) load in the background,
/// and its pictures ([precache]) a slide ahead; the slideshow waits a
/// moment for them rather than showing a slide half drawn.
///
/// [layout] places the pieces: the picture strip, the slides' content
/// (which also takes the swipes: give it the hero's whole area) and the
/// dots.
class HeroCarousel extends StatefulWidget {
  final List<Movie> movies;
  final Widget Function(BuildContext context, Movie movie) background;
  final Widget Function(BuildContext context, Movie movie, HeroSlide slide)
      content;
  final Future<void> Function(BuildContext context, Movie movie) precache;
  final Widget Function(
          BuildContext context, Widget strip, Widget slides, Widget dots)
      layout;
  final ScrollController? scrollController;
  final double pauseAfterScroll;
  final bool paused;

  const HeroCarousel({
    super.key,
    required this.movies,
    required this.background,
    required this.content,
    required this.precache,
    required this.layout,
    this.scrollController,
    this.pauseAfterScroll = 300,
    this.paused = false,
  });

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

/// How much of its frame's movement a picture takes back: at 0.5 it moves
/// at half the speed of its frame (and the finger). A frame a slide off to
/// the side has its picture half a slide back towards the middle — still
/// covering all of the frame that's on screen.
///
/// (Pictures that trailed the finger and then caught up as a slide landed
/// overtook the text in the second half of the move, which made the text
/// seem to slide backwards.)
const double _pictureParallax = 0.5;

class _HeroCarouselState extends State<HeroCarousel>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// How long each slide stays: the active dot's fill.
  static const _dwell = Duration(seconds: 7);
  static const _slideDuration = Duration(milliseconds: 800);
  static const _slideCurve = Curves.easeInOutCubic;

  /// Longest the slideshow waits for the next slide's details and pictures
  /// before moving on regardless.
  static const _maxWaitForNext = Duration(seconds: 3);

  // The slides are an endless PageView, starting far enough in to swipe
  // back from the first; slide = page % count.
  late int _origin;
  late PageController _pages;

  late final AnimationController _progress =
      AnimationController(vsync: this, duration: _dwell)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _advance();
        });

  // Each slide's details once loaded, and the loads (and pre-decodes)
  // under way, by slide.
  final Map<int, Movie> _details = {};
  final Map<int, Future<Movie?>> _loads = {};
  final Map<int, Future<void>> _readies = {};
  final Map<int, FocusNode> _focus = {};

  int _slide = 0; // the slide in view, for the dots
  bool _moved = false;

  int _pointers = 0;
  bool _dragging = false;
  bool _waiting = false; // for the next slide to be ready (see _advance)
  bool _sliding = false; // to another slide (see _goTo)
  bool _foreground = true;
  bool _tickerOn = true;
  bool _scrolledAway = false;
  bool _focusInside = false;
  ValueListenable<TickerModeData>? _tickerMode;

  int get _count => widget.movies.length;
  Movie _movie(int slide) => _details[slide] ?? widget.movies[slide];

  int get _page => _pages.hasClients && _pages.position.hasContentDimensions
      ? _pages.page!.round()
      : _origin;

  bool get _blocked =>
      _count < 2 ||
      widget.paused ||
      _pointers > 0 ||
      _dragging ||
      !_foreground ||
      !_tickerOn ||
      _scrolledAway ||
      MovieTabService().columnPages.value > 0 ||
      // A weak TV: held while another tab's open in the column beside it
      // too (Search, My List…), so it isn't loading the next slide's big
      // pictures while that tab's are scrolled (see TvDevice.isLowMemory).
      (TvDevice.isLowMemory &&
          MovieTabService().currentTab.value != BottomNavTab.home);

  @override
  void initState() {
    super.initState();
    _origin = _count * 1000;
    _pages = PageController(initialPage: _origin);
    WidgetsBinding.instance.addObserver(this);
    widget.scrollController?.addListener(_onScroll);
    MovieTabService().columnPages.addListener(_sync);
    MovieTabService().currentTab.addListener(_sync);
    // After the page's first busy moments: the rest of the slides'
    // details, one at a time, and the next slide's pictures.
    Future.delayed(const Duration(seconds: 1), _loadAll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode?.removeListener(_onTickerMode);
    _tickerMode = TickerMode.getValuesNotifier(context)
      ..addListener(_onTickerMode);
    _onTickerMode();
  }

  @override
  void didUpdateWidget(HeroCarousel old) {
    super.didUpdateWidget(old);
    if (old.scrollController != widget.scrollController) {
      old.scrollController?.removeListener(_onScroll);
      widget.scrollController?.addListener(_onScroll);
    }
    final sameMovies = old.movies.length == widget.movies.length &&
        [
          for (var i = 0; i < _count; i++)
            old.movies[i].id == widget.movies[i].id
        ].every((same) => same);
    if (!sameMovies) {
      // A new list (rare: the home reloaded): back to its first slide.
      _details.clear();
      _loads.clear();
      _readies.clear();
      _slide = 0;
      _moved = false;
      _origin = _count * 1000;
      if (_pages.hasClients) _pages.jumpToPage(_origin);
      _progress.value = 0;
      Future.microtask(_loadAll);
    }
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.scrollController?.removeListener(_onScroll);
    MovieTabService().columnPages.removeListener(_sync);
    MovieTabService().currentTab.removeListener(_sync);
    _tickerMode?.removeListener(_onTickerMode);
    _progress.dispose();
    _pages.dispose();
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On a computer, a window that's not selected (inactive) is still in
    // view: it holds still only once minimized (hidden). On a phone,
    // inactive is the notification shade or the app switcher over it.
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };
    _foreground = state == AppLifecycleState.resumed ||
        (desktop && state == AppLifecycleState.inactive);
    _sync();
  }

  void _onTickerMode() {
    _tickerOn = _tickerMode?.value.enabled ?? true;
    _sync();
  }

  void _onScroll() {
    final controller = widget.scrollController!;
    final away =
        controller.hasClients && controller.offset > widget.pauseAfterScroll;
    if (away == _scrolledAway) return;
    _scrolledAway = away;
    _sync();
  }

  /// Runs the active slide's timer, or holds it, as things stand.
  void _sync() {
    if (!mounted) return;
    if (_blocked || _waiting || _sliding) {
      _progress.stop();
    } else if (_progress.isCompleted) {
      // Its time ran out while held (see _advance).
      _advance();
    } else if (!_progress.isAnimating) {
      _progress.forward();
    }
  }

  FocusNode _focusFor(int slide) =>
      _focus.putIfAbsent(slide, () => FocusNode(debugLabel: 'Hero $slide'));

  Future<Movie?> _detailsFor(int slide) => _loads[slide] ??= () async {
        final basic = widget.movies[slide];
        Movie? movie;
        try {
          movie = await TMDBService().prefetchDetails(basic.id, type: basic.type);
        } catch (_) {}
        if (movie != null && mounted && slide < _count) {
          final loaded = movie;
          setState(() => _details[slide] = loaded);
        }
        return movie;
      }();

  /// [slide]'s details loaded and its pictures decoded.
  Future<void> _ready(int slide) => _readies[slide] ??= () async {
        final movie = await _detailsFor(slide);
        if (!mounted) return;
        await widget.precache(context, movie ?? widget.movies[slide]);
      }()
          .catchError((_) {});

  Future<void> _loadAll() async {
    if (!mounted || _count < 2) return;
    _ready(1);
    _ready(_count - 1);
    for (var slide = 2; slide < _count - 1; slide++) {
      if (!mounted) return;
      await _detailsFor(slide);
    }
  }

  /// On to the next slide, its time up — once it's ready (or has kept us
  /// waiting long enough).
  Future<void> _advance() async {
    if (_waiting || _sliding || _blocked) return;
    _waiting = true;
    final from = _page;
    try {
      await _ready((from + 1) % _count).timeout(_maxWaitForNext);
    } catch (_) {}
    if (!mounted) return;
    _waiting = false;
    // Moved meanwhile (swiped, a dot tapped) or held (_sync moves on once
    // it's let go).
    if (_sliding || _blocked || _page != from || !_progress.isCompleted) {
      _sync();
      return;
    }
    await _goTo(from + 1);
  }

  Future<void> _goTo(int page) async {
    if (!_pages.hasClients) return;
    _sliding = true;
    _progress.stop();
    // By slide, not by pixels (as animateToPage does): opening a tab in
    // the wide window's side column narrows the home mid-slide, and a
    // slide aimed at the old width's pixels landed thousands of slides
    // away — it raced off to a far one.
    final position = _pages.position;
    final Future<void> moving;
    if (position is ScrollPositionWithSingleContext) {
      final slide = _SlideActivity(
        position,
        from: _pages.page ?? page.toDouble(),
        to: page.toDouble(),
        duration: _slideDuration,
        curve: _slideCurve,
        vsync: position.context.vsync,
      );
      position.beginActivity(slide);
      moving = slide.done;
    } else {
      moving = _pages.animateToPage(
        page,
        duration: _slideDuration,
        curve: _slideCurve,
      );
    }
    // A TV remote's selection was on this slide's buttons: onto the next's
    // (it's focused once it's built, a frame on).
    if (_focusInside) _focusFor(page % _count).requestFocus();
    await moving;
    if (!mounted) return;
    _sliding = false;
    _progress.value = 0;
    _sync();
  }

  void _onDotTap(int slide) {
    if (slide == _slide || _sliding) return;
    // The short way round: from the last slide, the first is the next one.
    var delta = slide - _slide;
    if (delta > _count / 2) delta -= _count;
    if (delta < -_count / 2) delta += _count;
    _moved = true;
    _ready(slide);
    _goTo(_page + delta);
  }

  bool _onSlidesScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _sync();
    } else if (notification is ScrollEndNotification) {
      if (_dragging) {
        _dragging = false;
        // Swiped by hand: the slide it landed on gets its full time.
        _progress.value = 0;
      }
      final slide = _page % _count;
      _ready((slide + 1) % _count);
      _ready((slide - 1 + _count) % _count);
      _sync();
    }
    return false;
  }

  void _onPageChanged(int page) {
    setState(() {
      _slide = page % _count;
      if (page != _origin) _moved = true;
    });
    // The new slide's dot starts empty (it fills from when it lands).
    _progress.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final slides = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => _focusInside = focused,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onSlidesScroll,
        child: Listener(
          onPointerDown: (_) {
            _pointers++;
            _sync();
          },
          onPointerUp: (_) {
            _pointers = math.max(0, _pointers - 1);
            _sync();
          },
          onPointerCancel: (_) {
            _pointers = math.max(0, _pointers - 1);
            _sync();
          },
          child: ScrollConfiguration(
            // Swiped with a mouse too, on a computer.
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              overscroll: false,
              dragDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
                PointerDeviceKind.trackpad,
              },
            ),
            child: PageView.builder(
              controller: _pages,
              physics: _count < 2 ? const NeverScrollableScrollPhysics() : null,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, page) {
                final slide = page % _count;
                return widget.content(
                  context,
                  _movie(slide),
                  HeroSlide(
                    index: slide,
                    primaryFocus: _focusFor(slide),
                    entrance: !_moved && page == _origin,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    final strip = _PictureStrip(
      controller: _pages,
      origin: _origin,
      count: _count,
      movieAt: _movie,
      builder: widget.background,
    );

    final dots = _count < 2
        ? const SizedBox.shrink()
        : HeroDots(
            count: _count,
            active: _slide,
            progress: _progress,
            onTap: _onDotTap,
          );

    return widget.layout(context, strip, slides, dots);
  }
}

/// The slides' pictures side by side in frames joined edge to edge, moving
/// with the slides above them, each picture moving within its frame (see
/// _pictureParallax). Only
/// the one or two in view are built; each is kept (and drawn once, behind
/// a RepaintBoundary) while it's in view, so moving them is just moving
/// their layers.
class _PictureStrip extends StatefulWidget {
  final PageController controller;
  final int origin;
  final int count;
  final Movie Function(int slide) movieAt;
  final Widget Function(BuildContext context, Movie movie) builder;

  const _PictureStrip({
    required this.controller,
    required this.origin,
    required this.count,
    required this.movieAt,
    required this.builder,
  });

  @override
  State<_PictureStrip> createState() => _PictureStripState();
}

class _PictureStripState extends State<_PictureStrip> {
  // Built pictures by page, with the movie each was built for (a slide's
  // picture is rebuilt once its details arrive).
  final Map<int, (Movie, Widget)> _tiles = {};
  Size? _size;

  Widget _tile(int page) {
    final movie = widget.movieAt(page % widget.count);
    final kept = _tiles[page];
    if (kept != null && identical(kept.$1, movie)) return kept.$2;
    final tile = RepaintBoundary(child: widget.builder(context, movie));
    _tiles[page] = (movie, tile);
    return tile;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // Resized (a window, a phone turned): the pictures may be wanted
        // at another size, or another picture altogether.
        if (size != _size) {
          _size = size;
          _tiles.clear();
        }
        final width = size.width;
        return ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final controller = widget.controller;
            final page =
                controller.hasClients && controller.position.hasContentDimensions
                    ? controller.page!
                    : widget.origin.toDouble();
            final first = page.floor();
            final pages = [first, if (page - first > 0.0001) first + 1];
            _tiles.removeWhere((key, _) => !pages.contains(key));
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final p in pages)
                  Positioned(
                    key: ValueKey(p),
                    top: 0,
                    bottom: 0,
                    left: (p - page) * width,
                    width: width,
                    // The frame, its picture shifted back towards the
                    // middle within it.
                    child: ClipRect(
                      child: Transform.translate(
                        offset:
                            Offset(-(p - page) * width * _pictureParallax, 0),
                        child: _tile(p),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The slideshow's dots, Apple TV style: a dot a slide, the current one a
/// longer pill that fills as its time runs ([progress]). With more slides
/// than fit ([_maxShown]), only a window of them shows, the dots at an edge
/// with more beyond it smaller. Tapping one goes to its slide.
class HeroDots extends StatefulWidget {
  final int count;
  final int active;
  final Animation<double> progress;
  final ValueChanged<int> onTap;

  const HeroDots({
    super.key,
    required this.count,
    required this.active,
    required this.progress,
    required this.onTap,
  });

  @override
  State<HeroDots> createState() => _HeroDotsState();
}

class _HeroDotsState extends State<HeroDots> {
  static const _maxShown = 8;
  static const _dot = 8.0;
  static const _smallDot = 4.5;
  static const _pill = 26.0;
  static const _gap = 10.0;
  static const _duration = Duration(milliseconds: 350);
  static const _curve = Curves.easeOutCubic;

  int _start = 0; // the first dot in the window

  @override
  void initState() {
    super.initState();
    _fit();
  }

  @override
  void didUpdateWidget(HeroDots old) {
    super.didUpdateWidget(old);
    _fit();
  }

  /// Moves the window so the current dot is in it, off its smaller edges.
  void _fit() {
    final count = widget.count;
    final active = widget.active;
    if (count <= _maxShown) {
      _start = 0;
      return;
    }
    if (active <= _start) {
      _start = math.max(0, active - 1);
    } else if (active >= _start + _maxShown - 1) {
      _start = math.min(count - _maxShown, active - _maxShown + 2);
    }
    _start = _start.clamp(0, count - _maxShown);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    final end = math.min(count, _start + _maxShown); // past the last shown
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) _buildDot(i, end),
      ],
    );
  }

  Widget _buildDot(int i, int end) {
    final shown = i >= _start && i < end;
    final edge =
        (i == _start && _start > 0) || (i == end - 1 && end < widget.count);
    final active = i == widget.active;
    final width = !shown
        ? 0.0
        : active
            ? _pill
            : edge
                ? _smallDot
                : _dot;
    final height = !shown ? 0.0 : (edge && !active ? _smallDot : _dot);

    final dot = AnimatedContainer(
      duration: _duration,
      curve: _curve,
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_dot / 2),
        color: Colors.white.withValues(alpha: active ? 0.35 : 0.6),
      ),
      child: active
          ? AnimatedBuilder(
              animation: widget.progress,
              builder: (context, _) => Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: widget.progress.value,
                  heightFactor: 1,
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            )
          : null,
    );

    return MouseRegion(
      cursor: shown ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: shown ? () => widget.onTap(i) : null,
        child: AnimatedPadding(
          duration: _duration,
          curve: _curve,
          padding: EdgeInsets.symmetric(
            horizontal: shown ? _gap / 2 : 0,
            vertical: 10,
          ),
          child: SizedBox(
            height: _dot,
            child: Center(child: dot),
          ),
        ),
      ),
    );
  }
}

/// A slide from one page to another, as PageController.animateToPage's,
/// but steered by page rather than by pixels: each frame puts the slides
/// where they belong at the page view's width then, so a width change
/// mid-slide (the side column opening) can't send it somewhere else.
class _SlideActivity extends ScrollActivity {
  _SlideActivity(
    ScrollPositionWithSingleContext position, {
    required double from,
    required double to,
    required Duration duration,
    required Curve curve,
    required TickerProvider vsync,
  })  : _position = position,
        _from = from,
        _to = to,
        super(position) {
    _controller = AnimationController(duration: duration, vsync: vsync)
      ..addListener(_tick);
    _controller
        .animateTo(1, curve: curve)
        .whenComplete(() => delegate.goBallistic(0));
  }

  final ScrollPositionWithSingleContext _position;
  final double _from;
  final double _to;
  late final AnimationController _controller;
  final Completer<void> _done = Completer<void>();

  /// Completes when the slide ends, or something else (a swipe) takes over.
  Future<void> get done => _done.future;

  void _tick() {
    final page = _from + (_to - _from) * _controller.value;
    if (delegate.setPixels(page * _position.viewportDimension) != 0) {
      delegate.goIdle();
    }
  }

  @override
  bool get shouldIgnorePointer => true;

  @override
  bool get isScrolling => true;

  @override
  double get velocity =>
      (_to - _from) * _position.viewportDimension * _controller.velocity;

  @override
  void dispose() {
    if (!_done.isCompleted) _done.complete();
    _controller.dispose();
    super.dispose();
  }
}
