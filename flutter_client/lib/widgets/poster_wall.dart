import 'package:flutter/material.dart';

import '../services/app_mode_service.dart';

/// The tilted, endlessly scrolling wall of book / album / movie artwork
/// behind the welcome screen and the app-wide status screens (update,
/// maintenance, offline). Uses bundled assets, so it renders instantly and
/// works without a connection.
class PosterWall extends StatelessWidget {
  /// The artwork's size against the usual (1). Smaller on a phone's welcome
  /// screen, so more of it shows through the logo cut out of the frost.
  final double scale;

  /// How far down the wall (0 top, 1 bottom) its middle row of movies runs:
  /// through the welcome screen's logo, wherever that sits.
  final double focus;

  const PosterWall({super.key, this.scale = 1.0, this.focus = 0.5});

  static const _movieAssets = [
    'assets/welcome/movies/movie_1.jpg',
    'assets/welcome/movies/movie_2.jpg',
    'assets/welcome/movies/movie_3.jpg',
    'assets/welcome/movies/movie_4.jpg',
    'assets/welcome/movies/movie_5.jpg',
    'assets/welcome/movies/movie_6.jpg',
    'assets/welcome/movies/movie_7.jpg',
    'assets/welcome/movies/movie_8.jpg',
  ];

  static const _musicAssets = [
    'assets/welcome/music/music_1.jpg',
    'assets/welcome/music/music_2.jpg',
    'assets/welcome/music/music_3.jpg',
    'assets/welcome/music/music_4.jpg',
    'assets/welcome/music/music_5.jpg',
    'assets/welcome/music/music_6.jpg',
    'assets/welcome/music/music_7.jpg',
    'assets/welcome/music/music_8.jpg',
  ];

  static const _bookAssets = [
    'assets/welcome/books/book_1.jpg',
    'assets/welcome/books/book_2.jpg',
    'assets/welcome/books/book_3.jpg',
    'assets/welcome/books/book_4.jpg',
    'assets/welcome/books/book_5.jpg',
    'assets/welcome/books/book_6.jpg',
    'assets/welcome/books/book_7.jpg',
    'assets/welcome/books/book_8.jpg',
  ];

  // At least this many rows; more when smaller artwork or a taller screen
  // needs them to fill it.
  static const _minRows = 6;

  static const _books = 0, _music = 1, _movies = 2;

  /// Books, music and movies in turn, counted from the middle row ([middle]),
  /// which is movies.
  /// Where the app is Popcorn only (the desktop app, a TV), every row is
  /// movies: music and books aren't there to show.
  static int _kindOf(int rowIndex, int middle) => AppModeService.canSwitchMode
      ? ((rowIndex - middle + _movies) % 3 + 3) % 3
      : _movies;

  double _rowHeight(int kind) => ((kind == _music ? 135.0 : 155.0) + 8) * scale;

  Widget _buildRow(int rowIndex, int kind) {
    final assets = switch (kind) {
      _books => _bookAssets,
      _music => _musicAssets,
      _ => _movieAssets,
    };
    final isMusic = kind == _music;
    final scrollRight = rowIndex.isEven;
    // Repeats every six rows, so extra rows don't get ever faster.
    final speed = 1.0 + ((rowIndex % _minRows) * 0.15);

    // Music uses 1:1 square aspect ratio; movies and books use ~2:3 portrait
    final double itemWidth = (isMusic ? 135.0 : 105.0) * scale;
    final double itemHeight = (isMusic ? 135.0 : 155.0) * scale;

    return _ScrollingRow(
      imageAssets: assets,
      scrollRight: scrollRight,
      speed: speed,
      itemWidth: itemWidth,
      itemHeight: itemHeight,
      gap: 8 * scale,
      radius: 12 * scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final height =
          constraints.maxHeight.isFinite ? constraints.maxHeight : 800.0;
      // How far the middle row is moved off the wall's centre to sit at
      // [focus]; the wall needs that many more rows above or below.
      final shift = (focus - 0.5) * height;
      // Rows average (155 + 135 + 155) / 3 tall, plus their gap; a couple
      // more than fit, as the tilt pulls the corners in. An odd count, so
      // there's a middle row.
      final averageRow = (445 / 3 + 8) * scale;
      var rows = ((height + 2 * shift.abs()) / averageRow).ceil() + 2;
      rows = rows.clamp(_minRows, 60);
      if (rows.isEven) rows++;
      final middle = rows ~/ 2;

      // The column is centred, but its rows above and below the middle
      // aren't quite the same height: where that leaves the middle row's
      // centre, against the column's.
      var above = 0.0, below = 0.0;
      for (var i = 0; i < rows; i++) {
        final h = _rowHeight(_kindOf(i, middle));
        if (i < middle) above += h;
        if (i > middle) below += h;
      }
      final offset = shift - (above - below) / 2;

      // The rows scroll every frame; the boundary keeps that repaint to the
      // wall, instead of also repainting the text and buttons over it.
      return RepaintBoundary(
        child: ClipRect(
          child: OverflowBox(
            maxHeight: double.infinity,
            alignment: Alignment.center,
            child: Transform.translate(
              offset: Offset(0, offset),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateX(0.15)
                  ..rotateZ(-0.05),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(rows, (i) {
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 4 * scale),
                      child: _buildRow(i, _kindOf(i, middle)),
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _ScrollingRow extends StatefulWidget {
  final List<String> imageAssets;
  final bool scrollRight;
  final double speed;
  final double itemWidth;
  final double itemHeight;
  final double gap;
  final double radius;

  const _ScrollingRow({
    required this.imageAssets,
    required this.scrollRight,
    required this.speed,
    required this.itemWidth,
    required this.itemHeight,
    required this.gap,
    required this.radius,
  });

  @override
  State<_ScrollingRow> createState() => _ScrollingRowState();
}

class _ScrollingRowState extends State<_ScrollingRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final durationMs = (85000 / widget.speed).round();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: durationMs),
    )..repeat(reverse: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageAssets.isEmpty) return const SizedBox.shrink();

    // itemWidth + its horizontal margin
    final double totalItemWidth = widget.itemWidth + widget.gap;
    final double setWidth = totalItemWidth * widget.imageAssets.length;

    return SizedBox(
      height: widget.itemHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          double offset = _controller.value * setWidth;

          if (widget.scrollRight) {
            offset = offset - setWidth;
          } else {
            offset = -offset;
          }

          return Transform.translate(
            offset: Offset(offset, 0),
            child: child,
          );
        },
        child: OverflowBox(
          maxWidth: double.infinity,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._buildItems(),
              ..._buildItems(),
              ..._buildItems(), // 3 sets ensures continuous screen coverage and smooth loop
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildItems() {
    return widget.imageAssets.map((assetPath) {
      return Container(
        width: widget.itemWidth,
        height: widget.itemHeight,
        margin: EdgeInsets.symmetric(horizontal: widget.gap / 2),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: Image.asset(
            assetPath,
            fit: BoxFit.cover,
            // Decoded at the size it's shown, not its own: two dozen at
            // full size at once pushed the app's posters out of memory.
            cacheHeight:
                (widget.itemHeight * MediaQuery.devicePixelRatioOf(context))
                    .round(),
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey[850],
              child: const Icon(Icons.broken_image_rounded, color: Colors.grey),
            ),
          ),
        ),
      );
    }).toList();
  }
}
