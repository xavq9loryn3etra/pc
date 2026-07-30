class Movie {
  final String id;
  final String title;
  final int year;
  final String? image;
  final String? backdrop;
  final String rating; // Keeping as String to match TS '9.5' or 'N/A'
  final int voteCount;
  final String description;
  final String type; // 'movie' or 'tv'
  final bool inCinemas;
  final String? releaseDateRaw; // Raw TMDB release_date/first_air_date

  // Extra Details
  final String? director;
  final List<String>? cast;
  final List<String>? genres;
  final String? logoUrl;
  final String? runtime;
  final String? mpaa;
  final String? certification;
  final List<Season>? seasons;
  final String? trailerUrl;
  final String? imdbId;

  // History / Progress
  final int? currentSeason;
  final int? currentEpisode;
  final double? progress; // 0.0 to 1.0

  String? get posterUrl => image;
  String? get backdropUrl => backdrop;
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
    required this.rating,
    required this.voteCount,
    required this.description,
    required this.type,
    required this.inCinemas,
    this.releaseDateRaw,
    this.director,
    this.cast,
    this.genres,
    this.logoUrl,
    this.runtime,
    this.mpaa,
    this.certification,
    this.seasons,
    this.trailerUrl,
    this.imdbId,
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
  final double? progress;

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
    this.progress,
  });
}
