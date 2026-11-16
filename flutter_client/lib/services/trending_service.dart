import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../enums/app_mode.dart';
import 'app_mode_service.dart';
import 'books_service.dart';
import 'tmdb_service.dart';

/// One showcase item for the mode selector's background slideshow.
class TrendingItem {
  final String title;

  /// Author / artist; empty for movies.
  final String subtitle;

  /// Portrait artwork (poster / cover / album art) — fills a phone screen.
  final String imageUrl;

  /// Landscape artwork for wide screens, where available (movies only).
  final String? wideImageUrl;

  /// Title logo artwork, where available (movies only).
  final String? logoUrl;

  const TrendingItem({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    this.wideImageUrl,
    this.logoUrl,
  });

  /// The background image to use for a portrait or landscape screen.
  String imageFor({required bool wide}) =>
      wide ? (wideImageUrl ?? imageUrl) : imageUrl;

  Map<String, dynamic> toJson() => {
        'title': title,
        'subtitle': subtitle,
        'imageUrl': imageUrl,
        'wideImageUrl': wideImageUrl,
        'logoUrl': logoUrl,
      };

  factory TrendingItem.fromJson(Map<String, dynamic> json) => TrendingItem(
        title: json['title'] as String,
        subtitle: json['subtitle'] as String,
        imageUrl: original(json['imageUrl'] as String),
        wideImageUrl: _originalOrNull(json['wideImageUrl'] as String?),
        logoUrl: _originalOrNull(json['logoUrl'] as String?),
      );

  static final _tmdbSize = RegExp(r'(image\.tmdb\.org/t/p/)w\d+/');

  /// A TMDB picture's [url] at its full size. Slides saved on the device
  /// before the start screen used the originals (15 Nov 2026) still had
  /// TMDB's smaller sizes (w780 posters, w1280 backdrops), and showed
  /// softer than the same picture on the home: the start screen begins
  /// with the slides it showed last time.
  @visibleForTesting
  static String original(String url) =>
      url.replaceFirstMapped(_tmdbSize, (m) => '${m[1]}original/');

  static String? _originalOrNull(String? url) =>
      url == null ? null : original(url);
}

/// Top trending movies / albums / books for the mode selector. The last
/// result per mode is cached in SharedPreferences so the selector can show
/// it instantly on the next launch while a fresh list loads.
class TrendingService {
  static final TrendingService _instance = TrendingService._internal();
  factory TrendingService() => _instance;
  TrendingService._internal();

  static const _count = 3;
  // Bump the version when TrendingItem's shape or content changes, so a
  // stale cache from an older build isn't shown.
  static String _cacheKey(AppMode mode) => 'trending_cache_v5_${mode.name}';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  final Map<AppMode, Future<List<TrendingItem>>> _inFlight = {};

  /// The list cached by the previous launch, if any — or, the first time
  /// after an update that changed its version, the last version's (its
  /// pictures are on the device already).
  Future<List<TrendingItem>> cached(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final current = _decode(prefs.getString(_cacheKey(mode)));
    if (current.isNotEmpty) return current;
    return _decode(prefs.getString('trending_cache_v4_${mode.name}'));
  }

  static List<TrendingItem> _decode(String? raw) {
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => TrendingItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String _shownKey(AppMode mode) => 'trending_shown_v1_${mode.name}';
  static const _shownKept = 5;

  /// The slides the start screen last showed for [mode], latest first:
  /// their pictures are on the device, so they show at once, on a slow
  /// connection or none, while this week's load (see markShown).
  Future<List<TrendingItem>> shown(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(_shownKey(mode)));
  }

  /// Remembers [item] as shown on the start screen (its picture loaded).
  Future<void> markShown(AppMode mode, TrendingItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = [
        item,
        for (final i in _decode(prefs.getString(_shownKey(mode))))
          // One slide per title: an old one's picture differs.
          if (i.imageUrl != item.imageUrl && i.title != item.title) i,
      ].take(_shownKept).toList();
      await prefs.setString(
          _shownKey(mode), jsonEncode([for (final i in list) i.toJson()]));
    } catch (_) {}
  }

  /// What the start screen starts with: the slides it showed last time
  /// (on the device already), else the cached list, else a fresh one.
  Future<List<TrendingItem>> startingSlides(AppMode mode) async {
    final last = await shown(mode);
    if (last.isNotEmpty) return last;
    final previous = await cached(mode);
    if (previous.isNotEmpty) return previous;
    return fetch(mode);
  }

  /// A slide's picture: the full-size original (see _movies), decoded
  /// only as wide as covering this screen needs, with room for the slow
  /// zoom — sharp, without holding a 3000px picture in memory. A portrait
  /// poster (2:3) or a landscape backdrop (16:9) covers the screen, so it
  /// can need to be wider than the screen when it's the screen's height
  /// it has to fill. The same one for the splash's warm-up and the start
  /// screen, so what's loaded during the splash is what's shown.
  static ImageProvider slideImage(BuildContext context, TrendingItem item) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final wide = size.width > size.height;
    final aspect = wide ? 16 / 9 : 2 / 3;
    final width = (size.width > size.height * aspect
            ? size.width
            : size.height * aspect) *
        dpr *
        1.15;
    return ResizeImage.resizeIfNeeded(width.round(), null,
        CachedNetworkImageProvider(item.imageFor(wide: wide)));
  }

  /// The start screen panel's "frosted glass": the slide decoded tiny.
  static ImageProvider slideBlur(BuildContext context, TrendingItem item) {
    final size = MediaQuery.sizeOf(context);
    return ResizeImage.resizeIfNeeded(40, null,
        CachedNetworkImageProvider(item.imageFor(wide: size.width > size.height)));
  }

  /// A slide's title logo: the original, decoded at its box's size (80
  /// tall).
  static ImageProvider slideLogo(BuildContext context, String url) =>
      ResizeImage.resizeIfNeeded(
          null,
          (80 * MediaQuery.devicePixelRatioOf(context)).round(),
          CachedNetworkImageProvider(url));

  /// Gets the mode selector's first slide fully ready — list, background
  /// image and logo — so it isn't blank when the selector appears. Uses
  /// the same list the selector starts with: the cached one if there is
  /// one, otherwise a fresh fetch.
  Future<void> warmUp(AppMode mode, BuildContext context) async {
    final items = await startingSlides(mode);
    if (items.isEmpty || !context.mounted) return;
    final first = items.first;
    await Future.wait([
      precacheImage(slideImage(context, first), context, onError: (_, __) {}),
      precacheImage(slideBlur(context, first), context, onError: (_, __) {}),
      if (first.logoUrl != null)
        precacheImage(slideLogo(context, first.logoUrl!), context,
            onError: (_, __) {}),
    ]);
  }

  /// Fetches a fresh list (once per app session per mode) and caches it.
  /// Returns an empty list on failure.
  Future<List<TrendingItem>> fetch(AppMode mode) =>
      _inFlight[mode] ??= _fetchAndCache(mode);

  Future<List<TrendingItem>> _fetchAndCache(AppMode mode) async {
    try {
      final items = switch (mode) {
        AppMode.movies => await _movies(),
        AppMode.anime => await _movies(anime: true),
        AppMode.music => await _music(),
        AppMode.books => await _books(),
      };
      if (items.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _cacheKey(mode),
          jsonEncode(items.map((e) => e.toJson()).toList()),
        );
      }
      return items;
    } catch (e) {
      debugPrint('Trending fetch failed for ${mode.name}: $e');
      _inFlight.remove(mode); // allow a retry later
      return [];
    }
  }

  /// Popcorn's this week's trending (no anime, where anime is Ramen's),
  /// or with [anime], Ramen's most watched anime series.
  Future<List<TrendingItem>> _movies({bool anime = false}) async {
    final tmdb = TMDBService();
    final mode = anime ? AppMode.anime : AppMode.movies;
    final movies = (await (anime
            ? tmdb.popularAnimeSeries()
            : tmdb.getTrending()))
        .where((m) => m.image != null)
        .where((m) => AppModeService.belongsIn(mode, isAnime: m.isAnime))
        .take(_count)
        .toList();
    // Trending results don't include title logos or textless art; the
    // details call does. The logo is drawn over the slide, so the art
    // should be textless — trending's own poster / backdrop_path usually
    // has the title printed on it too.
    final details = await Future.wait(movies.map((m) => tmdb
        .getDetails(m.id, type: m.type)
        .catchError((_) => null)));
    return [
      for (var i = 0; i < movies.length; i++)
        TrendingItem(
          title: movies[i].title,
          subtitle: '',
          // The originals (full size): w780 posters and w1280 backdrops
          // were soft stretched across a phone's or a monitor's whole
          // screen. Decoded at the screen's size (see ModeSelectorScreen).
          imageUrl: details[i]?.textlessPosterHighRes ??
              movies[i].image!.replaceFirst('/w500/', '/original/'),
          wideImageUrl: details[i]?.backdropHighRes ??
              movies[i].backdropHighRes,
          logoUrl: details[i]?.logoHighRes,
        ),
    ];
  }

  Future<List<TrendingItem>> _books() async {
    final books = await BooksService().getTrendingBooks();
    return [
      for (final b in books.where((b) => b.coverUrl != null).take(_count))
        TrendingItem(
          title: b.title,
          subtitle: 'by ${b.author}',
          imageUrl: b.coverUrl!,
        ),
    ];
  }

  // Apple's public charts feed — no API key needed.
  Future<List<TrendingItem>> _music() async {
    final response = await _dio.get(
      'https://rss.applemarketingtools.com/api/v2/us/music/most-played/10/albums.json',
    );
    final data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    final results = (data['feed']['results'] as List).cast<Map>();
    return [
      for (final r in results.take(_count))
        TrendingItem(
          title: r['name'] as String,
          subtitle: r['artistName'] as String,
          // artworkUrl100 ends in /100x100bb.jpg; the CDN scales on request
          imageUrl: (r['artworkUrl100'] as String)
              .replaceFirst(RegExp(r'/\d+x\d+bb\.'), '/1000x1000bb.'),
        ),
    ];
  }
}
