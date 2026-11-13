import 'package:flutter/material.dart';
import '../../models/movie.dart';

// Platform interface for WebPlayer

/// The embed sites the web player opens (see ScraperService.getEmbedUrl).
const Set<String> webPlayerProviderHosts = {
  'vidlink.pro',
  'vsembed.ru',
  'moviesapi.to',
  '2embed.skin',
  'www.2embed.skin',
};

/// Whether the player's page may go to [url]: over https, to the site it
/// opened on (or one of its subdomains) or another of the embed sites.
/// Anything else (an ad's redirect, most often) is kept out.
bool isAllowedWebPlayerUrl(String url, String initialUrl) {
  if (url == 'about:blank') return true;
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https' || u.host.isEmpty) return false;
  final h = u.host.toLowerCase();
  final initialHost = (Uri.tryParse(initialUrl)?.host ?? '').toLowerCase();
  return (initialHost.isNotEmpty &&
          (h == initialHost || h.endsWith('.$initialHost'))) ||
      webPlayerProviderHosts.contains(h);
}

abstract class WebPlayerPlatform extends StatefulWidget {
  final String initialUrl;
  final VoidCallback onClose;
  final Movie movie;
  final int? season;
  final int? episode;
  final List<Episode> episodes;
  final List<Season>? seasons;
  final Movie details;

  const WebPlayerPlatform({
    super.key,
    required this.initialUrl,
    required this.onClose,
    required this.movie,
    this.season,
    this.episode,
    this.episodes = const [],
    this.seasons,
    required this.details,
  });
}
