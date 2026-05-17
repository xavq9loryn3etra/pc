import 'package:dio/dio.dart';

class SubtitleTrackData {
  final String id;
  final String url;
  final String lang;

  SubtitleTrackData({
    required this.id,
    required this.url,
    required this.lang,
  });

  factory SubtitleTrackData.fromJson(Map<String, dynamic> json) {
    return SubtitleTrackData(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      lang: json['lang']?.toString() ?? '',
    );
  }

  @override
  String toString() => 'SubtitleTrackData(id: $id, url: $url, lang: $lang)';
}

class SubtitleService {
  static final SubtitleService _instance = SubtitleService._internal();
  factory SubtitleService() => _instance;
  SubtitleService._internal();

  final Dio _dio = Dio();

  /// Fetch subtitles from Stremio OpenSubtitles v3 addon
  /// For Movies: https://opensubtitles-v3.strem.io/subtitles/movie/{imdbId}.json
  /// For Series: https://opensubtitles-v3.strem.io/subtitles/series/{imdbId}:{season}:{episode}.json
  Future<List<SubtitleTrackData>> fetchSubtitles(
    String imdbId, {
    int? season,
    int? episode,
  }) async {
    try {
      final String url;
      if (season != null && episode != null) {
        url = 'https://opensubtitles-v3.strem.io/subtitles/series/$imdbId:$season:$episode.json';
      } else {
        url = 'https://opensubtitles-v3.strem.io/subtitles/movie/$imdbId.json';
      }

      final response = await _dio.get(url);
      if (response.statusCode == 200 && response.data != null) {
        final subtitlesJson = response.data['subtitles'] as List?;
        if (subtitlesJson != null) {
          return subtitlesJson
              .map((s) => SubtitleTrackData.fromJson(s as Map<String, dynamic>))
              .toList();
        }
      }
      return [];
    } catch (e) {
      print('SubtitleService Error: $e');
      return [];
    }
  }
}
