class Movie {
  final String id;
  final String title;
  final int year;
  final String? image;
  final String? backdrop;
  // Best-rated poster with no title text on it (TMDB's no-language
  // posters), for places that draw the logo over the art themselves.
  // Details only, not persisted.
  final String? textlessPoster;
  final String rating; // Keeping as String to match TS '9.5' or 'N/A'
  final int voteCount;
  final String description;
  final String type; // 'movie' or 'tv'
  final bool inCinemas;
  final String? releaseDateRaw; // Raw TMDB release_date/first_air_date
  // TV only: the year its latest episode aired (TMDB's last_air_date).
  // Details only, not persisted.
  final int? lastAirYear;

  // Extra Details
  final String? director;
  final List<String>? cast;
  // Billed cast with photos and character names, for the details screen's
  // cast row (details only, not persisted — `cast` keeps the plain names).
  final List<CastMember>? castMembers;
  final List<String>? genres;
  final String? logoUrl;
  // Width ÷ height of [logoUrl]'s image, from TMDB (details only), so
  // layouts can size a box to the logo before it has loaded.
  final double? logoAspectRatio;
  final String? runtime;
  final String? mpaa;
  final String? certification;
  final List<Season>? seasons;
  final String? trailerUrl;
  final String? imdbId;
  // Wikidata entity ID (e.g. "Q104082429") from TMDB external_ids —
  // used to resolve direct streaming-service links (see
  // StreamingLinkService).
  final String? wikidataId;
  // Subscription service streaming this title in the user's country (from
  // TMDB's watch providers). Details-only, not persisted.
  final StreamingProvider? streamingProvider;
  // Any other subscription services streaming it there too, in TMDB's
  // order (the details screen's "Also on"). Details-only, not persisted.
  final List<StreamingProvider> otherStreamingProviders;

  // History / Progress
  final int? currentSeason;
  final int? currentEpisode;
  final double? progress; // 0.0 to 1.0

  String? get posterUrl => image;
  String? get backdropUrl => backdrop;
  // `backdrop` is TMDB's w1280 tier — plenty for episode thumbnails, the
  // player overlay, etc., but visibly soft when stretched across a full-width
  // hero banner on desktop (see TMDBService._backdropBase). This swaps in
  // TMDB's actual source resolution for the few places that render a
  // backdrop that large: the home hero banners and the details-page hero.
  String? get backdropHighRes => backdrop?.replaceFirst('/w1280/', '/original/');
  // `logoUrl` is also built from TMDB's w500 tier. Logos are usually wide,
  // short wordmarks, so a 500px-wide source can have well under 200px of
  // real height — same shortfall as backdrop for the couple of places a
  // logo renders large (the hero banners' ~100-150px logo, the details
  // page's 200px-wide hero header logo). No-op for the rare SVG logo path,
  // since TMDB serves those unscaled regardless of the size segment.
  String? get logoHighRes => logoUrl?.replaceFirst('/w500/', '/original/');
  // Mappings for UI compatibility
  DateTime? get releaseDate => DateTime(year);
  double get voteAverage => double.tryParse(rating) ?? 0.0;
  String? get overview => description;

  /// Whether this movie/show's release date is in the future — used to
  /// block playback of content that hasn't come out yet (no real torrent
  /// stream can exist for it regardless of what an indexer might return).
  bool get isUnreleased {
    final raw = releaseDateRaw;
    if (raw == null || raw.isEmpty) return false;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return false;
    return parsed.isAfter(DateTime.now());
  }

  Movie({
    required this.id,
    required this.title,
    required this.year,
    this.image,
    this.backdrop,
    this.textlessPoster,
    required this.rating,
    required this.voteCount,
    required this.description,
    required this.type,
    required this.inCinemas,
    this.releaseDateRaw,
    this.lastAirYear,
    this.director,
    this.cast,
    this.castMembers,
    this.genres,
    this.logoUrl,
    this.logoAspectRatio,
    this.runtime,
    this.mpaa,
    this.certification,
    this.seasons,
    this.trailerUrl,
    this.imdbId,
    this.wikidataId,
    this.streamingProvider,
    this.otherStreamingProviders = const [],
    this.currentSeason,
    this.currentEpisode,
    this.progress,
  });

  // Serialization for Local Storage (Favorites)
  Map<String, dynamic> toStorageJson() {
    return {
      'id': id,
      'title': title,
      'year': year,
      'image': image,
      'backdrop': backdrop,
      'rating': rating,
      'vote_count': voteCount,
      'description': description,
      'type': type,
      'in_cinemas': inCinemas,
      'release_date_raw': releaseDateRaw,
      'trailer_url': trailerUrl,
      'imdb_id': imdbId,
      'current_season': currentSeason,
      'current_episode': currentEpisode,
      'progress': progress,
    };
  }

  factory Movie.fromStorageJson(Map<String, dynamic> json) {
    return Movie(
      id: json['id'],
      title: json['title'],
      year: json['year'],
      image: json['image'],
      backdrop: json['backdrop'],
      rating: json['rating'],
      voteCount: json['vote_count'],
      description: json['description'],
      type: json['type'],
      inCinemas: json['in_cinemas'] ?? false,
      releaseDateRaw: json['release_date_raw'],
      trailerUrl: json['trailer_url'],
      imdbId: json['imdb_id'],
      currentSeason: json['current_season'],
      currentEpisode: json['current_episode'],
      progress: json['progress']?.toDouble(),
    );
  }
}

class Season {
  final int id;
  final int seasonNumber;
  final String? posterPath;
  final int? episodeCount;

  Season({
    required this.id,
    required this.seasonNumber,
    this.posterPath,
    this.episodeCount,
  });

  factory Season.fromJson(Map<String, dynamic> json) {
    return Season(
      id: json['id'],
      seasonNumber: json['season_number'],
      posterPath: json['poster_path'],
      episodeCount: json['episode_count'],
    );
  }
}

class Episode {
  final int id;
  final int episodeNumber;
  final String name;
  final String overview;
  final String? stillPath;
  final String? airDate;
  final double voteAverage;
  // Length in minutes, from TMDB; null when unknown.
  final int? runtime;
  final double? progress;

  /// A copy of this episode with [progress] (watch history) attached.
  Episode withProgress(double? progress) => Episode(
        id: id,
        episodeNumber: episodeNumber,
        name: name,
        overview: overview,
        stillPath: stillPath,
        airDate: airDate,
        voteAverage: voteAverage,
        runtime: runtime,
        progress: progress,
      );

  /// A copy of this episode with [runtime] (in minutes) replaced.
  Episode withRuntime(int? runtime) => Episode(
        id: id,
        episodeNumber: episodeNumber,
        name: name,
        overview: overview,
        stillPath: stillPath,
        airDate: airDate,
        voteAverage: voteAverage,
        runtime: runtime,
        progress: progress,
      );

  /// Whether this episode's air date is in the future — see
  /// Movie.isUnreleased for why this matters for playback.
  bool get isUnreleased {
    final raw = airDate;
    if (raw == null || raw.isEmpty) return false;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return false;
    return parsed.isAfter(DateTime.now());
  }

  Episode({
    required this.id,
    required this.episodeNumber,
    required this.name,
    required this.overview,
    this.stillPath,
    this.airDate,
    required this.voteAverage,
    this.runtime,
    this.progress,
  });
}

/// A subscription streaming service that carries a title, as reported by
/// TMDB's watch providers (data from JustWatch).
///
/// Deliberately has no web URL: tapping it opens the title only in the
/// service's own app, via StreamingLinkService — never TMDB, a search page
/// or any other website.
class StreamingProvider {
  final int id;
  final String name;
  final String? logoUrl;

  const StreamingProvider({
    required this.id,
    required this.name,
    this.logoUrl,
  });

  // Logos bundled in assets/providers/ (TMDB's own logo images) so the
  // major services' icons show instantly instead of loading from the
  // network on first view. Keyed by TMDB provider ID.
  static const _bundledLogoIds = {
    8, // Netflix
    9, // Amazon Prime Video
    337, // Disney Plus
    350, // Apple TV
    15, // Hulu
    1899, // HBO Max
    531, // Paramount Plus
    2336, // JioHotstar
    232, // Zee5
    237, // Sony Liv
    283, // Crunchyroll
  };
  // Other IDs TMDB uses for the same services and logos.
  static const _logoAliases = {
    1796: 8, // Netflix Standard with Ads
    119: 9, // Amazon Prime Video (other regions)
    2100: 9, // Amazon Prime Video with Ads
  };

  /// Bundled logo asset for this service, or null to load [logoUrl].
  String? get bundledLogoAsset {
    final logoId = _logoAliases[id] ?? id;
    return _bundledLogoIds.contains(logoId)
        ? 'assets/providers/$logoId.png'
        : null;
  }
}

/// One billed cast member, from TMDB credits.
class CastMember {
  final String name;
  final String? character;
  final String? profileUrl;

  const CastMember({required this.name, this.character, this.profileUrl});
}
