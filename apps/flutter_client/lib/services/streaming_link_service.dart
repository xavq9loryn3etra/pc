import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One streaming service's direct-link recipe: the Wikidata properties that
/// hold its title IDs, and the official URL format for each (from the
/// property's own "formatter URL", P1630).
class _ServiceLinks {
  final List<String> movieProps;
  final List<String> tvProps;
  final String movieUrl; // `$1` = the ID
  final String tvUrl;

  const _ServiceLinks({
    required this.movieProps,
    required this.tvProps,
    required this.movieUrl,
    required this.tvUrl,
  });

  const _ServiceLinks.same(List<String> props, String url)
      : this(movieProps: props, tvProps: props, movieUrl: url, tvUrl: url);
}

/// Resolves a direct link to a title on a streaming service — the kind the
/// service's own app opens (e.g. netflix.com/title/80994082) — from
/// Wikidata's per-service ID properties (CC0 open data), starting from the
/// Wikidata ID that TMDB's external_ids provide.
///
/// Search URLs and TMDB's watch page don't open in the services' apps, so
/// without this, taps landed in the browser.
class StreamingLinkService {
  static final StreamingLinkService _instance =
      StreamingLinkService._internal();
  factory StreamingLinkService() => _instance;
  StreamingLinkService._internal();

  static const _primeUrl = r'https://www.primevideo.com/detail/$1';

  // Keyed by TMDB watch-provider ID.
  static const Map<int, _ServiceLinks> _services = {
    // Netflix, Netflix Standard with Ads
    8: _ServiceLinks.same(['P1874'], r'https://www.netflix.com/title/$1'),
    1796: _ServiceLinks.same(['P1874'], r'https://www.netflix.com/title/$1'),
    // Amazon Prime Video (+ other regions, with Ads). Wikidata mostly has
    // the Amazon ID (P8055); primevideo.com/detail takes it too and opens
    // the Prime Video app rather than Amazon's shopping app.
    9: _ServiceLinks.same(['P14440', 'P8055'], _primeUrl),
    119: _ServiceLinks.same(['P14440', 'P8055'], _primeUrl),
    2100: _ServiceLinks.same(['P14440', 'P8055'], _primeUrl),
    // Disney Plus
    337: _ServiceLinks(
      movieProps: ['P7595'],
      tvProps: ['P7596'],
      movieUrl: r'https://www.disneyplus.com/movies/wd/$1',
      tvUrl: r'https://www.disneyplus.com/series/wp/$1',
    ),
    // Apple TV
    350: _ServiceLinks(
      movieProps: ['P9586'],
      tvProps: ['P9751'],
      movieUrl: r'https://tv.apple.com/movie/$1',
      tvUrl: r'https://tv.apple.com/show/$1',
    ),
    // Hulu
    15: _ServiceLinks(
      movieProps: ['P6466'],
      tvProps: ['P6467'],
      movieUrl: r'https://www.hulu.com/movie/$1',
      tvUrl: r'https://www.hulu.com/series/$1',
    ),
    // HBO Max (values include their path, e.g. "show/<uuid>")
    1899: _ServiceLinks.same(['P8298'], r'https://play.hbomax.com/$1'),
    384: _ServiceLinks.same(['P8298'], r'https://play.hbomax.com/$1'),
    // Crunchyroll
    283: _ServiceLinks.same(['P11330'], r'https://crunchyroll.com/series/$1'),
    // JioHotstar
    2336: _ServiceLinks.same(['P11049'], r'https://hotstar.com/$1'),
    // Paramount Plus
    531: _ServiceLinks.same(
        ['P13147'], r'https://www.paramountplus.com/shows/video/$1/'),
    // Sony Liv
    237: _ServiceLinks.same(['P9465'], r'https://www.sonyliv.com/shows/$1'),
    // Peacock Premium, Premium Plus
    386: _ServiceLinks.same(['P11815'], r'https://www.peacocktv.com/stream-$1'),
    387: _ServiceLinks.same(['P11815'], r'https://www.peacocktv.com/stream-$1'),
  };

  static final Set<String> _allProps = {
    for (final s in _services.values) ...s.movieProps,
    for (final s in _services.values) ...s.tvProps,
  };

  static const _prefsPrefix = 'wd_streaming_ids_';

  // Wikidata asks API clients to identify themselves with a descriptive
  // User-Agent (app name + contact URL).
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    headers: {
      'User-Agent': 'PopcornApp/2.0 (https://github.com/xavq9loryn3etra/pc)',
    },
  ));

  final Map<String, Future<Map<String, String>?>> _inFlight = {};

  /// Whether [providerId] has a direct-link recipe at all.
  bool supports(int providerId) => _services.containsKey(providerId);

  /// A direct link to the title on [providerId], or null when Wikidata has
  /// no ID for it there (or the lookup fails) — callers fall back.
  Future<String?> directUrl({
    required String wikidataId,
    required int providerId,
    required bool isTv,
  }) async {
    final service = _services[providerId];
    if (service == null) return null;
    final ids = await _idsFor(wikidataId);
    if (ids == null) return null;
    for (final prop in isTv ? service.tvProps : service.movieProps) {
      final id = ids[prop];
      if (id != null) {
        return (isTv ? service.tvUrl : service.movieUrl)
            .replaceAll(r'$1', id);
      }
    }
    return null;
  }

  /// Fetches (once, then cached on-device) every streaming ID Wikidata has
  /// for [wikidataId]. Prefetching this early makes taps instant.
  Future<Map<String, String>?> _idsFor(String wikidataId) {
    return _inFlight[wikidataId] ??= _lookup(wikidataId)
      ..whenComplete(() => _inFlight.remove(wikidataId));
  }

  /// Starts the lookup in the background (no-op if cached or in flight).
  void prefetch(String wikidataId) => _idsFor(wikidataId);

  Future<Map<String, String>?> _lookup(String wikidataId) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('$_prefsPrefix$wikidataId');
      if (cached != null) {
        return Map<String, String>.from(jsonDecode(cached) as Map);
      }
    } catch (_) {}

    try {
      final response = await _dio.get(
        'https://www.wikidata.org/wiki/Special:EntityData/$wikidataId.json',
      );
      final entities =
          response.data is Map ? response.data['entities'] : null;
      final entity = entities is Map && entities.isNotEmpty
          ? entities.values.first
          : null;
      final claims = entity is Map ? entity['claims'] : null;
      final ids = <String, String>{};
      if (claims is Map) {
        for (final prop in _allProps) {
          final statements = claims[prop];
          if (statements is! List || statements.isEmpty) continue;
          final value = statements.first['mainsnak']?['datavalue']?['value'];
          if (value is String && value.isNotEmpty) ids[prop] = value;
        }
      }
      try {
        await prefs?.setString('$_prefsPrefix$wikidataId', jsonEncode(ids));
      } catch (_) {}
      return ids;
    } catch (e) {
      // Network error: don't cache, so a later tap can retry.
      debugPrint('Streaming ID lookup failed for $wikidataId: $e');
      return null;
    }
  }
}
