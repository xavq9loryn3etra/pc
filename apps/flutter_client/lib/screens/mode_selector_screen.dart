import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/trending_service.dart';
import '../theme/iridescent.dart';
import '../widgets/glass_blur.dart';
import '../widgets/mode_switch_row.dart';
import 'main_screen.dart';

/// Start screen: a full-bleed, slowly zooming slideshow of the top three
/// trending titles for the last opened mode, with the mode buttons on a
/// curved panel below.
class ModeSelectorScreen extends StatefulWidget {
  const ModeSelectorScreen({super.key});

  @override
  State<ModeSelectorScreen> createState() => _ModeSelectorScreenState();
}

class _ModeSelectorScreenState extends State<ModeSelectorScreen> {
  static const _slideDuration = Duration(seconds: 6);
  static const _fadeDuration = Duration(milliseconds: 1000);

  late final AppMode _mode = AppModeService().currentMode.value;

  // The list being cycled through, and the position in it.
  List<TrendingItem> _queue = [];
  int _queueIndex = 0;
  // A fresh list that arrived while a cached one was showing; swapped in at
  // the next slide change rather than cutting the current slide short.
  List<TrendingItem>? _pending;

  // What's on screen (null until the first image has loaded), and a
  // counter that gives every slide its own key.
  TrendingItem? _current;
  int _slide = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final service = TrendingService();
    final cached = await service.cached(_mode);
    if (!mounted) return;
    if (cached.isNotEmpty) await _show(cached, 0);

    final fresh = await service.fetch(_mode);
    if (!mounted || fresh.isEmpty) return;
    if (_queue.isEmpty) {
      await _show(fresh, 0);
    } else {
      _pending = fresh;
    }
  }

  bool get _isWide {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  ImageProvider _imageFor(TrendingItem item) =>
      CachedNetworkImageProvider(item.imageFor(wide: _isWide));

  // The mode panel's "frosted glass": the slide decoded tiny and stretched
  // smoothly reads as the artwork blurred, without a live BackdropFilter —
  // which re-blurred the always-zooming slideshow on every frame.
  ImageProvider _blurredImageFor(TrendingItem item) =>
      ResizeImage.resizeIfNeeded(40, null, _imageFor(item));

  /// Shows [items][index] once its image has loaded (skipping it if it
  /// fails), then schedules the next slide.
  Future<void> _show(List<TrendingItem> items, int index) async {
    _timer?.cancel();
    _queue = items;
    _queueIndex = index;
    final item = items[index];
    var loaded = true;
    try {
      await Future.wait([
        precacheImage(_imageFor(item), context,
            onError: (_, __) => loaded = false),
        // So the panel's blurred copy switches with the slide, not after.
        precacheImage(_blurredImageFor(item), context, onError: (_, __) {}),
        // A logo that fails to load just falls back to the text title.
        if (item.logoUrl != null)
          precacheImage(CachedNetworkImageProvider(item.logoUrl!), context,
              onError: (_, __) {}),
      ]).timeout(const Duration(seconds: 8));
    } catch (_) {
      loaded = false;
    }
    if (!mounted) return;
    if (loaded) {
      setState(() {
        _current = items[index];
        _slide++;
      });
    }
    _timer = Timer(loaded ? _slideDuration : Duration.zero, _next);
  }

  void _next() {
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      // Carry on from whatever's on screen — the fresh list usually starts
      // with the same title the cached one did, which would repeat it.
      final current = pending.indexWhere(
          (i) => i.imageUrl == _current?.imageUrl || i.title == _current?.title);
      _show(pending, (current + 1) % pending.length);
    } else if (_queue.isNotEmpty) {
      _show(_queue, (_queueIndex + 1) % _queue.length);
    }
  }

  void _selectMode(AppMode mode) {
    AppModeService().setMode(mode);
    // Get to the destination as fast as possible rather than making the
    // user sit through a long fade — the destination screen's own skeleton
    // loaders (TMDB fetch, etc.) already communicate "still loading" once
    // we're there, so there's nothing to gain from a slow transition on
    // top of that. Kept brief instead of instant (Duration.zero) purely so
    // it doesn't read as a rendering glitch.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MainScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 150),
      ),
    );
  }

  // Scrims: keep the status bar legible and darken behind the caption,
  // easing off again under the panel so the art still shows through its
  // glass.
  static const _scrim = DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0x99000000),
          Color(0x00000000),
          Color(0x00000000),
          Color(0xBF000000),
          Color(0x99000000),
        ],
        stops: [0.0, 0.16, 0.34, 0.62, 1.0],
      ),
    ),
  );

  /// The zooming, cross-fading slideshow — sharp as the background, or
  /// [blurred] for the mode panel's glass. Both copies are built in the
  /// same frame with the same slide key, so their zoom and fades run in
  /// step. Behind a RepaintBoundary: it animates every frame, and shouldn't
  /// drag the caption and buttons above it into repainting too.
  Widget _slideshow(TrendingItem? item, {required bool blurred}) {
    return RepaintBoundary(
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: _fadeDuration,
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [...previous, if (current != null) current],
          ),
          child: item == null
              ? _Placeholder(key: const ValueKey('placeholder'), mode: _mode)
              : _KenBurnsImage(
                  key: ValueKey(_slide),
                  image: blurred ? _blurredImageFor(item) : _imageFor(item),
                  // Smooth (bicubic) upscaling turns the tiny decode into
                  // a soft blur rather than visible blocks.
                  filterQuality:
                      blurred ? FilterQuality.high : FilterQuality.medium,
                  // Vary where each slide zooms towards
                  focus: const [
                    Alignment(0, -0.4),
                    Alignment(0.3, 0.1),
                    Alignment(-0.3, -0.1),
                  ][_slide % 3],
                  duration: _slideDuration + _fadeDuration,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final screenSize = MediaQuery.sizeOf(context);
    final item = _current;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background slideshow — full height, so the frosted panel at the
          // bottom has artwork behind it.
          Positioned.fill(child: _slideshow(item, blurred: false)),

          const Positioned.fill(child: _scrim),

          // Title, prompt and mode buttons
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: SizedBox(
                    // Up-to-80px logo + subtitle
                    height: 128,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 500),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.08),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: item == null
                          ? const SizedBox.expand()
                          : _HeroCaption(
                              key: ValueKey(_slide),
                              item: item,
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'Choose your mode',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 14),
                // Same frosted glass as the floating bottom nav bar's
                // buttons (blur, colour boost, kGlassTint) — but faked:
                // a blurred copy of the slideshow, lined up with the real
                // one behind (the panel spans the screen's full width and
                // sits on its bottom edge), instead of a live blur.
                CustomPaint(
                  foregroundPainter: _DomeEdgePainter(),
                  child: ClipPath(
                    clipper: _DomeClipper(),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: OverflowBox(
                              alignment: Alignment.bottomCenter,
                              minWidth: screenSize.width,
                              maxWidth: screenSize.width,
                              minHeight: screenSize.height,
                              maxHeight: screenSize.height,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ColorFiltered(
                                    colorFilter: GlassBlur.saturate,
                                    child: _slideshow(item, blurred: true),
                                  ),
                                  _scrim,
                                ],
                              ),
                            ),
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          color:
                              kGlassTint,
                          padding: EdgeInsets.fromLTRB(
                              16, 40, 16, 28 + bottomInset),
                          child: ModeSwitchRow(onSelected: _selectMode),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Title (logo artwork where available) and subtitle for one slide.
class _HeroCaption extends StatelessWidget {
  final TrendingItem item;

  const _HeroCaption({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final title = Text(
      item.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 30,
        height: 1.1,
        fontWeight: FontWeight.w800,
        color: Colors.white,
        letterSpacing: -0.5,
      ),
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (item.logoUrl != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260, maxHeight: 80),
            child: Image(
              image: CachedNetworkImageProvider(item.logoUrl!),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => title,
            ),
          )
        else
          title,
        if (item.subtitle.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            item.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ],
    );
  }
}

/// Slowly zooms into its image for as long as it's on screen.
class _KenBurnsImage extends StatelessWidget {
  final ImageProvider image;
  final Alignment focus;
  final Duration duration;
  final FilterQuality filterQuality;

  const _KenBurnsImage({
    super.key,
    required this.image,
    required this.focus,
    required this.duration,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 1.15),
      duration: duration,
      builder: (context, scale, child) => Transform.scale(
        scale: scale,
        alignment: focus,
        child: child,
      ),
      child: Image(
        image: image,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: filterQuality,
      ),
    );
  }
}

/// Shown until the first trending image has loaded.
class _Placeholder extends StatelessWidget {
  final AppMode mode;

  const _Placeholder({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.3),
          radius: 1.0,
          colors: [mode.gradientColor, Colors.black],
        ),
      ),
    );
  }
}

/// The bottom panel's top edge: a shallow dome.
Path _domeEdge(Size size) {
  const rise = 32.0;
  return Path()
    ..moveTo(0, rise)
    ..quadraticBezierTo(size.width / 2, -rise, size.width, rise);
}

/// Clips the bottom panel to its dome shape.
class _DomeClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => _domeEdge(size)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(_DomeClipper oldClipper) => false;
}

/// The faint white edge along the dome, matching the nav bar buttons'
/// border.
class _DomeEdgePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // The glass edge catches the app's iridescent light (see
    // AppIridescence) rather than a flat faint white.
    canvas.drawPath(
      _domeEdge(size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = AppIridescence.sweep(Offset.zero & size, opacity: 0.45),
    );
  }

  @override
  bool shouldRepaint(_DomeEdgePainter oldDelegate) => false;
}
