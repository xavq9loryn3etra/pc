import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/movie.dart';
import 'saved_movies_service.dart';
import 'streaming_link_service.dart';

// ... imports

class _CacheEntry {
  final dynamic data;
  final DateTime timestamp;
  _CacheEntry(this.data) : timestamp = DateTime.now();
  bool isValid(int ttlMinutes) =>
      DateTime.now().difference(timestamp).inMinutes < ttlMinutes;
}

class TMDBService {
  static final TMDBService _instance = TMDBService._internal();
  factory TMDBService() => _instance;
  TMDBService._internal();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
  final String _baseUrl = 'https://api.themoviedb.org/3';
  final String _imageBase = 'https://image.tmdb.org/t/p/w500';
  final String _backdropBase = 'https://image.tmdb.org/t/p/w1280';

  // Simple in-memory cache
  final Map<String, _CacheEntry> _cache = {};

  // Helper to get API Key
  String get _apiKey => dotenv.env['TMDB_API_KEY'] ?? '';

  void clearCache() => _cache.clear();

  Future<List<Movie>> getTrending() async {
    const key = 'trending';
    if (_cache.containsKey(key) && _cache[key]!.isValid(10)) {
      return _cache[key]!.data as List<Movie>;
    }

    try {
      final response = await _dio.get(
        '$_baseUrl/trending/all/week',
        queryParameters: {'api_key': _apiKey},
      );
      final movies = (response.data['results'] as List)
          .map((m) => _formatMovie(m))
          .whereType<Movie>()
          .toList();

      _cache[key] = _CacheEntry(movies);
      return movies;
    } catch (e) {
      print('TMDB Trending Error: $e');
      return [];
    }
  }

  Future<List<Movie>> search(String query) async {
    final key = 'search_${query.toLowerCase()}';
    if (_cache.containsKey(key) && _cache[key]!.isValid(5)) {
      return _cache[key]!.data as List<Movie>;
    }
    try {
      final response = await _dio.get(
        '$_baseUrl/search/multi',
        queryParameters: {
          'api_key': _apiKey,
          'query': query,
          'include_adult': false,
        },
      );
      final results = (response.data['results'] as List)
          .where((r) => r['media_type'] == 'movie' || r['media_type'] == 'tv')
          .toList();
      final movies =
          results.map((m) => _formatMovie(m)).whereType<Movie>().toList();
      _cache[key] = _CacheEntry(movies);
      return movies;
    } catch (e) {
      print('TMDB Search Error: $e');
      return [];
    }
  }

  Future<List<Movie>> searchMulti(String query) async {
    if (query.isEmpty) return [];
    // Short TTL — search results go stale quickly, but this still avoids
    // re-hitting the network for the same query while the user is typing
    // and pausing, or retyping something they already searched for.
    final key = 'searchMulti_${query.toLowerCase()}';
    if (_cache.containsKey(key) && _cache[key]!.isValid(5)) {
      return _cache[key]!.data as List<Movie>;
    }
    try {
      final response = await _dio.get(
        '$_baseUrl/search/multi',
        queryParameters: {
          'api_key': _apiKey,
          'query': query,
          'include_adult': false,
        },
      );

      // Filter out people, only Movies and TV (like Electron app does)
      final results = (response.data['results'] as List)
          .where((r) => r['media_type'] == 'movie' || r['media_type'] == 'tv')
          .toList();

      final movies =
          results.map((m) => _formatMovie(m)).whereType<Movie>().toList();
      _cache[key] = _CacheEntry(movies);
      return movies;
    } catch (e) {
      print('TMDB Search Error: $e');
      return [];
    }
  }

  // Original languages written in the Latin alphabet, whose logos read fine
  // alongside the app's English UI (e.g. Lupin's French "LUPIN").
  static const _latinScriptLanguages = {
    'fr', 'es', 'de', 'it', 'pt', 'nl', 'sv', 'da', 'no', 'nb', 'nn', 'fi',
    'is', 'pl', 'cs', 'sk', 'sl', 'hr', 'bs', 'sr', 'hu', 'ro', 'tr', 'et',
    'lv', 'lt', 'ga', 'cy', 'ca', 'eu', 'gl', 'id', 'ms', 'tl', 'vi', 'sq',
    'af', 'sw', 'mt', 'lb',
  };

  /// Details are fetched with English / language-neutral images only, so a
  /// non-English production with no English-tagged logo (e.g. Lupin: 34
  /// logos, none English) fell back to a plain text title. When that
  /// happens and its original language uses the Latin alphabet, fetch the
  /// original-language logos and add them to [data]'s images. Other
  /// scripts (Japanese, Korean, …) keep the English text title.
  Future<void> _addOriginalLanguageLogos(
    dynamic data,
    String type,
    String id,
    CancelToken? cancelToken,
  ) async {
    if (data is! Map) return;
    final images = data['images'];
    final logos = images is Map ? images['logos'] : null;
    if (logos is List && logos.isNotEmpty) return;
    final language = data['original_language'];
    if (language is! String || !_latinScriptLanguages.contains(language)) {
      return;
    }
    try {
      final response = await _dio.get(
        '$_baseUrl/$type/$id/images',
        queryParameters: {
          'api_key': _apiKey,
          'include_image_language': language,
        },
        cancelToken: cancelToken,
      );
      final found = response.data is Map ? response.data['logos'] : null;
      if (found is List && found.isNotEmpty) {
        data['images'] = {
          ...(images is Map ? images : const {}),
          'logos': found,
        };
      }
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      // No logo is fine — the text title is shown instead.
    }
  }

  Future<Movie?> getDetails(String id,
      {String? type, CancelToken? cancelToken}) async {
    final key = 'details_${id}_$type';
    if (_cache.containsKey(key) && _cache[key]!.isValid(30)) {
      return _cache[key]!.data as Movie;
    }
    // Resolved alongside the details request (cached after the first).
    final watchCountry = _watchCountry();

    // 1. Try Movie (unless explicitly TV)
    if (type != 'tv') {
      try {
        final response = await _dio.get(
          '$_baseUrl/movie/$id',
          queryParameters: {
            'api_key': _apiKey,
            'append_to_response':
                'credits,videos,images,release_dates,external_ids,watch/providers',
            'include_image_language': 'en,null',
          },
          cancelToken: cancelToken,
        );
        await _addOriginalLanguageLogos(response.data, 'movie', id, cancelToken);
        final movie = _formatMovieDetails(response.data,
            isTv: false, watchCountry: await watchCountry);
        _cache[key] = _CacheEntry(movie);
        return movie;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        if (type == 'movie') return null;
      }
    }

    // 2. Try TV
    try {
      final response = await _dio.get(
        '$_baseUrl/tv/$id',
        queryParameters: {
          'api_key': _apiKey,
          'append_to_response':
              'credits,videos,images,content_ratings,external_ids,watch/providers',
          'include_image_language': 'en,null',
        },
        cancelToken: cancelToken,
      );
      await _addOriginalLanguageLogos(response.data, 'tv', id, cancelToken);
      final split = await _splitSeasons(id, response.data['seasons']);
      if (split != null) {
        response.data['seasons'] = [
          ...(response.data['seasons'] as List)
              .where((s) => s['season_number'] == 0),
          for (final e in split.entries)
            {
              'id': -e.key,
              'season_number': e.key,
              'episode_count': e.value.length,
            },
        ];
      }
      final movie = _formatMovieDetails(response.data,
          isTv: true, watchCountry: await watchCountry);
      _cache[key] = _CacheEntry(movie);
      return movie;
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      print('TMDB Details Error: $e');
      return null;
    }
  }

  Movie? _formatMovie(Map<String, dynamic> m) {
    // Only filter out if BOTH images are missing (need at least one)
    if (m['poster_path'] == null && m['backdrop_path'] == null) return null;

    bool inCinemas = false;
    final isTv = m['media_type'] == 'tv' || m['first_air_date'] != null;

    if (!isTv) {
      final releaseDate = m['release_date'];
      if (releaseDate != null && releaseDate.toString().isNotEmpty) {
        try {
          final release = DateTime.parse(releaseDate);
          final now = DateTime.now();
          final diff = now.difference(release).inDays;
          if (release.isAfter(now) || (diff >= 0 && diff < 45)) {
            inCinemas = true;
          }
        } catch (_) {}
      }
    }

    var dateStr =
        (m['release_date'] ?? m['first_air_date'] ?? '0000').toString();
    if (dateStr.isEmpty) dateStr = '0000';
    final yearStr = dateStr.length >= 4 ? dateStr.substring(0, 4) : '0000';

    return Movie(
      id: m['id'].toString(),
      title: m['title'] ?? m['name'] ?? 'Unknown',
      year: int.tryParse(yearStr) ?? 0,
      image: m['poster_path'] != null ? '$_imageBase${m['poster_path']}' : null,
      backdrop: m['backdrop_path'] != null
          ? '$_backdropBase${m['backdrop_path']}'
          : null,
      rating: (m['vote_average'] ?? 0).toStringAsFixed(1),
      voteCount: m['vote_count'] ?? 0,
      description: m['overview'] ?? '',
      type: m['media_type'] ?? (isTv ? 'tv' : 'movie'),
      inCinemas: inCinemas,
      releaseDateRaw: (m['release_date'] ?? m['first_air_date'])?.toString(),
    );
  }

  Movie _formatMovieDetails(Map<String, dynamic> m,
      {required bool isTv, required String watchCountry}) {
    // Basic formatting
    final base = _formatMovie(m);
    if (base == null) throw Exception('Failed to format base movie');

    // Extract Certification
    String certification = isTv ? 'TV-14' : 'PG-13';
    if (!isTv) {
      final releaseDates = m['release_dates']?['results'] as List?;
      final usRelease = releaseDates?.firstWhere(
        (r) => r['iso_3166_1'] == 'US',
        orElse: () => null,
      );
      if (usRelease != null) {
        final certCallback = (usRelease['release_dates'] as List?)?.firstWhere(
          (d) => d['certification'] != '',
          orElse: () => null,
        );
        if (certCallback != null) certification = certCallback['certification'];
      }
    } else {
      final ratings = m['content_ratings']?['results'] as List?;
      final usRating = ratings?.firstWhere(
        (r) => r['iso_3166_1'] == 'US',
        orElse: () => null,
      );
      if (usRating != null) certification = usRating['rating'];
    }

    // Credits
    final credits = m['credits'];
    String? director;
    List<String> cast = [];
    List<CastMember> castMembers = [];
    if (credits != null) {
      director = (credits['crew'] as List?)?.firstWhere(
        (c) => c['job'] == 'Director',
        orElse: () => null,
      )?['name'];
      cast = (credits['cast'] as List?)
              ?.take(5)
              .map((c) => c['name'].toString())
              .toList() ??
          [];
      castMembers = (credits['cast'] as List? ?? const [])
          .whereType<Map>()
          .where((c) => c['name'] is String)
          .take(15)
          .map((c) {
        final character = c['character'];
        final profile = c['profile_path'];
        return CastMember(
          name: c['name'] as String,
          character:
              character is String && character.isNotEmpty ? character : null,
          profileUrl: profile is String
              ? 'https://image.tmdb.org/t/p/w185$profile'
              : null,
        );
      }).toList();
    }

    // Genres
    final genres =
        (m['genres'] as List?)?.map((g) => g['name'].toString()).toList();

    // Logo
    String? logoUrl;
    double? logoAspectRatio;
    final images = m['images'];
    if (images != null &&
        images['logos'] != null &&
        (images['logos'] as List).isNotEmpty) {
      final logos = images['logos'] as List;
      final enLogo = logos.firstWhere(
        (l) => l['iso_639_1'] == 'en',
        orElse: () => logos.first,
      );
      if (enLogo != null) {
        // TMDB also serves every SVG logo as a rasterized PNG (same path,
        // .png extension) — use that. flutter_svg ignores <style> CSS, which
        // Illustrator-exported SVGs often use for fills (e.g. Stranger
        // Things' `.st0{fill:#EA2A2D}`), so those logos rendered solid
        // black. PNG also goes through the image cache and the details
        // screen's header preload, which SvgPicture doesn't.
        String path = enLogo['file_path'];
        if (path.toLowerCase().endsWith('.svg')) {
          path = '${path.substring(0, path.length - 4)}.png';
        }
        logoUrl = '$_imageBase$path';
        final ratio = enLogo['aspect_ratio'];
        if (ratio is num && ratio > 0) logoAspectRatio = ratio.toDouble();
      }
    }

    // Backdrop — prefer the best-rated entry from images.backdrops (already
    // filtered to en/null language by include_image_language, and
    // pre-sorted by vote_average) over the bare backdrop_path field, which
    // is just TMDB's own arbitrary "primary" pick and isn't language-aware —
    // foreign titles in particular can default to a backdrop with
    // non-English text baked in. Among those, textless ones (no language)
    // come first: an `en` backdrop usually has the title printed on it,
    // which doubled up with the logo drawn over the hero (e.g. Parasite).
    String? backdrop = base.backdrop;
    final backdrops = images is Map ? images['backdrops'] : null;
    if (backdrops is List && backdrops.isNotEmpty) {
      final candidates = backdrops.whereType<Map>();
      final best = candidates.firstWhere(
        (b) => b['iso_639_1'] == null,
        orElse: () => candidates.first,
      );
      if (best['file_path'] != null) {
        backdrop = '$_backdropBase${best['file_path']}';
      }
    }

    // Textless poster — same idea, for the mode selector's portrait slides,
    // which draw the logo over the poster. No fallback to a poster with
    // text: callers use `image` for that.
    String? textlessPoster;
    final posters = images is Map ? images['posters'] : null;
    if (posters is List) {
      for (final p in posters.whereType<Map>()) {
        if (p['iso_639_1'] == null && p['file_path'] is String) {
          textlessPoster = '$_imageBase${p['file_path']}';
          break;
        }
      }
    }

    // Runtime
    String? runtime;
    if (isTv) {
      final runtimes = m['episode_run_time'] as List?;
      if (runtimes != null && runtimes.isNotEmpty) runtime = '${runtimes[0]}m';
    } else {
      final rt = m['runtime'] as int?;
      if (rt != null) runtime = '${rt ~/ 60}h ${rt % 60}m';
    }

    // Seasons
    List<Season>? seasons;
    if (isTv && m['seasons'] != null) {
      seasons = (m['seasons'] as List).map((s) => Season.fromJson(s)).toList();
    }

    // Trailer
    String? trailerUrl;
    final videos = m['videos'];
    if (videos != null && videos['results'] != null) {
      final results = videos['results'] as List;
      final trailer = results.firstWhere(
        (v) => v['site'] == 'YouTube' && v['type'] == 'Trailer',
        orElse: () => null,
      );
      if (trailer != null) {
        trailerUrl = 'https://www.youtube.com/watch?v=${trailer['key']}';
      }
    }

    // IMDB ID
    String? imdbId;
    if (m['imdb_id'] != null && m['imdb_id'].toString().isNotEmpty) {
      imdbId = m['imdb_id'];
    } else if (m['external_ids'] != null) {
      imdbId = m['external_ids']['imdb_id'];
    }

    // Wikidata ID — the key for looking up the Netflix title ID.
    final externalIds = m['external_ids'];
    final wikidata = externalIds is Map ? externalIds['wikidata_id'] : null;
    final String? wikidataId =
        wikidata is String && wikidata.isNotEmpty ? wikidata : null;

    final streamingProviders =
        _pickStreamingProviders(m['watch/providers'], watchCountry);

    return Movie(
      id: base.id,
      title: base.title,
      year: base.year,
      image: base.image,
      backdrop: backdrop,
      textlessPoster: textlessPoster,
      rating: base.rating,
      voteCount: base.voteCount,
      description: base.description,
      type: isTv ? 'tv' : 'movie',
      inCinemas: base.inCinemas,
      releaseDateRaw: base.releaseDateRaw,
      lastAirYear: isTv
          ? int.tryParse('${m['last_air_date'] ?? ''}'.split('-').first)
          : null,
      director: director,
      cast: cast,
      castMembers: castMembers,
      genres: genres,
      logoUrl: logoUrl,
      logoAspectRatio: logoAspectRatio,
      runtime: runtime,
      certification: certification,
      mpaa: isTv ? certification : (m['adult'] == true ? 'R' : certification),
      seasons: seasons,
      trailerUrl: trailerUrl,
      imdbId: imdbId,
      wikidataId: wikidataId,
      streamingProvider: streamingProviders.firstOrNull,
      otherStreamingProviders: streamingProviders.skip(1).toList(),
    );
  }

  // TMDB provider IDs → the service's public search URL, which Android App
  // Links / iOS Universal Links open in the service's app when installed.
  // Only services whose search URL format is known; others fall back to
  // TMDB's own watch page for the title.
  static const _netflixIds = {8, 1796}; // Netflix, Netflix Standard with Ads

  /// The subscription ("flatrate") services streaming a title in [country]
  /// (see _watchCountry), the main one first — Netflix when it's one of
  /// them, otherwise TMDB's top-ranked one — then the rest in TMDB's
  /// order. Only services StreamingLinkService can open directly in their
  /// app are considered: the buttons never fall back to TMDB, a search
  /// page or any other website. One entry per service: plan variants
  /// ("… with Ads", other regions' listings) collapse into the first.
  List<StreamingProvider> _pickStreamingProviders(
      dynamic watchProviders, String country) {
    if (watchProviders is! Map) return const [];
    final results = watchProviders['results'];
    if (results is! Map) return const [];
    final regional = results[country];
    if (regional is! Map) return const [];
    final flatrate = regional['flatrate'];
    if (flatrate is! List || flatrate.isEmpty) return const [];

    // Already sorted by TMDB's display_priority.
    final providers = <StreamingProvider>[];
    for (final p in flatrate.whereType<Map>()) {
      final id = p['provider_id'];
      final name = p['provider_name'];
      if (id is! int ||
          name is! String ||
          !StreamingLinkService().supports(id)) {
        continue;
      }
      // "Netflix Standard with Ads" → "Netflix", "… with Ads" → "…".
      final label = _netflixIds.contains(id)
          ? 'Netflix'
          : name.replaceFirst(
              RegExp(r'\s+(Standard\s+)?with\s+Ads$', caseSensitive: false),
              '');
      if (providers.any((existing) => existing.name == label)) continue;
      final logo = p['logo_path'];
      providers.add(StreamingProvider(
        id: id,
        name: label,
        logoUrl: logo is String ? 'https://image.tmdb.org/t/p/w92$logo' : null,
      ));
    }

    final netflix = providers.indexWhere((p) => _netflixIds.contains(p.id));
    if (netflix > 0) providers.insert(0, providers.removeAt(netflix));
    return providers;
  }

  // Countries TMDB has watch-provider data for (JustWatch's coverage),
  // fetched once per session.
  Future<Set<String>?>? _watchRegions;

  Future<Set<String>?> _loadWatchRegions() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/watch/providers/regions',
        queryParameters: {'api_key': _apiKey},
      );
      final results = response.data is Map ? response.data['results'] : null;
      if (results is! List) return null;
      return {
        for (final r in results.whereType<Map>())
          if (r['iso_3166_1'] is String) r['iso_3166_1'] as String,
      };
    } catch (e) {
      print('TMDB Watch Regions Error: $e');
      return null;
    }
  }

  /// The country whose streaming catalogue the provider button uses: the
  /// device's Region setting when TMDB covers it, otherwise the first
  /// covered country of the language preferences, else US.
  ///
  /// TMDB has no data at all for some countries (e.g. Sri Lanka), so iOS —
  /// which reports the real Region setting — found no provider for any
  /// title there, while Android, whose region follows the language
  /// ("English (US)" → US), did.
  Future<String> _watchCountry() async {
    final candidates = _countryCandidates();
    final regions = await (_watchRegions ??= _loadWatchRegions());
    if (regions == null) {
      _watchRegions = null; // retry on the next details fetch
      return candidates.first;
    }
    return candidates.firstWhere(regions.contains,
        orElse: () => candidates.first);
  }

  /// The device's countries, most specific first: the Region setting, then
  /// the language preferences' countries, then US.
  ///
  /// PlatformDispatcher's locales are the *language* preferences: on iOS
  /// their region follows the language variant ("English (US)" → US) or is
  /// missing, not where the user is. Platform.localeName is the current
  /// locale (NSLocale.current on iOS), which carries the Region setting —
  /// e.g. "en_LK", or "en_US@rg=lkzzzz" when language and region differ.
  static List<String> _countryCandidates() {
    final candidates = <String>{};
    final name = Platform.localeName;
    final rg = RegExp(r'rg=([a-zA-Z]{2})').firstMatch(name);
    if (rg != null) candidates.add(rg.group(1)!.toUpperCase());
    // "en_LK", "zh_Hans_CN", "en_US.UTF-8": the 2-letter subtag after the
    // language.
    final subtags = name.split('@').first.split(RegExp(r'[-_.]'));
    for (final subtag in subtags.skip(1)) {
      if (RegExp(r'^[a-zA-Z]{2}$').hasMatch(subtag)) {
        candidates.add(subtag.toUpperCase());
        break;
      }
    }
    for (final locale in PlatformDispatcher.instance.locales) {
      final code = locale.countryCode;
      if (code != null && code.isNotEmpty) candidates.add(code.toUpperCase());
    }
    candidates.add('US');
    return candidates.toList();
  }

  /// A season's episodes — with, for any already played, the length of the
  /// copy actually played in place of TMDB's runtime (see
  /// SavedMoviesService.saveEpisodeLength).
  Future<List<Episode>> getSeasonDetails(String tvId, int seasonNumber) async {
    final history = SavedMoviesService();
    return [
      for (final e in await _seasonEpisodes(tvId, seasonNumber))
        switch (history.getEpisodeMinutes(tvId, seasonNumber, e.episodeNumber)) {
          final minutes? => e.withRuntime(minutes),
          null => e,
        },
    ];
  }

  Future<List<Episode>> _seasonEpisodes(String tvId, int seasonNumber) async {
    final key = 'season_${tvId}_$seasonNumber';
    if (_cache.containsKey(key) && _cache[key]!.isValid(30)) {
      return _cache[key]!.data as List<Episode>;
    }
    try {
      if (seasonNumber > 0) {
        final split = await _splitSeasons(tvId);
        if (split != null) {
          final episodes = split[seasonNumber] ?? const <Episode>[];
          _cache[key] = _CacheEntry(episodes);
          return episodes;
        }
      }
      final response = await _dio.get(
        '$_baseUrl/tv/$tvId/season/$seasonNumber',
        queryParameters: {'api_key': _apiKey},
      );
      final episodes = (response.data['episodes'] as List)
          .map((e) => _episodeFromJson(e, e['episode_number']))
          .toList();
      _cache[key] = _CacheEntry(episodes);
      return episodes;
    } catch (e) {
      print('TMDB Season Details Error: $e');
      return [];
    }
  }

  Episode _episodeFromJson(Map<String, dynamic> e, int episodeNumber) =>
      Episode(
        id: e['id'],
        episodeNumber: episodeNumber,
        name: e['name'],
        overview: e['overview'],
        stillPath:
            e['still_path'] != null ? '$_imageBase${e['still_path']}' : null,
        airDate: e['air_date'],
        voteAverage: (e['vote_average'] ?? 0).toDouble(),
        runtime: e['runtime'] is int ? e['runtime'] as int : null,
      );

  // Per show: its seasons from TMDB's "Seasons" episode group, or null when
  // TMDB's own seasons are used. See _loadSplitSeasons.
  final Map<String, Future<Map<int, List<Episode>>?>> _splitSeasonsByShow = {};

  /// Some shows — mostly anime — are one long "Season 1" on TMDB (absolute
  /// numbering), while Torrentio, like IMDb, splits them into real seasons:
  /// TMDB's S1E25 is Torrentio's S2E1, so nothing past the first season
  /// could be found. For those, TMDB usually also has a "Seasons" episode
  /// group with the real split; this returns it as season number →
  /// episodes, renumbered from 1 within each season. [tmdbSeasons] is the
  /// show's TMDB season list when the caller already has it.
  Future<Map<int, List<Episode>>?> _splitSeasons(String tvId,
      [List? tmdbSeasons]) {
    return _splitSeasonsByShow[tvId] ??=
        _loadSplitSeasons(tvId, tmdbSeasons).catchError((Object e) {
      // Falls back to TMDB's own seasons; retried next time instead of
      // being remembered.
      print('TMDB Episode Group Error: $e');
      _splitSeasonsByShow.remove(tvId);
      return null;
    });
  }

  Future<Map<int, List<Episode>>?> _loadSplitSeasons(
      String tvId, List? tmdbSeasons) async {
    tmdbSeasons ??= (await _dio.get(
      '$_baseUrl/tv/$tvId',
      queryParameters: {'api_key': _apiKey},
    ))
        .data['seasons'] as List?;
    final regular =
        (tmdbSeasons ?? const []).where((s) => (s['season_number'] ?? 0) > 0);
    if (regular.length != 1) return null;

    final groups = (await _dio.get(
      '$_baseUrl/tv/$tvId/episode_groups',
      queryParameters: {'api_key': _apiKey},
    ))
        .data['results'] as List?;
    // Type 6 is TMDB's "production" grouping, which is where these splits
    // live.
    final seasonsGroup = groups?.firstWhere(
      (g) => g['type'] == 6 && g['name'] == 'Seasons',
      orElse: () => null,
    );
    if (seasonsGroup == null) return null;

    final detail = (await _dio.get(
      '$_baseUrl/tv/episode_group/${seasonsGroup['id']}',
      queryParameters: {'api_key': _apiKey},
    ))
        .data['groups'] as List?;
    final parts = (detail ?? const [])
        .where((g) =>
            (g['episodes'] as List?)?.isNotEmpty == true &&
            // Specials stay TMDB's own season 0.
            (g['episodes'] as List).every((e) => e['season_number'] != 0))
        .toList()
      ..sort((a, b) => (a['order'] as int).compareTo(b['order'] as int));
    if (parts.length < 2) return null;

    return {
      for (var i = 0; i < parts.length; i++)
        i + 1: [
          for (final (j, e) in (parts[i]['episodes'] as List).indexed)
            _episodeFromJson(e, j + 1),
        ],
    };
  }

  Future<String?> getTrailer(String id, {bool isTv = false}) async {
    // Logic to fetch videos similar to TS
    // ...
    return null; // Stub for now
  }
}
