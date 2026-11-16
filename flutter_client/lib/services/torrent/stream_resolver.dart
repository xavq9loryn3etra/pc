import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:libtorrent_flutter/libtorrent_flutter.dart' show FileInfo;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/movie.dart';
import '../audio_language_service.dart';
import '../episode_numbering.dart';
import '../tmdb_service.dart';
import 'free_space.dart';
import 'torrent_download_registry.dart';
import 'torrent_engine_service.dart';
import 'torrent_index_service.dart';

/// The result of resolving a stream, possibly after falling back away from
/// the originally-requested one.
class StreamResolveResult {
  final TorrentStream stream;
  final StreamResult result;
  StreamResolveResult({required this.stream, required this.result});
}

/// Thrown by [StreamResolver.resolveWithFallback] when its `isCancelled`
/// says the user gave up (e.g. closed the popup) — not an error to show.
class ResolveCancelledException implements Exception {
  const ResolveCancelledException();
}

/// One quality the user can pick (4K, 1080p, ...) instead of a specific
/// torrent: [streams] holds every torrent of that quality, best pick first.
/// Playing an option starts [best] and falls back through the rest, so the
/// user never has to choose between releases.
class QualityOption {
  /// See [StreamResolver.tierOf]: 4 = 4K down to 0 = CAM/unknown.
  final int tier;
  final List<TorrentStream> streams;

  const QualityOption(this.tier, this.streams);

  TorrentStream get best => streams.first;

  /// Short mark for the quality badge.
  String get badge => const {4: '4K', 3: 'FHD', 2: 'HD', 1: 'SD'}[tier] ?? '—';

  String get name =>
      const {4: 'Ultra HD', 3: 'Full HD', 2: 'HD', 1: 'SD'}[tier] ?? 'Other';

  String get resolution =>
      const {4: '2160p', 3: '1080p', 2: '720p', 1: '480p'}[tier] ??
      (best.quality == 'CAM' ? 'Cinema recording' : 'Unknown quality');

  /// [best]'s download size ("2.1 GB"), or null when it isn't known.
  String? get size =>
      StreamResolver._sizeInMB(best.size) != null ? best.size : null;
}

class StreamResolver {
  final _indexService = TorrentIndexService();
  final _engine = TorrentEngineService.instance;

  /// How much bigger a quality tier is allowed to be than the best size
  /// available one tier down before it's considered "not worth it" and we
  /// step down instead. People pick torrents by size and quality, not
  /// seeder count: a 4K release that happens to be smaller than the 1080p
  /// alternative is an easy win, but a 1080p release costing 2x+ what a
  /// solid 720p costs isn't worth it to most people, no matter the seeds.
  static const double _sizeJumpThreshold = 2.2;

  /// Get available qualities for a movie/show, sorted so the best practical
  /// pick — balancing quality against file size the way people actually
  /// choose — comes first. Only SD (480p) and up: cinema recordings and
  /// releases of unknown quality (tier 0, see [tierOf]) are left out
  /// altogether, so nothing — a list, a fallback — ever lands on one. So
  /// are cinema recordings that claim a resolution ("1080p HDCAM"), see
  /// [_isCamRecording].
  ///
  /// [title], when given, also drops releases of a different title — see
  /// [_fitsTitle] — and, while it's only in cinemas ([Movie.isCinemaOnly]),
  /// every copy not named as a home release (see [_isHomeRelease]).
  Future<List<TorrentStream>> getAvailableStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
    Movie? title,
    // Ranks for this audio language instead of the one saved for [title]
    // — for a list being looked at in another (see AudioLanguagePicker).
    AudioLanguage? audioLanguage,
  }) async {
    final stopwatch = Stopwatch()..start();
    // Alongside the finders: the copies of films with the same name.
    final namesakes = type == 'movie' && title != null
        ? _namesakeCopies(title)
        : Future.value(const <TorrentStream>[]);
    final found = withoutNamesakes(
        await _find(imdbId, type, season, episode, title), await namesakes);
    print('[timing] found ${found.length} copies in '
        '${stopwatch.elapsedMilliseconds} ms');
    final cinemaOnly = title?.isCinemaOnly ?? false;
    await _loadWrongCopies();
    var streams = found
        .where((s) =>
            !isWrongCopy(imdbId, s.infoHash) &&
            tierOf(s) > 0 &&
            !_isCamRecording(s, title) &&
            (!cinemaOnly || _isHomeRelease(s, title)) &&
            !_isExtra(s, title) &&
            !(type != 'movie' && (season ?? 1) > 0 && _isSpecial(s, title)) &&
            _fitsTitle(s, title) &&
            // Never a fan edit, not even when there's nothing else.
            !_isCustomEdit(s, title) &&
            !saysAnotherFilm(s, title) &&
            !tooSmallFor(s, title))
        .toList();
    // English audio for titles made in English. For one made in another
    // language, the audio chosen for it (AudioLanguageService, the
    // original by default): for, say, a Tamil film, an untagged (assumed
    // English) copy with 11 sharers otherwise outranked the Tamil one with
    // 235, and every fallback attempt went to barely-shared copies.
    if (title != null) {
      final languages = AudioLanguageService();
      await languages.ensureLoaded();
      final choice = AudioLanguageService.appliesTo(title);
      final own = choice ? title.originalLanguage! : 'en';
      final wanted = choice &&
              (audioLanguage ?? languages.of(title)) == AudioLanguage.original
          ? own
          : 'en';
      final audio = WantedAudio(
          language: wanted, titleLanguage: own, titleName: title.title);
      streams = [for (final s in streams) s.wantingLanguage(audio)];
    }

    // Never a copy in another language — as on Netflix, it plays in the
    // language chosen or not at all. Every pick is made from this list (a
    // quality, a start's fallbacks, stall recovery, the next episode, the
    // copy last played when resuming), so none can land on a dub: The
    // Mentalist's only SD copies were Russian, French and Italian ones, and
    // SD played Russian; Back to the Future Part II, its English copies
    // short of disk space, fell back to a dub and kept resuming in it.
    // No copy in the language: nothing to play.
    streams = streams.where((s) => languageRank(s) < 2).toList();

    final recommendedTier = _recommendedTierRank(streams);
    streams.sort((a, b) =>
        _score(b, recommendedTier).compareTo(_score(a, recommendedTier)));
    return streams;
  }

  // What the finders listed for each movie / episode lately, so ranking
  // it again (its audio language changed) needn't look it all up again.
  static final _found =
      <String, ({DateTime at, List<TorrentStream> streams})>{};
  static const _foundFor = Duration(minutes: 20);

  Future<List<TorrentStream>> _find(String imdbId, String type, int? season,
      int? episode, Movie? title) async {
    // The finders go by IMDb's numbering, which for some shows (long
    // anime: One Piece) isn't TMDB's, shown in the app.
    if (type != 'movie' && title != null && season != null && episode != null) {
      (season, episode) = await EpisodeNumbering().toImdb(
          imdbId: imdbId, tmdbId: title.id, season: season, episode: episode);
    }
    final key = type == 'movie'
        ? 'movie:$imdbId'
        : 'tv:$imdbId:${season ?? 1}:${episode ?? 1}';
    final cached = _found[key];
    if (cached != null && DateTime.now().difference(cached.at) < _foundFor) {
      return cached.streams;
    }
    final found = type == 'movie'
        ? await _indexService.getMovieStreams(imdbId)
        : await _indexService.getSeriesStreams(
            imdbId, season ?? 1, episode ?? 1);
    void keep(List<TorrentStream> streams) {
      if (streams.isEmpty) return;
      _found[key] = (at: DateTime.now(), streams: List.unmodifiable(streams));
    }

    // Only a full answer is kept: a finder that failed, or wasn't waited
    // for (Torrentio can take 20s), may have had the season packs and most
    // of the copies — asked again next time. One still going is kept when
    // it has answered, if they all did.
    if (found.complete) {
      keep(found.streams);
    } else {
      found.rest?.then((all) {
        if (all != null) keep(all);
      });
    }
    return found.streams;
  }

  // The copies of each movie's namesakes, by TMDB id (see
  // [_namesakeCopies]).
  static final _namesakesOf = <String, List<TorrentStream>>{};

  /// YTS's copies of the films with [title]'s name, out within a year of
  /// it (TMDBService.namesakesOf): the finders file some of them under
  /// [title] too. YTS's own are surely theirs (see [withoutNamesakes]).
  /// Not waited on for more than a few seconds: none then.
  Future<List<TorrentStream>> _namesakeCopies(Movie title) async {
    final cached = _namesakesOf[title.id];
    if (cached != null) return cached;
    Future<List<TorrentStream>> lookUp() async {
      final ids = await TMDBService().namesakesOf(title);
      final lists = await Future.wait(ids.map(_indexService.ytsStreams));
      if (lists.any((l) => l == null)) {
        return [for (final l in lists) ...?l];
      }
      return _namesakesOf[title.id] = [for (final l in lists) ...l!];
    }

    try {
      // Late, and the copies are listed without it (the player's length
      // check is still there): YTS can take half a minute to fail.
      return await lookUp().timeout(const Duration(seconds: 6));
    } catch (_) {
      return const [];
    }
  }

  /// [streams] without the copies of another film with the same name —
  /// one of [namesakes], or the same size at the same quality (another
  /// upload of it). Torrentio listed The Asylum's The Odyssey (2026) under
  /// Nolan's: its YTS copies, and re-uploads of them shared by thousands,
  /// came first for HD and Full HD, and played The Asylum's film.
  @visibleForTesting
  static List<TorrentStream> withoutNamesakes(
      List<TorrentStream> streams, List<TorrentStream> namesakes) {
    if (namesakes.isEmpty) return streams;
    final hashes = {for (final n in namesakes) n.infoHash.toLowerCase()};
    bool sameCopy(TorrentStream s, TorrentStream n) {
      final a = _sizeInMB(s.size), b = _sizeInMB(n.size);
      if (a == null || b == null || tierOf(s) != tierOf(n)) return false;
      return (a - b).abs() <= math.max(4, b * 0.006);
    }

    return [
      for (final s in streams)
        if (!hashes.contains(s.infoHash.toLowerCase()) &&
            !namesakes.any((n) => sameCopy(s, n)))
          s,
    ];
  }

  // A release saying it isn't the film it's filed under: "The Odyssey 2026
  // (NOT The Chris Nolan FILM)".
  static final _anotherFilmPattern = RegExp(
      r'(?<![A-Za-z])not[ ._-]+the[ ._-]+.{0,40}?(?<![A-Za-z])(film|movie)(?![A-Za-z])',
      caseSensitive: false);

  /// Whether [stream]'s name says it's another film than [title] (whose
  /// own name may say "not the").
  @visibleForTesting
  static bool saysAnotherFilm(TorrentStream stream, Movie? title) {
    if (_anotherFilmPattern.hasMatch(title?.title ?? '')) return false;
    return _anotherFilmPattern.hasMatch('${stream.name}\n${stream.title}');
  }

  // Files that run as programs on Windows or Android. A real copy of a film
  // never has one; fakes of a new film often do (a short clip, and a
  // "player" or "codec" to install). Not ".com": a text file named
  // "...Demonoid.com" has it too.
  static const _programTypes = {
    'exe', 'msi', 'scr', 'bat', 'cmd', 'lnk', 'pif', 'vbs', 'vbe', 'wsf',
    'hta', 'ps1', 'jar', 'apk', 'xapk',
  };

  /// What's wrong inside a copy, from its [files] — once connected, before
  /// it plays — or null if nothing: a program among them, or the file to
  /// play (the one [fileIdx] names, or the largest video) named for
  /// another film or year than [title] ("Bonus/The.Odyssey.1997.mkv").
  @visibleForTesting
  static String? insideProblem(
      List<FileInfo> files, int? fileIdx, Movie? title) {
    if (files.isEmpty) return null;
    for (final f in files) {
      final name = f.name.toLowerCase();
      final dot = name.lastIndexOf('.');
      if (dot > 0 && _programTypes.contains(name.substring(dot + 1))) {
        return 'it holds a program (${f.name})';
      }
    }
    if (title == null) return null;
    FileInfo? playing;
    if (fileIdx != null) {
      for (final f in files) {
        if (f.index == fileIdx) playing = f;
      }
    } else {
      try {
        final index = TorrentEngineService.chooseVideoFile(files);
        playing = files.firstWhere((f) => f.index == index);
      } catch (_) {}
    }
    if (playing == null) return null;
    final path = playing.path.isNotEmpty ? playing.path : playing.name;
    final fits = title.year <= 0 ||
        (_yearsFit(path, title) &&
            !(title.type == 'tv' &&
                namesAnotherShow(path,
                    showTitle: title.title, startYear: title.year)));
    return fits ? null : 'its video is named for another film ($path)';
  }

  // Copies found to be of another film than the one they're listed for
  // (the player saw their length was wrong — see [wrongLength]), as
  // "<imdb id>:<info hash>": never offered for it again. Saved.
  static Set<String> _wrongCopies = {};
  static Future<void>? _wrongCopiesLoaded;
  static const _wrongCopiesKey = 'wrong_copies_v1';

  static Future<void> _loadWrongCopies() =>
      _wrongCopiesLoaded ??= SharedPreferences.getInstance().then((prefs) {
        _wrongCopies = {...?prefs.getStringList(_wrongCopiesKey)};
      }).catchError((Object _) {});

  /// Whether [infoHash] was found to be another film than [imdbId].
  static bool isWrongCopy(String imdbId, String infoHash) =>
      _wrongCopies.contains('$imdbId:${infoHash.toLowerCase()}');

  /// Notes [infoHash] as another film than [imdbId], or ([wrong] false)
  /// takes that back.
  static Future<void> markWrongCopy(String imdbId, String infoHash,
      {bool wrong = true}) async {
    await _loadWrongCopies();
    final key = '$imdbId:${infoHash.toLowerCase()}';
    wrong ? _wrongCopies.add(key) : _wrongCopies.remove(key);
    // The latest 500.
    final list = _wrongCopies.toList();
    final kept = list.length > 500 ? list.sublist(list.length - 500) : list;
    _wrongCopies = kept.toSet();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_wrongCopiesKey, kept);
    } catch (_) {}
  }

  /// Whether a video [length] can't be the film [expectedMinutes] long:
  /// under two thirds of it (The Asylum's 86-minute The Odyssey for
  /// Nolan's 173), or over 1.8 times (extended cuts run up to a third
  /// longer). Never when the film's length isn't known, or is under half
  /// an hour (a short's listed length can be well off).
  @visibleForTesting
  static bool wrongLength(Duration length, int? expectedMinutes) {
    if (expectedMinutes == null || expectedMinutes < 30) return false;
    if (length <= Duration.zero) return false;
    final minutes = length.inSeconds / 60;
    return minutes < expectedMinutes * 0.65 ||
        minutes > expectedMinutes * 1.8;
  }

  // Words that mark a release as filmed in a cinema: camera (CAM, HDCAM),
  // telesync (TS, HDTS), telecine (TC), screeners (SCR, DVDScr, HdTScr) and
  // the names Indian releases use for them ("PreDVDRip", "HQ Pre",
  // "HQ S-Print").
  static final _camPattern = RegExp(
      r'(?<![A-Za-z])((hd|hq)[ .-]?)?(cam(rip)?|ts(rip)?|tc|telesync|telecine'
      r'|pre[ .-]?dvd(rip)?|s[ .-]?print)(?![A-Za-z])'
      r'|(?<![A-Za-z])((dvd|hdts?)[ .-]?)?scr(eener)?(?![A-Za-z])'
      r'|(?<![A-Za-z])hq[ .-]?pre(?![A-Za-z])',
      caseSensitive: false);

  // Words that mark a release as copied from a streaming service, disc or
  // TV broadcast — never from a cinema.
  static final _homeSourcePattern = RegExp(
      r'(?<![A-Za-z])(web([ .-]?(dl|rip))?|blu[ .-]?ray|bd(rip|remux)?'
      r'|br[ .-]?rip|remux|hdtv|dvd(rip)?|amzn|nf|dsnp|hmax|atvp)(?![A-Za-z])',
      caseSensitive: false);

  /// Whether [pattern] matches [stream]'s release name, other than in
  /// words of [title]'s own name ("Charlotte's Web", "Cam").
  static bool _namedAs(RegExp pattern, TorrentStream stream, Movie? title) {
    final ownWords =
        (title?.title.toLowerCase() ?? '').split(RegExp('[^a-z0-9]+')).toSet();
    return pattern
        .allMatches(stream.name)
        .any((m) => !ownWords.contains(m[0]!.toLowerCase()));
  }

  /// Whether [stream] was filmed in a cinema, whatever resolution it
  /// claims — "Movie 2026 1080p HDCAM" is still a camera recording.
  static bool _isCamRecording(TorrentStream stream, Movie? title) =>
      _namedAs(_camPattern, stream, title);

  /// Whether [stream]'s name shows it came from a streaming service, disc
  /// or TV (WEB-DL, BluRay, HDTV, ...). Vaguer names ("HDRip", none at all)
  /// are often camera recordings while a movie is still in cinemas.
  static bool _isHomeRelease(TorrentStream stream, Movie? title) =>
      _namedAs(_homeSourcePattern, stream, title);

  // Words that mark a pack's file as a bonus clip rather than the feature.
  static final _extraPattern = RegExp(
      r'(?<![A-Za-z])(menu|sample|trailer|NCOP|NCED|creditless|featurettes?|'
      r'behind[ ._-]the[ ._-]scenes|making[ ._-]of|deleted[ ._-]scenes)(?![A-Za-z])',
      caseSensitive: false);

  /// Whether [stream] is a disc menu, sample, trailer or similar extra that
  /// Torrentio matched to the episode by mistake — e.g. a Blu-ray rip's
  /// 12 MB "menu/…[S1][D1][01]….mkv" listed as Naruto's episode 1. Judged
  /// by the file's own name (a pack's second title line; words that are
  /// part of [title]'s own name, as in "The Menu", don't count) and by
  /// size: no real episode is under 30 MB.
  static bool _isExtra(TorrentStream stream, Movie? title) {
    final lines = stream.title.split('\n');
    final ownName = title?.title.toLowerCase() ?? '';
    if (stream.isPack &&
        lines.length > 1 &&
        _extraPattern
            .allMatches(lines[1])
            .any((m) => !ownName
                .contains(m[0]!.toLowerCase().replaceAll(RegExp(r'[._-]'), ' ')))) {
      return true;
    }
    final mb = _sizeInMB(stream.size);
    return mb != null && mb < 30;
  }

  static final _specialPattern =
      RegExp(r'(?<![A-Za-z])(OVAs?|OADs?)(?![A-Za-z])', caseSensitive: false);

  /// Whether [stream] is an OVA/OAD special rather than a regular episode —
  /// Torrentio matches "[NamikazeSubs] Naruto OVA 01 …" to Naruto's S1E1,
  /// a different 17-minute story. Either the file's own name (for a pack)
  /// says so, or the release is OVAs only — one named as a whole series
  /// that also has its OVAs ("Attack on Titan (S01-S04+OVA+Movies)") still
  /// holds the episode.
  static bool _isSpecial(TorrentStream stream, Movie? title) {
    final ownName = title?.title.toLowerCase() ?? '';
    bool saysSpecial(String name) => _specialPattern
        .allMatches(name)
        .any((m) => !ownName.contains(m[0]!.toLowerCase()));
    final lines = stream.title.split('\n');
    if (stream.isPack && lines.length > 1 && saysSpecial(lines[1])) {
      return true;
    }
    return saysSpecial(stream.name) &&
        !_collectionPattern.hasMatch(stream.name);
  }

  // A release of a whole series: seasons ("S01-S04"), "complete", or an
  // episode range ("001-220", "Episodes 001-750") — not a year span.
  static final _collectionPattern = RegExp(
      r'(?<![A-Za-z])(S\d{1,2}|seasons?|complete|collection|batch|episodes)(?![A-Za-z])'
      r'|(?<!\d)\d{1,3}\s*[-~]\s*\d{1,3}(?!\d)',
      caseSensitive: false);

  static final _customPattern = RegExp(
      r'(?<![A-Za-z])(custom|one[ ._-]?pace)(?![A-Za-z])',
      caseSensitive: false);

  /// Whether [stream] is a fan edit ("[N-Custom] Naruto …", One Pace's
  /// One Piece): these cut the opening, ending and recaps, so an episode
  /// plays at 17 minutes instead of 23 and doesn't match what people
  /// expect. One Pace re-cuts whole arcs, its parts numbered its own way:
  /// Torrentio filed an Enies Lobby part under Amazon Lily's first
  /// episode, and it came first. Not when the edit's name is part of
  /// [title]'s own.
  static bool _isCustomEdit(TorrentStream stream, Movie? title) {
    final name = title?.title.toLowerCase() ?? '';
    return _customPattern.allMatches(stream.name).any((m) => !name
        .contains(m[0]!.toLowerCase().replaceAll(RegExp('[ ._-]'), ' ')));
  }

  // A year standing on its own in a release name ("Baki (2018)",
  // "Show.2019.1080p"), not part of a longer number like "1920x1080".
  static final _yearPattern =
      RegExp(r'(?<![A-Za-z0-9])(19\d\d|20\d\d)(?![A-Za-z0-9])');
  // A span of years, as collections and complete series give them
  // ("(2000-2023)", "1994 - 2004", "2008 to 2021").
  static final _yearRangePattern = RegExp(
      r'(?<![A-Za-z0-9])(19\d\d|20\d\d)\s*(?:[-–]|to)\s*(19\d\d|20\d\d)(?![A-Za-z0-9])',
      caseSensitive: false);

  /// Whether [stream] could be a release of [title]: not when its name
  /// gives only years outside the title's own. Torrentio sometimes files a
  /// remake or namesake under the original — "Baki (Baki the Grappler
  /// 2018)" under 2001's Baki the Grappler — which would play the wrong
  /// show. Names without a year are kept, as are numbers that are part of
  /// the title itself ("Blade Runner 2049").
  static bool _fitsTitle(TorrentStream stream, Movie? title) {
    if (title == null || title.year <= 0) return true;
    if (title.type == 'tv' &&
        namesAnotherShow('${stream.name}\n${stream.title}',
            showTitle: title.title, startYear: title.year)) {
      return false;
    }
    return _yearsFit(stream.name, title);
  }

  /// Whether the years [name] gives (if any) are [title]'s own — see
  /// [_fitsTitle].
  static bool _yearsFit(String name, Movie title) {
    final titleNumbers =
        _yearPattern.allMatches(title.title).map((m) => m[0]).toSet();
    final years = _yearPattern
        .allMatches(name)
        .map((m) => m[0]!)
        .where((y) => !titleNumbers.contains(y))
        .map(int.parse);
    if (years.isEmpty) return true;
    // A year either side: release and air dates can straddle New Year,
    // and festival premieres come a year early.
    final first = title.year - 1;
    final last = title.type == 'tv'
        ? (title.lastAirYear ?? DateTime.now().year) + 1
        : title.year + 1;
    // A collection spanning the title's years ("The Christopher Nolan
    // Collection (2000-2023)") holds it too.
    for (final range in _yearRangePattern.allMatches(name)) {
      if (int.parse(range[1]!) <= last && int.parse(range[2]!) >= first) {
        return true;
      }
    }
    return years.any((y) => y >= first && y <= last);
  }

  /// Whether [stream] is far too small for the quality it claims, for
  /// [title]'s length — a squeezed copy labelled HD: One Piece's 74 MB
  /// "720p" episode, a third of a real one, showed as its HD size. At
  /// least 3.5 MB a minute for 720p, 5 for 1080p and 12 for 4K (squeezed
  /// but sound copies: 1080p anime episodes of 175 MB, 4K films of 1.5 GB,
  /// pass). With the length unknown, a short one's taken (20 minutes for
  /// an episode, 80 for a film), so only the plainly impossible go.
  @visibleForTesting
  static bool tooSmallFor(TorrentStream stream, Movie? title) {
    final mb = _sizeInMB(stream.size);
    if (mb == null) return false;
    final perMinute = const {4: 12.0, 3: 5.0, 2: 3.5}[tierOf(stream)];
    if (perMinute == null) return false;
    final minutes =
        minutesOf(title?.runtime) ?? (title?.type == 'movie' ? 80 : 20);
    return mb < perMinute * minutes;
  }

  /// A runtime as TMDB's given ("24m", "1h 48m") in minutes; null if none.
  @visibleForTesting
  static int? minutesOf(String? runtime) {
    if (runtime == null) return null;
    final h = int.tryParse(RegExp(r'(\d+)\s*h').firstMatch(runtime)?[1] ?? '');
    final m = int.tryParse(RegExp(r'(\d+)\s*m').firstMatch(runtime)?[1] ?? '');
    if (h == null && m == null) return null;
    final total = (h ?? 0) * 60 + (m ?? 0);
    return total > 0 ? total : null;
  }

  /// Whether a release [name] is of another show called the same as
  /// [showTitle]: right after the name it gives a year (release names'
  /// way of telling such shows apart: "One.Piece.2023.S02E03") that isn't
  /// the year [startYear] the show began, give or take one. Torrentio filed
  /// the live-action One Piece (2023) under the anime's season 2 episode 3,
  /// the anime's episode 11 by IMDb's numbering; the anime has aired since
  /// 1999, so the year alone was within its years, and a reconnect landed
  /// on the live-action show. "One Piece (1999-2000) s01e01" still fits.
  @visibleForTesting
  static bool namesAnotherShow(String name,
      {required String showTitle, required int startYear}) {
    String words(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r"['’]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    final show = words(showTitle);
    if (show.isEmpty) return false;
    final release = ' ${words(name)} ';
    for (final m in RegExp(' ${RegExp.escape(show)} ' r'((?:19|20)\d\d) ')
        .allMatches(release)) {
      if ((int.parse(m[1]!) - startYear).abs() > 1) return true;
    }
    return false;
  }

  /// Starting from the highest available quality tier, keep stepping down
  /// a tier as long as that tier costs disproportionately more size than
  /// what's available one tier down — this is what "all the 1080p options
  /// are too big, I'll take 720p instead" looks like as a rule. Stops as
  /// soon as a tier's size premium looks reasonable, or size data is
  /// missing (in which case we don't second-guess and keep the tier).
  int? _recommendedTierRank(List<TorrentStream> streams) {
    if (streams.isEmpty) return null;

    // Only weigh releases with English audio when there are any — a
    // quality available only in other languages shouldn't be recommended.
    final english = streams.where((s) => languageRank(s) < 2).toList();
    final pool = english.isEmpty ? streams : english;

    // Best (smallest) size per tier, only counting candidates that actually
    // report seeders — an unseeded torrent isn't a real "deal", it's a risk.
    final bestSizePerTier = <int, double>{};
    final tiersPresent = <int>{};
    for (final s in pool) {
      final tier = tierOf(s);
      tiersPresent.add(tier);
      if ((s.seeders ?? 0) <= 0) continue;
      final mb = _sizeInMB(s.size);
      if (mb == null) continue;
      final existing = bestSizePerTier[tier];
      if (existing == null || mb < existing) bestSizePerTier[tier] = mb;
    }

    final ordered = tiersPresent.toList()..sort((a, b) => b.compareTo(a));
    // 4K is never the recommendation when there's anything else: the next
    // best quality looks much the same on most screens, for a fraction of
    // the download. It's still listed for whoever wants it.
    int chosen = ordered.first == 4 && ordered.length > 1 ? 1 : 0;
    while (chosen < ordered.length - 1) {
      final currentSize = bestSizePerTier[ordered[chosen]];
      final nextSize = bestSizePerTier[ordered[chosen + 1]];
      if (currentSize != null &&
          nextSize != null &&
          currentSize > nextSize * _sizeJumpThreshold) {
        chosen++;
      } else {
        break;
      }
    }
    return ordered[chosen];
  }

  /// Final per-stream score: the recommended tier always sorts above every
  /// other tier; within it (and when ranking the rest), English audio,
  /// quality and seeders still matter, with size as a light tie-breaker —
  /// smaller wins between otherwise-similar options.
  double _score(TorrentStream stream, int? recommendedTier) {
    final tier = tierOf(stream);
    final recommendedBonus =
        (recommendedTier != null && tier == recommendedTier) ? 10000.0 : 0.0;
    // Outweighs any seeder difference (capped at 500) within a tier.
    final languagePenalty = languageRank(stream) * 600.0;
    final seederScore = (stream.seeders ?? 0).clamp(0, 500).toDouble();
    final sizeMB = _sizeInMB(stream.size);
    final sizePenalty = sizeMB != null ? sizeMB / 1000 : 0.0;
    return recommendedBonus +
        tier * 1000 -
        languagePenalty +
        seederScore -
        sizePenalty;
  }

  /// Flags that say which language the audio is in, by TMDB code. Not
  /// India's or China's: those stand for several (Torrentio marks Hindi,
  /// Tamil and Telugu all with India's — see [_maybeByFlag]).
  static const _flagLanguages = {
    '🇬🇧': 'en', '🇺🇸': 'en', '🇩🇪': 'de', '🇫🇷': 'fr', '🇪🇸': 'es',
    '🇲🇽': 'es', '🇮🇹': 'it', '🇵🇹': 'pt', '🇧🇷': 'pt', '🇷🇺': 'ru',
    '🇯🇵': 'ja', '🇰🇷': 'ko', '🇱🇰': 'si',
  };

  /// Flags that stand for one of several languages.
  static const _maybeByFlag = {
    '🇮🇳': {'hi', 'ta', 'te'},
    '🇨🇳': {'zh', 'cn'},
    '🇹🇼': {'zh', 'cn'},
    '🇭🇰': {'zh', 'cn'},
  };

  /// Words in release names that say which language the audio is in, by
  /// TMDB code: the full name anywhere, any case; the short code ("HIN",
  /// "MAL") in capitals, or any case inside brackets ("[ Hin Mal ]").
  /// With the misspellings release names use: Trance's best-shared
  /// Malayalam copy says "[ Hin Tel Malyalam ]", and was never offered.
  static const _audioNames = <(String, String, String?)>[
    ('en', 'English', 'ENG'),
    ('hi', 'Hindi', 'HIN'),
    ('ml', 'Malayalam|Malyalam|Malayalm|Malyalm|Malayallam', 'MAL'),
    ('ta', 'Tamil', 'TAM'),
    ('te', 'Telugu|Telgu|Telegu', 'TEL'),
    ('kn', 'Kannada|Kanada', 'KAN'),
    ('bn', 'Bengali', null),
    ('mr', 'Marathi', null),
    ('si', 'Sinhala', null),
    ('de', 'German|Deutsch', 'GER'),
    ('fr', 'French|TrueFrench|VFF|VFQ|VF2', 'FRE'),
    ('es', 'Spanish|Castellano|Latino', 'SPA|ESP'),
    ('it', 'Italian', 'ITA'),
    ('pt', 'Portuguese', 'POR'),
    ('ru', 'Russian', 'RUS'),
    ('ja', 'Japanese', 'JPN|JAP'),
    ('ko', 'Korean', 'KOR'),
    ('zh', 'Chinese|Mandarin', 'CHI'),
    ('cn', 'Cantonese', null),
  ];

  static RegExp _word(String words, {bool anyCase = true}) => RegExp(
      // Not when it's the subtitles' language ("English Subs", "ENG-SUB").
      '(?<![A-Za-z])(?:$words)(?![A-Za-z])(?![ ._-]?[Ss][Uu][Bb])',
      caseSensitive: !anyCase);

  static final _audioPatterns = [
    for (final (code, full, short) in _audioNames)
      (
        code,
        _word(full),
        short == null ? null : _word(short, anyCase: false),
        short == null ? null : _word(short),
      ),
  ];

  static final _bracketed = RegExp(r'\[[^\]]*\]|\([^)]*\)');
  static final _multiInName =
      RegExp(r'(?<![A-Za-z])(multi|dual)[ ._-]?audio', caseSensitive: false);

  /// The languages [stream]'s release name says its audio is in (TMDB
  /// codes) — leaving out the title's own words.
  static Set<String> audioNamedIn(TorrentStream stream) {
    var name = stream.name.replaceAll(RegExp(r'[._]'), ' ');
    final titleName = stream.wantedAudio?.titleName.trim() ?? '';
    if (titleName.isNotEmpty) {
      name = name.replaceAll(
          RegExp(RegExp.escape(titleName), caseSensitive: false), ' ');
    }
    final bracketed = _bracketed.allMatches(name).map((m) => m[0]!).join(' ');
    return {
      for (final (code, full, short, shortAnyCase) in _audioPatterns)
        if (full.hasMatch(name) ||
            (short?.hasMatch(name) ?? false) ||
            (shortAnyCase?.hasMatch(bracketed) ?? false))
          code,
    };
  }

  static final _flagPattern =
      RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);
  static final _multiAudioPattern =
      RegExp(r'(multi|dual) audio', caseSensitive: false);

  // An AVI file (or the XviD / DivX video that comes in one).
  static final _aviPattern = RegExp(
      r'\.avi(?![A-Za-z0-9])|(?<![A-Za-z])(xvid|divx)(?![A-Za-z])',
      caseSensitive: false);

  /// Whether [stream] is an AVI file, whose soundtracks rarely say which
  /// language they're in — so the player can't pick the wanted one.
  static bool isAvi(TorrentStream stream) =>
      _aviPattern.hasMatch(stream.title) || _aviPattern.hasMatch(stream.name);

  /// The language flags on [stream]'s languages line.
  static Set<String> flagsOf(TorrentStream stream) =>
      _flagPattern.allMatches(stream.languages).map((m) => m[0]!).toSet();

  /// Whether [stream] is marked as having audio in the language with
  /// [flags], in a file the player can pick it from.
  static bool hasMarkedAudio(TorrentStream stream, Set<String> flags) {
    if (flags.isEmpty || !flagsOf(stream).any(flags.contains)) return false;
    return flagsOf(stream).length == 1 || !isAvi(stream);
  }

  /// How well [stream]'s audio suits the language wanted
  /// ([TorrentStream.wantedAudio]: English, unless it's a title made in
  /// another language and that's the one chosen) — lower is better. What
  /// it's in comes from its flags (Torrentio's languages line) and the
  /// languages its release name names ([audioNamedIn]):
  ///  0 — that language only — or, saying nothing, the title's own
  ///  1 — that language among others, the player picking it (see
  ///      PlayerScreen's 'alang'); or India's flag alone, wanting Hindi,
  ///      Tamil or Telugu, which it stands for
  ///  2 — not that language, or not one the player can pick: several
  ///      soundtracks in an AVI file. Never offered (see
  ///      [getAvailableStreams])
  static int languageRank(TorrentStream stream) {
    final wanted = stream.wantedAudio?.language ?? 'en';
    final own = stream.wantedAudio?.titleLanguage ?? 'en';
    final flags = flagsOf(stream);
    // The languages it says it's in, by its flags and its name.
    final heard = {
      ...audioNamedIn(stream),
      for (final f in flags)
        if (_flagLanguages[f] != null) _flagLanguages[f]!,
    };
    // One of several, by a flag that stands for more than one — unless
    // its name says which.
    final maybe = <String>{
      for (final f in flags)
        if (_maybeByFlag[f] case final some? when !heard.any(some.contains))
          ...some,
    };
    final multi = _multiAudioPattern.hasMatch(stream.languages) ||
        _multiInName.hasMatch(stream.name);
    // Several soundtracks in an AVI file: the player can't tell which is
    // which (The Mentalist's Russian "rus + eng" DVD rip played Russian).
    final several = multi || heard.length + (maybe.isEmpty ? 0 : 1) > 1;
    final pickable = !(several && isAvi(stream));

    // Says nothing: in the title's own language — or, marked as having
    // several soundtracks, it among them. Never another: Aavesham's
    // unmarked Malayalam copies played when English was picked.
    if (heard.isEmpty && maybe.isEmpty) {
      if (wanted != own) return 2;
      if (!multi) return 0;
      return pickable ? 1 : 2;
    }
    if (heard.contains(wanted)) {
      if (!several) return 0;
      return pickable ? 1 : 2;
    }
    // India's flag, wanting Hindi, Tamil or Telugu: it may well be.
    if (maybe.contains(wanted)) return pickable ? 1 : 2;
    return 2;
  }

  static int tierOf(TorrentStream stream) {
    final q = stream.quality?.toLowerCase() ?? '';
    if (q.contains('4k') || q.contains('2160')) return 4;
    if (q.contains('1080')) return 3;
    if (q.contains('720')) return 2;
    if (q.contains('480')) return 1;
    return 0; // CAM/HDRip/unknown
  }

  /// Groups [streams] (as sorted by [getAvailableStreams]) into one option
  /// per quality, highest quality first. Within a quality, torrents with a
  /// healthy number of sharers come first — single episodes before season
  /// packs, then smallest first, the same picture for less to download —
  /// then the rest by sharers.
  /// [preferHash] (the last-played torrent) is put first in its quality
  /// regardless, so resuming reuses what's already downloaded.
  static List<QualityOption> qualityOptions(
    List<TorrentStream> streams, {
    String? preferHash,
  }) {
    final byTier = <int, List<TorrentStream>>{};
    for (final s in streams) {
      byTier.putIfAbsent(tierOf(s), () => []).add(s);
    }

    final tiers = byTier.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final tier in tiers)
        QualityOption(tier, _bestFirst(byTier[tier]!, preferHash)),
    ];
  }

  /// What Play most likely starts from [streams] (as sorted by
  /// [getAvailableStreams]): the last-played torrent when it's among them,
  /// otherwise the best copy of the recommended quality — the popup's
  /// highlighted row either way.
  ///
  /// With [preferTier] (the quality being watched, for the next episode),
  /// the best copy of that quality instead when there is one.
  static TorrentStream? likelyPick(
    List<TorrentStream> streams, {
    String? lastPlayedHash,
    int? preferTier,
  }) {
    if (streams.isEmpty) return null;
    if (lastPlayedHash != null) {
      for (final s in streams) {
        if (s.infoHash.toLowerCase() == lastPlayedHash.toLowerCase()) return s;
      }
    }
    final options = qualityOptions(streams);
    if (preferTier != null) {
      for (final o in options) {
        if (o.tier == preferTier) return o.best;
      }
    }
    final tier = tierOf(streams.first);
    return options.firstWhere((o) => o.tier == tier).best;
  }

  /// What a head start (see [warmUp]) races, from [streams]: the
  /// [likelyPick] and the next two of its quality — sharer counts are often
  /// stale, so the pick may have no one sharing it. Just the last-played
  /// torrent when there is one: resuming wants that one, with what it has
  /// downloaded.
  static List<TorrentStream> headStartCandidates(
    List<TorrentStream> streams, {
    String? lastPlayedHash,
    int? preferTier,
  }) {
    final pick = likelyPick(streams,
        lastPlayedHash: lastPlayedHash, preferTier: preferTier);
    if (pick == null) return const [];
    if (lastPlayedHash != null &&
        pick.infoHash.toLowerCase() == lastPlayedHash.toLowerCase()) {
      return [pick];
    }
    return sameQuality(pick, streams).take(3).toList();
  }

  /// The torrents to try when [stream] is picked: [stream] itself, then the
  /// rest of [all] that share its quality, best first — so a failed start
  /// falls back to the same quality rather than a lower one.
  static List<TorrentStream> sameQuality(
    TorrentStream stream,
    List<TorrentStream> all,
  ) {
    final tier = tierOf(stream);
    return [
      stream,
      ..._bestFirst(all.where((s) => tierOf(s) == tier).toList(), null)
          .where((s) => s.infoHash != stream.infoHash),
    ];
  }

  // AV1 in a release name: "AV1", "AV1-GROUP", not inside another word.
  static final _av1Pattern =
      RegExp(r'(?<![A-Za-z0-9])av1(?![A-Za-z0-9])', caseSensitive: false);

  /// How hard [stream]'s video is to decode — lower is easier. For now only
  /// AV1 is marked down (1): many phones, the S10 among them, have no AV1
  /// decoder in hardware, and software decoding stutters. Others may follow
  /// once tested on a device (x265 10-bit, Dolby Vision without HDR).
  static int codecRank(TorrentStream stream) =>
      _av1Pattern.hasMatch(stream.name) ? 1 : 0;

  /// "Healthy" means at least this many sharers, or a fifth of the
  /// best-shared torrent of the same quality if that's more — seed counts
  /// are only rough, so this just weeds out the barely-shared ones.
  static const int _minHealthySeeders = 5;

  static List<TorrentStream> _bestFirst(
    List<TorrentStream> group,
    String? preferHash,
  ) {
    final maxSeeds = group.fold<int>(0, (m, s) => math.max(m, s.seeders ?? 0));
    final floor = math.max(_minHealthySeeders, (maxSeeds * 0.2).round());
    bool healthy(TorrentStream s) => (s.seeders ?? 0) >= floor;

    // Index tie-break keeps the incoming (score) order between equals —
    // List.sort isn't stable.
    final indexed = group.asMap().entries.toList();
    indexed.sort((a, b) {
      final sa = a.value, sb = b.value;
      if (preferHash != null) {
        final pa = sa.infoHash.toLowerCase() == preferHash.toLowerCase();
        final pb = sb.infoHash.toLowerCase() == preferHash.toLowerCase();
        if (pa != pb) return pa ? -1 : 1;
      }
      // No English audio goes last whatever its sharers.
      final la = languageRank(sa), lb = languageRank(sb);
      if ((la == 2) != (lb == 2)) return la == 2 ? 1 : -1;
      // Then a healthy copy before a barely-shared one, even if the healthy
      // one also has other languages: the player picks the English track,
      // and a copy with 2,000 sharers starts far sooner than one with 300.
      // (Matchbox's best Full HD copy lists a dozen languages and was
      // ranked below every English-only one.)
      final ha = healthy(sa), hb = healthy(sb);
      if (ha != hb) return ha ? -1 : 1;
      if (la != lb) return la.compareTo(lb);
      if (ha) {
        // A torrent of just this episode before a season pack: it starts
        // sooner, as there's only one file's metadata to fetch.
        if (sa.isPack != sb.isPack) return sa.isPack ? 1 : -1;
        // Smallest first favours the hardest encodes to decode (see
        // codecRank): an easier one goes before them whatever its size.
        final ca = codecRank(sa), cb = codecRank(sb);
        if (ca != cb) return ca.compareTo(cb);
        // Unknown sizes go after known ones.
        final ma = _sizeInMB(sa.size) ?? double.infinity;
        final mb = _sizeInMB(sb.size) ?? double.infinity;
        if (ma != mb) return ma.compareTo(mb);
      } else {
        final c = (sb.seeders ?? 0).compareTo(sa.seeders ?? 0);
        if (c != 0) return c;
      }
      return a.key.compareTo(b.key);
    });
    return [for (final e in indexed) e.value];
  }

  static double? _sizeInMB(String? size) {
    if (size == null) return null;
    final match = RegExp(r'^([\d.]+)\s*(TB|GB|MB)$', caseSensitive: false)
        .firstMatch(size.trim());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    switch (match.group(2)!.toUpperCase()) {
      case 'TB':
        return value * 1024 * 1024;
      case 'GB':
        return value * 1024;
      default:
        return value; // MB
    }
  }

  /// Resolve a specific torrent to a playable local URL.
  Future<StreamResult> resolve(TorrentStream selected) async {
    return await _engine.streamMagnet(
      selected.infoHash,
      fileIndex: selected.fileIdx,
      trackers: selected.trackers,
    );
  }

  /// Gives what Play will most likely start a head start: races
  /// [candidates] (see [headStartCandidates]) and starts downloading the
  /// first to connect — from [resumeAt] (0–1) when it's being resumed — so
  /// pressing Play starts it at once. See [TorrentEngineService.warmUp].
  void warmUp(List<TorrentStream> candidates, {double? resumeAt}) =>
      _engine.warmUp([
        for (final s in candidates)
          (infoHash: s.infoHash, trackers: s.trackers, fileIndex: s.fileIdx),
      ], resumeAt: resumeAt);

  /// Ends a [warmUp] Play didn't take — see [TorrentEngineService.coolDown].
  Future<void> coolDown(List<TorrentStream> candidates) =>
      _engine.coolDown([for (final s in candidates) s.infoHash]);

  /// How long a copy gets to connect on its own before the next one is
  /// started alongside it. A healthy top pick usually connects within a
  /// couple of seconds and so still wins; a dead one now costs this long
  /// rather than its full 20s timeout.
  static const _headStart = Duration(seconds: 3);

  /// [streams] without the copies too big for the space the device has
  /// left (see [FreeSpace.fits]); what's already downloaded of one counts
  /// as room. Everything stays when the space can't be read.
  Future<List<TorrentStream>> _thatFit(List<TorrentStream> streams) async {
    final free = await FreeSpace.bytes();
    if (free == null) return streams;
    var registry = const <String, TorrentDownloadInfo>{};
    try {
      registry = await TorrentDownloadRegistry.loadAll();
    } catch (_) {}
    return streams.where((s) {
      final have = registry[s.infoHash.toLowerCase()]?.downloadedBytes ?? 0;
      return FreeSpace.fits(
        sizeBytes: TorrentDownloadRegistry.parseSizeBytes(s.size),
        haveBytes: have,
        freeBytes: free,
      );
    }).toList();
  }

  /// Resolve [selected], automatically falling back to the next-best
  /// candidates in [allStreams] if it's slow, fails or times out.
  /// Torrentio's seed counts are scraped/cached and often stale — a
  /// "67 seeds" pick can turn out unreachable while a "0 seeds" one streams
  /// fine — so one failed attempt shouldn't be a dead end the user has to
  /// manually recover from.
  ///
  /// The candidates race rather than take turns: [selected] starts first,
  /// each next one [_headStart] later (or as soon as one fails), and the
  /// first to connect plays. The others are paused, or removed when they
  /// time out.
  ///
  /// Once [isCancelled] returns true, no further candidates are tried, a
  /// torrent that connected meanwhile is paused (keeping what it
  /// downloaded), and [ResolveCancelledException] is thrown.
  Future<StreamResolveResult> resolveWithFallback(
    TorrentStream selected,
    List<TorrentStream> allStreams, {
    // Six, not three: a regional film's copies are thinly shared and their
    // seed counts stale — Trance's first three HD copies all had no one
    // sharing them. A hopeless case now gives up after ~35 s, not ~26.
    int maxAttempts = 6,
    bool Function()? isCancelled,
    // What's being played, to look inside each copy for (see
    // [insideProblem]).
    Movie? title,
  }) async {
    var ordered = [
      selected,
      ...allStreams.where((s) =>
          s.infoHash.toLowerCase() != selected.infoHash.toLowerCase()),
    ];
    ordered = await _thatFit(ordered);
    if (ordered.isEmpty) throw const NotEnoughSpaceException();
    // The copy a head start is already downloading (see warmUp) goes
    // first — it starts at once — then others it connected to, where
    // [selected] may be the one the head start found no one sharing. All
    // three of The Mentalist's had their metadata in, so "connected" put
    // the top pick (no one sharing it) ahead of the one downloading, and
    // playback waited two minutes.
    final candidates = [
      ...ordered.where((s) => _engine.hasHeadStart(s.infoHash)),
      ...ordered.where((s) =>
          !_engine.hasHeadStart(s.infoHash) && _engine.isReady(s.infoHash)),
      ...ordered.where((s) => !_engine.isReady(s.infoHash)),
    ].take(maxAttempts).toList();
    bool cancelled() => isCancelled?.call() ?? false;
    if (cancelled()) throw const ResolveCancelledException();

    final stopwatch = Stopwatch()..start();
    final outcome = Completer<StreamResolveResult>();
    var started = 0;
    var failed = 0;

    void startNext() {
      if (outcome.isCompleted || started >= candidates.length) return;
      final candidate = candidates[started++];
      final number = started;
      // A connection that fails cleans up its own torrent (see
      // TorrentEngineService.connect) — nothing to dispose here.
      _engine.connect(candidate.infoHash, trackers: candidate.trackers).then(
          (id) async {
        if (outcome.isCompleted) {
          // Lost the race, or the user gave up: stop it, keeping what it
          // has, unless it's what's playing; and out of the session unless
          // it's a saved download or a head start's.
          unawaited(_engine.dropLoser(id));
          return;
        }
        if (cancelled()) {
          _engine.pause(id);
          outcome.completeError(const ResolveCancelledException());
          return;
        }
        try {
          // Its files, before a byte of video: another film's, or a
          // program, and it's a failed start — the next copy goes.
          final problem =
              insideProblem(_engine.filesOf(id), candidate.fileIdx, title);
          if (problem != null) {
            print('Copy $number left out: $problem');
            throw Exception(problem);
          }
          final result =
              await _engine.startStream(id, fileIndex: candidate.fileIdx);
          if (outcome.isCompleted) {
            // Another copy won (or the user gave up) while this one's
            // previous stream was closing.
            _engine.pause(id);
            unawaited(_engine.dropLoser(id));
            return;
          }
          print('[timing] copy $number of ${candidates.length} connected '
              'first, after ${stopwatch.elapsedMilliseconds} ms');
          outcome.complete(
              StreamResolveResult(stream: candidate, result: result));
        } catch (e) {
          _engine.discardFailedStart(id);
          failed++;
          if (failed == candidates.length) {
            outcome.completeError(e);
          } else {
            startNext();
          }
        }
      }, onError: (Object e) {
        if (outcome.isCompleted) return;
        failed++;
        if (failed == candidates.length) {
          print('[timing] no copy connected, gave up after '
              '${stopwatch.elapsedMilliseconds} ms');
          outcome.completeError(e);
        } else {
          // A failure brings the next copy forward.
          startNext();
        }
      });
    }

    startNext();
    var sinceLastStart = Duration.zero;
    const tick = Duration(milliseconds: 250);
    final ticker = Timer.periodic(tick, (_) {
      if (outcome.isCompleted) return;
      if (cancelled()) {
        outcome.completeError(const ResolveCancelledException());
        return;
      }
      sinceLastStart += tick;
      if (sinceLastStart >= _headStart) {
        sinceLastStart = Duration.zero;
        startNext();
      }
    });
    try {
      return await outcome.future;
    } finally {
      ticker.cancel();
    }
  }

  /// Stop a torrent — its stream and its downloading — while keeping what
  /// it downloaded, for a later resume. Use on normal player close, and for
  /// an abandoned start.
  void pause(int torrentId) => _engine.pause(torrentId);

  /// [pause] for a normal player close, that also trims the download to
  /// the last stretch watched — see [TorrentEngineService.releaseAndTrim].
  Future<void> releaseAndTrim(
    int torrentId, {
    required int fileIndex,
    required int keepFrom,
  }) =>
      _engine.releaseAndTrim(torrentId,
          fileIndex: fileIndex, keepFrom: keepFrom);

  /// Let a torrent paused by a later start download again — for going back
  /// to it when that start failed.
  void resume(int torrentId) => _engine.resume(torrentId);

  /// Cleanup after playback — deletes downloaded data. Use for abandoned
  /// mid-session switches (quality/episode change), not a normal player close.
  void cleanup(int torrentId) => _engine.cleanup(torrentId);
}
