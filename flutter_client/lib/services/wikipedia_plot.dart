import 'package:dio/dio.dart';

import 'tmdb_service.dart';

/// A film's plot as Wikipedia tells it, for Popcorn Ask's spoilers (see
/// AiService): the model retells it rather than going from memory, which
/// for a little-known or recent film (Neera, a 2025 Sinhala film) it made
/// up. Found through the film's Wikidata entry (from TMDB), so it's the
/// right article, not just one with the same name.
class WikipediaPlot {
  WikipediaPlot._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    // Wikimedia asks apps to say who they are.
    headers: {
      'User-Agent': 'Popcorn/3 (https://popcorn-organization.github.io/popcorn/)'
    },
  ));

  /// The section headings a plot is under, by Wikipedia language.
  static const _plotHeadings = {
    'en': ['Plot', 'Synopsis', 'Plot summary', 'Story'],
    'si': ['කතාව', 'කතා සාරය', 'කථාව', 'කථා සාරය', 'කතා වස්තුව'],
  };

  /// The plot of the movie with TMDB id [tmdbId] from its English
  /// Wikipedia article (else its Sinhala one), as plain text; null when
  /// there's none to be found.
  static Future<String?> forMovie(String tmdbId) async {
    try {
      final wikidata = await TMDBService().wikidataId(tmdbId, isTv: false);
      if (wikidata == null) return null;
      final entity = await _dio.get(
        'https://www.wikidata.org/w/api.php',
        queryParameters: {
          'action': 'wbgetentities',
          'ids': wikidata,
          'props': 'sitelinks',
          'sitefilter': 'enwiki|siwiki',
          'format': 'json',
        },
      );
      final links =
          entity.data['entities']?[wikidata]?['sitelinks'] as Map? ?? const {};
      for (final lang in _plotHeadings.keys) {
        final title = links['${lang}wiki']?['title'];
        if (title is! String) continue;
        final plot = await _plot(lang, title);
        if (plot != null) return plot;
      }
    } catch (e) {
      print('[wikipedia] $e');
    }
    return null;
  }

  static Future<String?> _plot(String lang, String title) async {
    final response = await _dio.get(
      'https://$lang.wikipedia.org/w/api.php',
      queryParameters: {
        'action': 'query',
        'prop': 'extracts',
        'explaintext': 1,
        'exsectionformat': 'wiki',
        'titles': title,
        'redirects': 1,
        'format': 'json',
        'formatversion': 2,
      },
    );
    final pages = response.data['query']?['pages'] as List?;
    final text = pages?.firstOrNull?['extract'];
    if (text is! String) return null;
    return plotIn(text, _plotHeadings[lang]!);
  }

  /// The section under one of [headings] in an article's plain text (its
  /// headings as "== Plot =="), up to the next heading of the same level.
  static String? plotIn(String article, List<String> headings) {
    for (final heading in headings) {
      final start = RegExp('\\n== *${RegExp.escape(heading)} *==\\n')
          .firstMatch(article);
      if (start == null) continue;
      final rest = article.substring(start.end);
      final end = RegExp(r'\n== [^=]').firstMatch(rest);
      final plot = (end == null ? rest : rest.substring(0, end.start)).trim();
      // A stub ("The plot is about…") is no help.
      if (plot.split(RegExp(r'\s+')).length >= 60) return plot;
    }
    return null;
  }
}
