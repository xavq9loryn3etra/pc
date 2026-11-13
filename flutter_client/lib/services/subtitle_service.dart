import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class SubtitleTrackData {
  final String id;
  final String url;
  final String lang;
  final String? label;
  final bool isEmbedded;

  /// The video release it was made for ("Ghosts.2021.S01E07.1080p.WEB.H264-
  /// CAKES"), and that release's group ("CAKES") — see
  /// [SubtitleService.rank].
  final String? releaseName;
  final String? releaseGroup;

  /// Found by the video's fingerprint (see [SubtitleService.videoFingerprint]):
  /// made for this very file, so in time with it.
  final bool matchesFile;

  /// For Sinhala made from English subtitles (SubtitleTranslator): the
  /// English track it's translated from. Its [url] is only a name then.
  final SubtitleTrackData? translatedFrom;

  SubtitleTrackData({
    required this.id,
    required this.url,
    required this.lang,
    this.label,
    this.isEmbedded = false,
    this.releaseName,
    this.releaseGroup,
    this.matchesFile = false,
    this.translatedFrom,
  });

  factory SubtitleTrackData.fromJson(Map<String, dynamic> json) {
    String? text(String key) {
      final v = json[key]?.toString().trim();
      return v == null || v.isEmpty ? null : v;
    }

    return SubtitleTrackData(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      lang: json['lang']?.toString() ?? '',
      releaseName: text('movieReleaseName') ?? text('subtitleFileName'),
      releaseGroup: text('releaseGroup'),
      // How OpenSubtitles matched it: "h", by the file's hash; "i", only by
      // the title's IMDb id.
      matchesFile: json['m'] == 'h',
    );
  }

  @override
  String toString() =>
      'SubtitleTrackData(id: $id, lang: $lang, embedded: $isEmbedded, url: $url)';
}

class SubtitleService {
  static final SubtitleService _instance = SubtitleService._internal();
  factory SubtitleService() => _instance;
  SubtitleService._internal();

  final Dio _dio = Dio();

  /// Fetch subtitles from Stremio OpenSubtitles v3 addon
  /// For Movies: https://opensubtitles-v3.strem.io/subtitles/movie/{imdbId}.json
  /// For Series: https://opensubtitles-v3.strem.io/subtitles/series/{imdbId}:{season}:{episode}.json
  ///
  /// With [videoHash] (see [videoFingerprint]), subtitles made for this
  /// very file are found too ([SubtitleTrackData.matchesFile]).
  Future<List<SubtitleTrackData>> fetchSubtitles(
    String imdbId, {
    int? season,
    int? episode,
    int? videoSizeBytes,
    String? filename,
    String? videoHash,
  }) async {
    try {
      final extraParts = <String>[
        if (videoHash != null) 'videoHash=$videoHash',
        if (videoSizeBytes != null && videoSizeBytes > 0)
          'videoSize=$videoSizeBytes',
        if (filename != null && filename.isNotEmpty)
          'filename=${Uri.encodeComponent(filename)}',
      ];
      final extraPath = extraParts.isEmpty ? '' : '/${extraParts.join('&')}';
      final String url;
      if (season != null && episode != null) {
        url =
            'https://opensubtitles-v3.strem.io/subtitles/series/$imdbId:$season:$episode$extraPath.json';
      } else {
        url =
            'https://opensubtitles-v3.strem.io/subtitles/movie/$imdbId$extraPath.json';
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

  /// The video at [streamUrl]'s fingerprint, as OpenSubtitles knows files
  /// by — from its size and first and last 64 KB — and its size. Null if
  /// it couldn't be read within [timeout]. Reading a torrent stream's end
  /// has the engine fetch it first: wanted only once the video plays (see
  /// PlayerScreen._fingerprintSubtitles), and given up on properly — the
  /// reads cancelled, not left fetching.
  Future<({String hash, int size})?> videoFingerprint(
    String streamUrl, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final cancel = CancelToken();
    final timer = Timer(timeout, () => cancel.cancel('too slow'));
    Future<Response<List<int>>> read(String range) => _dio.get<List<int>>(
          streamUrl,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {'Range': 'bytes=$range'},
          ),
        );
    try {
      final head = await read('0-65535');
      // "bytes 0-65535/<size>"
      final size = int.tryParse(
          head.headers.value('content-range')?.split('/').last ?? '');
      if (size == null || size < 2 * 65536) return null;
      final tail = await read('${size - 65536}-${size - 1}');
      return (
        hash: openSubtitlesHash(size, Uint8List.fromList(head.data!),
            Uint8List.fromList(tail.data!)),
        size: size,
      );
    } catch (_) {
      return null;
    } finally {
      timer.cancel();
    }
  }

  /// OpenSubtitles' hash: the file's [size] plus every 8 bytes of its
  /// first and last 64 KB ([head], [tail]) read as numbers, wrapping at 64
  /// bits — as 16 hex digits.
  static String openSubtitlesHash(int size, Uint8List head, Uint8List tail) {
    var hash = size;
    for (final chunk in [head, tail]) {
      final data = ByteData.sublistView(chunk);
      for (var i = 0; i + 8 <= chunk.length; i += 8) {
        hash += data.getInt64(i, Endian.little); // Wraps, as it should.
      }
    }
    return BigInt.from(hash).toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  /// [subs] best first for the video [videoName] (its torrent's name and
  /// file name): made for this very file; then for the same release — its
  /// group's, from the same kind of source (Blu-ray, web, TV), the same
  /// streaming service — as those are timed alike. Otherwise as they came.
  static List<SubtitleTrackData> rank(
    List<SubtitleTrackData> subs,
    String videoName,
  ) {
    final scored = [
      for (var i = 0; i < subs.length; i++)
        (i: i, s: subs[i], score: likeness(subs[i], videoName)),
    ]..sort((a, b) =>
        a.score != b.score ? b.score - a.score : a.i - b.i);
    return [for (final e in scored) e.s];
  }

  /// How alike [s]'s release and the video [videoName]'s are, for timing:
  /// 100 made for this very file; +4 the same release group, +2 the same
  /// kind of source (Blu-ray, web, TV), +1 the same streaming service.
  static int likeness(SubtitleTrackData s, String videoName) {
    if (s.matchesFile) return 100;
    final video = _tokens(videoName);
    final videoSource = _source(video);
    final release = _tokens(s.releaseName ?? '');
    var score = 0;
    final group = s.releaseGroup?.toLowerCase();
    if (group != null && video.contains(group)) score += 4;
    if (videoSource != null && _source(release) == videoSource) score += 2;
    for (final service in _services) {
      if (video.contains(service) && release.contains(service)) score += 1;
    }
    return score;
  }

  /// The kind of source [name] (a release's) says it's from: "bluray",
  /// "web", "hdtv", "dvd" — or null.
  static String? sourceOf(String name) => _source(_tokens(name));

  static const _services = {'amzn', 'nf', 'dsnp', 'hmax', 'max', 'atvp', 'pcok', 'hulu', 'pmtp', 'cbs'};

  static Set<String> _tokens(String name) => name
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();

  static String? _source(Set<String> t) {
    if (t.contains('bluray') ||
        t.contains('bdrip') ||
        t.contains('brrip') ||
        t.contains('bdremux') ||
        t.contains('remux')) {
      return 'bluray';
    }
    if (t.contains('web') || t.contains('webrip') || t.contains('webdl')) {
      return 'web';
    }
    if (t.contains('hdtv')) return 'hdtv';
    if (t.contains('dvdrip') || t.contains('dvd')) return 'dvd';
    return null;
  }
}
