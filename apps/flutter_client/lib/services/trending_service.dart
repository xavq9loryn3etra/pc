import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../enums/app_mode.dart';
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
        imageUrl: json['imageUrl'] as String,
        wideImageUrl: json['wideImageUrl'] as String?,
        logoUrl: json['logoUrl'] as String?,
      );
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
  static String _cacheKey(AppMode mode) => 'trending_cache_v3_${mode.name}';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  final Map<AppMode, Future<List<TrendingItem>>> _inFlight = {};

  /// The list cached by the previous launch, if any.
  Future<List<TrendingItem>> cached(AppMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(mode));
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => TrendingItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Gets the mode selector's first slide fully ready — list, background
  /// image and logo — so it isn't blank when the selector appears. Uses
  /// the same list the selector starts with: the cached one if there is
  /// one, otherwise a fresh fetch.
  Future<void> warmUp(AppMode mode, BuildContext context) async {
    var items = await cached(mode);
    if (items.isEmpty) items = await fetch(mode);
    if (items.isEmpty || !context.mounted) return;
    final size = MediaQuery.sizeOf(context);
    final first = items.first;
    await Future.wait([
      precacheImage(
        CachedNetworkImageProvider(
            first.imageFor(wide: size.width > size.height)),
        context,
        onError: (_, __) {},
      ),
      if (first.logoUrl != null)
        precacheImage(CachedNetworkImageProvider(first.logoUrl!), context,
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

  Future<List<TrendingItem>> _movies() async {
    final tmdb = TMDBService();
    final movies = (await tmdb.getTrending())
        .where((m) => m.image != null)
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
          // w500 is soft full-screen on modern phones
          imageUrl: (details[i]?.textlessPoster ?? movies[i].image!)
              .replaceFirst('/w500/', '/w780/'),
          wideImageUrl: details[i]?.backdrop ?? movies[i].backdrop,
          logoUrl: details[i]?.logoUrl,
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
