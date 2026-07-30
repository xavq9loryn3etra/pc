import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/movie.dart';

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

  Future<Movie?> getDetails(String id, {String? type}) async {
    final key = 'details_${id}_$type';
    if (_cache.containsKey(key) && _cache[key]!.isValid(30)) {
      return _cache[key]!.data as Movie;
    }

    // 1. Try Movie (unless explicitly TV)
    if (type != 'tv') {
      try {
        final response = await _dio.get(
          '$_baseUrl/movie/$id',
          queryParameters: {
            'api_key': _apiKey,
            'append_to_response': 'credits,videos,images,release_dates,external_ids',
            'include_image_language': 'en,null',
          },
        );
        final movie = _formatMovieDetails(response.data, isTv: false);
        _cache[key] = _CacheEntry(movie);
        return movie;
      } catch (e) {
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
              'credits,videos,images,content_ratings,external_ids',
          'include_image_language': 'en,null',
        },
      );
      final movie = _formatMovieDetails(response.data, isTv: true);
      _cache[key] = _CacheEntry(movie);
      return movie;
    } catch (e) {
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

  Movie _formatMovieDetails(Map<String, dynamic> m, {required bool isTv}) {
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
    }

    // Genres
    final genres =
        (m['genres'] as List?)?.map((g) => g['name'].toString()).toList();

    // Logo
    String? logoUrl;
    final images = m['images'];
    if (images != null &&
        images['logos'] != null &&
        (images['logos'] as List).isNotEmpty) {
      final logos = images['logos'] as List;
      final enLogo = logos.firstWhere(
        (l) => l['iso_639_1'] == 'en',
        orElse: () => logos.first,
      );
      if (enLogo != null) logoUrl = '$_imageBase${enLogo['file_path']}';
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

    return Movie(
      id: base.id,
      title: base.title,
      year: base.year,
      image: base.image,
      backdrop: base.backdrop,
      rating: base.rating,
      voteCount: base.voteCount,
      description: base.description,
      type: isTv ? 'tv' : 'movie',
      inCinemas: base.inCinemas,
      releaseDateRaw: base.releaseDateRaw,
      director: director,
      cast: cast,
      genres: genres,
      logoUrl: logoUrl,
      runtime: runtime,
      certification: certification,
      mpaa: isTv ? certification : (m['adult'] == true ? 'R' : certification),
      seasons: seasons,
      trailerUrl: trailerUrl,
      imdbId: imdbId,
    );
  }

  Future<List<Episode>> getSeasonDetails(String tvId, int seasonNumber) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tv/$tvId/season/$seasonNumber',
        queryParameters: {'api_key': _apiKey},
      );
      return (response.data['episodes'] as List)
          .map(
            (e) => Episode(
              id: e['id'],
              episodeNumber: e['episode_number'],
              name: e['name'],
              overview: e['overview'],
              stillPath: e['still_path'] != null
                  ? '$_imageBase${e['still_path']}'
                  : null,
              airDate: e['air_date'],
              voteAverage: (e['vote_average'] ?? 0).toDouble(),
            ),
          )
          .toList();
    } catch (e) {
      print('TMDB Season Details Error: $e');
      return [];
    }
  }

  Future<String?> getTrailer(String id, {bool isTv = false}) async {
    // Logic to fetch videos similar to TS
    // ...
    return null; // Stub for now
  }
}
