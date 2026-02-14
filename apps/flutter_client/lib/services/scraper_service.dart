class ScraperService {
  // VidKing URL Generation
  String getEmbedUrl(
    String tmdbId, {
    int? season,
    int? episode,
    String? imdbId,
    String provider = 'vidking',
  }) {
    final primaryColor = 'FDEDAD'; // Match existing app theme

    if (provider == 'vidlink') {
      if (season != null && episode != null) {
        return 'https://vidlink.pro/tv/$tmdbId/$season/$episode?primaryColor=$primaryColor';
      }
      return 'https://vidlink.pro/movie/$tmdbId?primaryColor=$primaryColor';
    }

    if (provider == 'moviesapi') {
      if (season != null && episode != null) {
        return 'https://moviesapi.club/tv/$tmdbId-$season-$episode';
      }
      return 'https://moviesapi.club/movie/$tmdbId';
    }

    if (provider == 'vsembed') {
      if (season != null && episode != null) {
        return 'https://vsembed.ru/embed/tv?tmdb=$tmdbId&season=$season&episode=$episode';
      }
      return 'https://vsembed.ru/embed/movie?tmdb=$tmdbId';
    }

    // Default: VidKing, or explicit 'vidking'
    // VidKing also supports IMDB: https://vidking.net/embed/imdb/{imdb_id}
    // Prefer IMDB if available for better mapping accuracy
    if (imdbId != null && (season == null || episode == null)) {
      // Logic for movie with IMDB
      return 'https://vidking.net/embed/imdb/$imdbId?color=$primaryColor';
    }

    // Fallback to TMDB
    if (season != null && episode != null) {
      return 'https://vidking.net/embed/tv/$tmdbId/$season/$episode?color=$primaryColor';
    }
    return 'https://vidking.net/embed/movie/$tmdbId?color=$primaryColor';
  }

  // Legacy Future for backward compat if needed, but we prefer direct String for embeds
  Future<String?> getStreamUrl(String query) async {
    // Phase 1 Stub - kept for reference
    return 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
  }
}
