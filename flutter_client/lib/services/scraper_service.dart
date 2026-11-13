class ScraperService {
  String getEmbedUrl(
    String tmdbId, {
    int? season,
    int? episode,
    String? imdbId,
    String provider = '2embed',
  }) {
    final primaryColor = 'FDEDAD'; // Match existing app theme

    if (provider == 'vidlink') {
      if (season != null && episode != null) {
        return 'https://vidlink.pro/tv/$tmdbId/$season/$episode?primaryColor=$primaryColor';
      }
      return 'https://vidlink.pro/movie/$tmdbId?primaryColor=$primaryColor';
    }

    if (provider == 'moviesapi') {
      // moviesapi.club is dead (NXDOMAIN as of Aug 2026) — the service
      // moved to moviesapi.to, which also switched its TV path from
      // hyphens to slashes (confirmed: the old hyphenated path 301s to
      // this one on the new domain).
      if (season != null && episode != null) {
        return 'https://moviesapi.to/tv/$tmdbId/$season/$episode';
      }
      return 'https://moviesapi.to/movie/$tmdbId';
    }

    if (provider == 'vsembed') {
      if (season != null && episode != null) {
        return 'https://vsembed.ru/embed/tv?tmdb=$tmdbId&season=$season&episode=$episode';
      }
      return 'https://vsembed.ru/embed/movie?tmdb=$tmdbId';
    }

    // Default: 2embed, or explicit '2embed'. Replaces the old default,
    // vidking.net, which as of Aug 2026 is dead — its whole domain
    // (including the homepage) returns a broken Google-infrastructure
    // error page, not just a stale URL format like moviesapi.club above.
    //
    // Domain is 2embed.skin, NOT 2embed.cc — .cc's own page only works
    // when actually loaded inside an iframe; loaded as the top-level
    // document (exactly what happens when the WebView opens this URL
    // directly), its JS checks `window === window.top` and immediately
    // self-redirects to .skin, which the WebView's navigation whitelist
    // then blocks as an unrecognized host, leaving a blank screen. .skin
    // is the real destination and loads directly with no such check.
    //
    // Both /embed and /embedtv paths accept either a TMDB or an IMDB id
    // interchangeably (confirmed against both), so — unlike vidking —
    // there's no separate IMDB-specific path; just prefer whichever id
    // we have.
    final id = imdbId ?? tmdbId;
    if (season != null && episode != null) {
      return 'https://www.2embed.skin/embedtv/$id?s=$season&e=$episode';
    }
    return 'https://www.2embed.skin/movie/$id';
  }

  // Legacy Future for backward compat if needed, but we prefer direct String for embeds
  Future<String?> getStreamUrl(String query) async {
    // Phase 1 Stub - kept for reference
    return 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
  }
}
