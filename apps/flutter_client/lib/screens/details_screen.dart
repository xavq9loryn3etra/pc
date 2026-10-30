import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import '../widgets/player_route.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import '../theme/app_theme.dart';
import '../widgets/skeletons.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import '../services/scraper_service.dart';
import '../services/saved_movies_service.dart';
import '../services/feature_flags_service.dart';
import '../services/streaming_link_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/stream_resolver.dart';
import '../services/torrent/torrent_download_registry.dart';
import 'web_player/web_player.dart';
import 'player_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui'; // For BackdropFilter
import '../widgets/glass_blur.dart';
import '../widgets/artwork_glow.dart';
import '../widgets/glass_bubble_bar.dart';
import '../widgets/details_overview.dart';
import '../widgets/episode_card.dart';
import '../widgets/marquee_text.dart';
import '../widgets/quality_option_list.dart';
import '../widgets/season_picker.dart';
import '../widgets/image_precache.dart';

class DetailsScreen extends StatefulWidget {
  final Movie movie;
  final String? heroTag;
  final VoidCallback? onClose;
  final bool isSidePanel;

  const DetailsScreen({
    super.key,
    required this.movie,
    this.heroTag,
    this.onClose,
    this.isSidePanel = false,
  });

  /// Starts loading [movie]'s page ahead of it opening — its details, then
  /// its header image and logo, at the size the page will ask for — so it
  /// usually opens already filled in rather than on its skeleton. For when
  /// a finger touches its poster: the tap that opens it lands a moment
  /// later. Cheap to repeat: the details are cached, the images too.
  static Future<void> prefetch(BuildContext context, Movie movie) async {
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    try {
      final details =
          await TMDBService().prefetchDetails(movie.id, type: movie.type);
      if (details == null || !context.mounted) return;
      final header =
          _DetailsScreenState.headerImageFor(details, screen);
      if (header.isNotEmpty && !header.toLowerCase().endsWith('.svg')) {
        final decode =
            _DetailsScreenState.headerDecodeSize(details, screen, dpr);
        precacheImage(
          ResizeImage.resizeIfNeeded(decode.width, decode.height,
              CachedNetworkImageProvider(header)),
          context,
          onError: (_, __) {},
        );
      }
      final logo = _DetailsScreenState._logoUrlFor(details);
      if (logo != null && !logo.toLowerCase().endsWith('.svg')) {
        precacheImage(
          ResizeImage.resizeIfNeeded(
              (200 * dpr).toInt(), null, CachedNetworkImageProvider(logo)),
          context,
          onError: (_, __) {},
        );
      }
    } catch (_) {
      // Only a head start: the page loads it all itself anyway.
    }
  }

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  Movie? _details;
  // Movies only: the Play popup's torrents, fetched as soon as the details
  // load so the popup can list the qualities straight away (see
  // _openMovie). Null until then, or when playback is hidden.
  Future<List<TorrentStream>>? _movieStreams;
  // The other services streaming this title that have a direct link to it
  // (see _loadAlsoOn) — the "Also on" logos under the buttons.
  List<StreamingProvider> _alsoOn = const [];
  bool _loading = true;
  // Skeleton reveal stages after _loading turns false: fading out, then
  // removed (see _revealOverSkeleton).
  bool _skeletonFading = false;
  bool _skeletonDone = false;
  // Streaming-service button: a tap in progress, and the snackbar message
  // currently showing (see _openProvider / _showProviderMessage).
  bool _openingProvider = false;
  String? _providerMessage;
  final ScrollController _scrollController = ScrollController();
  // The page's vertical scroll offset, for the parallax backdrop and the
  // app bar. Fed from scroll notifications rather than a _scrollController
  // listener: when the content shrinks (e.g. the synopsis collapsing) the
  // position is corrected *without* notifying controller listeners, which
  // left the backdrop frozen at its old parallax offset. Scroll-metrics
  // notifications do report those corrections.
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0);
  // Whether the app bar shows the title logo (scrolled past 350px). Its own
  // notifier, so the app bar rebuilds only when that flips — not on every
  // scroll pixel, as when it listened to _scrollOffset.
  final ValueNotifier<bool> _showTitle = ValueNotifier(false);

  void _setScroll(double pixels) {
    _scrollOffset.value = pixels;
    _showTitle.value = pixels > 350; // title logo reveal point
  }

  bool _onPageScroll(Notification notification) {
    // depth 0 = the page's own scroll view, not nested ones (the cast row).
    if (notification is ScrollUpdateNotification &&
        notification.depth == 0) {
      _setScroll(notification.metrics.pixels);
    } else if (notification is ScrollMetricsNotification &&
        notification.depth == 0) {
      _setScroll(notification.metrics.pixels);
    }
    return false;
  }
  final Dio _shareDio = Dio();
  final CancelToken _detailsCancelToken = CancelToken();

  // TV Show State
  List<Episode> _episodes = [];
  Season? _selectedSeason;
  int? _selectedEpisode;
  bool _loadingEpisodes = false;

  Future<void> _shareMovie() async {
    final m = _details ?? widget.movie;
    const downloadUrl =
        'https://drive.google.com/drive/folders/1ftzQcKIUkB2sKwInoSdMG7-SH4rPf96i?usp=sharing';
    final smartLink =
        'https://script.google.com/macros/s/AKfycbzEwmEgC4JXWXz4TPHUUxPon_56ZN4VsOKq7FAw_3rWgRi2L4KIZAx1rs_HZ94-1h6IVg/exec?id=${m.id}&type=${m.type}';

    final message = '🍿 Watch "${m.title}" on Popcorn!\n\n'
        '📲 Tap to Play: $smartLink\n\n'
        '📥 Download App: $downloadUrl';

    try {
      // 1. Get temp directory
      final temp = await getTemporaryDirectory();
      final path = '${temp.path}/poster_${m.id}.jpg';

      // 2. Download image if it doesn't exist in temp and m.image is not null
      final file = File(path);
      if (!await file.exists() && m.image != null) {
        await _shareDio.download(m.image!, path);
      }

      if (await file.exists()) {
        // 3. Share file + text
        await Share.shareXFiles(
          [XFile(path)],
          text: message,
          subject: 'Share ${m.title}',
        );
      } else {
        // Fallback to text only
        Share.share(message, subject: 'Share ${m.title}');
      }
    } catch (e) {
      // Fallback to text only if image download fails
      Share.share(message, subject: 'Share ${m.title}');
    }
  }

  @override
  void initState() {
    super.initState();
    FeatureFlagsService().hidePlayback.addListener(_onFlagsChanged);
    _loadDetails();
  }

  void _onFlagsChanged() {
    if (mounted) setState(() {});
  }

  // No local _isFavorite field/setState needed — toggleFavorite() below
  // calls notifyListeners(), and the like button already reads
  // SavedMoviesService().isFavorite(...) directly inside the
  // ListenableBuilder(listenable: SavedMoviesService()) further down, so it
  // updates on its own without a second, full-screen rebuild.
  Future<void> _toggleFavorite() async {
    await SavedMoviesService().toggleFavorite(_details ?? widget.movie);
  }

  Future<void> _openTrailer(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Opens the streaming service's page for this title — in its app when
  /// installed (Android App Links / iOS Universal Links), else the browser.
  /// Opens this title in the streaming service's own app — and nowhere
  /// else. Never falls back to TMDB, a search page or a browser: if there's
  /// no direct link for the title, or no app on the device can open it, the
  /// user is told instead.
  Future<void> _openProvider(StreamingProvider provider) async {
    // Ignore taps while one is still resolving / launching.
    if (_openingProvider) return;
    _openingProvider = true;
    try {
      await _openProviderNow(provider);
    } finally {
      _openingProvider = false;
    }
  }

  Future<void> _openProviderNow(StreamingProvider provider) async {
    final m = _details ?? widget.movie;
    // Usually already resolved and cached by the prefetch in _loadDetails.
    final url = m.wikidataId == null
        ? null
        : await StreamingLinkService()
            .directUrl(
              wikidataId: m.wikidataId!,
              providerId: provider.id,
              isTv: m.type == 'tv',
            )
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (!mounted) return;
    if (url == null) {
      // The title is on the service (per TMDB / JustWatch) — there's just
      // no direct link to it yet, so point the user to the app instead.
      _showProviderMessage(
          '${m.title} is on ${provider.name}. Open the ${provider.name} app '
          'to watch it.');
      return;
    }

    var opened = false;
    try {
      // Non-browser only: the OS opens the link in the service's app, or
      // refuses (returns false / throws) rather than falling back to a
      // browser.
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalNonBrowserApplication,
      );
    } catch (e) {
      debugPrint('Failed to open ${provider.name}: $e');
    }
    if (!opened && mounted) {
      _showProviderMessage(
          "Couldn't open ${provider.name}. Make sure the app is installed.");
    }
  }

  void _showProviderMessage(String message) {
    // Repeated taps leave the snackbar that's already up alone instead of
    // dismissing and re-showing it each time.
    if (_providerMessage == message) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _providerMessage = message;
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(SnackBar(content: Text(message)))
        .closed
        .then((_) {
      if (_providerMessage == message) _providerMessage = null;
    });
  }

  /// Splits the Play pill so [provider]'s logo sits at its right end,
  /// behind a thin divider; unchanged when there's no provider. Either way
  /// the pill's ripples are hosted by a _PillInk.
  /// Works out which of [m]'s other streaming services ("Also on") can
  /// open it directly — only those get a logo, so none of them is a dead
  /// button. One Wikidata lookup covers every service, and it's usually
  /// already in flight from the main service's prefetch.
  Future<void> _loadAlsoOn(Movie m) async {
    final others = m.otherStreamingProviders;
    final wikidataId = m.wikidataId;
    if (others.isEmpty || wikidataId == null) return;
    final urls = await Future.wait([
      for (final p in others)
        StreamingLinkService().directUrl(
          wikidataId: wikidataId,
          providerId: p.id,
          isTv: m.type == 'tv',
        ),
    ]);
    if (!mounted) return;
    setState(() => _alsoOn = [
          for (var i = 0; i < others.length; i++)
            if (urls[i] != null) others[i],
        ]);
  }

  /// The quiet line under the buttons: "Also on [logo] [logo] · " — the
  /// other services streaming this title, each opening it in its own app
  /// like the main service's button — then the JustWatch credit TMDB
  /// requires for watch-provider data.
  Widget _buildStreamingCredit() {
    final style = TextStyle(
      fontSize: 11,
      color: Colors.white.withValues(alpha: 0.4),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        if (_alsoOn.isNotEmpty) ...[
          Text('Also on', style: style),
          const SizedBox(width: 4),
          for (final p in _alsoOn)
            Tooltip(
              message: 'Watch on ${p.name}',
              child: InkWell(
                onTap: () => _openProvider(p),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: ProviderLogo(provider: p, size: 20),
                ),
              ),
            ),
          Text('  ·  ', style: style),
        ],
        Text('Streaming info by JustWatch', style: style),
      ],
    );
  }

  Widget _withProviderSegment(StreamingProvider? provider, Widget play) {
    if (provider == null) return _PillInk(child: play);
    return _PillInk(
      // Stretch so both tap targets fill the pill's full height, not just
      // the strip their content occupies.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: play),
          Center(
            child: Container(width: 1, height: 26, color: Colors.black12),
          ),
          InkWell(
            onTap: () => _openProvider(provider),
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(30)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
              child: Center(
                child: ProviderLogo(provider: provider, size: 28),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // The movie's likely picks, connecting ahead of Play (see _warmUpMovie).
  List<TorrentStream> _warmedStreams = const [];

  /// Gives the copy Play will most likely start a head start, once
  /// [streams] are found — it connects, and on Wi-Fi starts downloading,
  /// while the user reads the page, so Play starts at once (see
  /// StreamResolver.warmUp). From where it was left off, when it's being
  /// resumed.
  Future<void> _warmUpMovie(
    String imdbId,
    Future<List<TorrentStream>> streams,
  ) async {
    final list = await streams;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _warmedStreams = StreamResolver.headStartCandidates(
      list,
      lastPlayedHash: prefs.getString('last_played_torrent_$imdbId'),
    );
    StreamResolver().warmUp(
      _warmedStreams,
      resumeAt:
          SavedMoviesService().getMovieFromHistory(widget.movie.id)?.progress,
    );
  }

  @override
  void dispose() {
    StreamResolver().coolDown(_warmedStreams);
    // Aborts the in-flight TMDB request if the screen is closed before it
    // resolves, instead of letting it finish (and get silently discarded)
    // in the background — saves bandwidth/battery on a quick back-out.
    _detailsCancelToken.cancel();
    _scrollController.dispose();
    _scrollOffset.dispose();
    _showTitle.dispose();
    FeatureFlagsService().hidePlayback.removeListener(_onFlagsChanged);
    super.dispose();
  }

  // The header images, shared by build() and _preloadHeader() so the
  // preload warms exactly what the screen will request. Full-resolution
  // sources: the header is large enough that TMDB's standard tiers look soft.
  static String _backdropUrlFor(Movie m) =>
      m.backdropHighRes ?? m.backdrop ?? m.posterUrl ?? '';

  /// Whether the header shows [m]'s textless poster rather than its
  /// backdrop: on a phone's tall header, as Apple TV does with its key art.
  /// A wide backdrop there shows only its middle half — about half its
  /// detail, with the subject often cut off. Wide screens keep the backdrop.
  static bool usesPosterHeader(Movie m, Size screen, {bool sidePanel = false}) =>
      m.textlessPoster != null && !sidePanel && screen.width / _headerHeight < 1.2;

  static String headerImageFor(Movie m, Size screen, {bool sidePanel = false}) =>
      usesPosterHeader(m, screen, sidePanel: sidePanel)
          ? m.textlessPosterHighRes!
          : _backdropUrlFor(m);

  /// The size to decode the header image at: one side only (see build()) —
  /// the poster by the screen's width, which it fills, a backdrop by the
  /// header's height.
  static ({int? width, int? height}) headerDecodeSize(
    Movie m,
    Size screen,
    double dpr, {
    bool sidePanel = false,
  }) =>
      usesPosterHeader(m, screen, sidePanel: sidePanel)
          ? (width: (screen.width * dpr).toInt(), height: null)
          : (width: null, height: (_headerHeight * dpr).toInt());

  bool _usesPosterHeader(Movie m) => usesPosterHeader(
      m, MediaQuery.sizeOf(context),
      sidePanel: widget.isSidePanel);

  String _headerImageFor(Movie m) => headerImageFor(
      m, MediaQuery.sizeOf(context),
      sidePanel: widget.isSidePanel);

  /// How far below the header image its glow (see ArtworkGlow) runs
  /// before it has faded to black: past the title, buttons and synopsis.
  static const double _glowHeight = 270;

  /// The header image's height. Tall, so the title, buttons and synopsis
  /// below it sit low on the picture, as on Apple TV.
  static const double _headerHeight = 520;

  ({int? width, int? height}) _headerDecodeSize(Movie m) => headerDecodeSize(
      m, MediaQuery.sizeOf(context), MediaQuery.devicePixelRatioOf(context),
      sidePanel: widget.isSidePanel);

  static String? _logoUrlFor(Movie m) =>
      m.logoUrl == null ? null : (m.logoHighRes ?? m.logoUrl!);

  // Longest the skeleton waits on header images / the first season before
  // showing the page anyway; anything slower finishes loading in place.
  static const _maxPreloadWait = Duration(seconds: 4);

  Future<void> _loadDetails() async {
    Movie? d;
    try {
      d = await TMDBService().getDetails(
        widget.movie.id,
        type: widget.movie.type,
        cancelToken: _detailsCancelToken,
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) return;
      rethrow;
    }
    if (!mounted) return;

    // Resolve the streaming service's direct link in the background now, so
    // it's ready (and cached) before its button is tapped — see
    // _openProvider.
    final loaded = d ?? widget.movie;
    final provider = loaded.streamingProvider;
    if (provider != null &&
        loaded.wikidataId != null &&
        StreamingLinkService().supports(provider.id)) {
      StreamingLinkService().prefetch(
        wikidataId: loaded.wikidataId!,
        providerId: provider.id,
        isTv: loaded.type == 'tv',
      );
    }
    // Waited for below with the rest, so the "Also on" row is there when
    // the page appears instead of popping in after.
    final alsoOn = _loadAlsoOn(loaded);

    // Still behind the skeleton (_loading stays true): store the details
    // and pick the starting season, then keep the skeleton up while the
    // header images and first season's episodes load, so the page appears
    // complete instead of filling in piece by piece.
    setState(() {
      _details = d ?? widget.movie;

      // Look the movie's torrents up in the background now, rather than
      // when Play is pressed — Torrentio can take several seconds.
      if (_details!.type == 'movie' &&
          !FeatureFlagsService().hidePlayback.value) {
        _movieStreams = StreamResolver().getAvailableStreams(
          imdbId: _details!.imdbId ?? _details!.id,
          type: _details!.type,
          title: _details,
        );
        _warmUpMovie(_details!.imdbId ?? _details!.id, _movieStreams!);
      }

      // Init Season 1 if TV
      if (_details?.type == 'tv' &&
          _details?.seasons != null &&
          _details!.seasons!.isNotEmpty) {
        _selectedSeason = _details!.seasons!.firstWhere(
          (s) => s.seasonNumber == 1,
          orElse: () => _details!.seasons!.firstWhere(
            (s) => s.seasonNumber > 0,
            orElse: () => _details!.seasons!.first,
          ),
        );
      }
    });

    try {
      await Future.wait([
        _preloadHeader(_details!),
        if (_selectedSeason != null)
          _loadSeasonDetails(_selectedSeason!.seasonNumber),
        alsoOn,
      ]).timeout(_maxPreloadWait);
    } catch (_) {
      // Timed out or an image failed: show the page regardless.
    }

    if (!mounted) return;
    // Build the page under the skeleton, give it a few frames to settle,
    // then fade the skeleton off it (see _revealOverSkeleton).
    setState(() => _loading = false);
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _skeletonFading = true);
  }

  /// Downloads and decodes the header backdrop and logo into Flutter's
  /// image cache, keyed exactly as the CachedNetworkImage widgets in
  /// build() will look them up (same URL and memCache size), so they
  /// paint on the first frame.
  Future<void> _preloadHeader(Movie m) async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final backdrop = _headerImageFor(m);
    final logo = _logoUrlFor(m);
    final jobs = <Future<void>>[];
    // SVGs render through SvgPicture, not the image cache — skip them.
    if (backdrop.isNotEmpty && !backdrop.toLowerCase().endsWith('.svg')) {
      final decode = _headerDecodeSize(m);
      jobs.add(precacheImage(
        ResizeImage.resizeIfNeeded(
          decode.width,
          decode.height,
          CachedNetworkImageProvider(backdrop),
        ),
        context,
      ));
    }
    if (logo != null && !logo.toLowerCase().endsWith('.svg')) {
      jobs.add(precacheImage(
        ResizeImage.resizeIfNeeded(
          (200 * dpr).toInt(),
          null,
          CachedNetworkImageProvider(logo),
        ),
        context,
      ));
    }
    // The movie popup's blurred background (see _openMovie): the same
    // backdrop decoded tiny — nearly free once it's downloaded — so the
    // popup doesn't open on the bare dark fallback and fill in after.
    if (m.type != 'tv') {
      jobs.add(precacheNetworkImage(
        context,
        backdrop,
        cacheWidth: EpisodeBackdrop.cacheWidth,
      ));
    }
    await Future.wait(jobs);
  }

  Future<void> _loadSeasonDetails(int seasonNum) async {
    if (_details == null) return;
    setState(() => _loadingEpisodes = true);

    final episodes = await TMDBService().getSeasonDetails(
      _details!.id,
      seasonNum,
    );

    // Inject history progress
    final service = SavedMoviesService();

    final processedEpisodes = episodes.map((e) {
      final progress = service.getEpisodeProgress(
        widget.movie.id,
        seasonNum,
        e.episodeNumber,
      );

      if (progress != null) return e.withProgress(progress);
      return e;
    }).toList();

    if (mounted) {
      setState(() {
        _episodes = processedEpisodes;
        _loadingEpisodes = false;
      });
    }
  }

  /// True if the movie itself, or the currently targeted TV episode, hasn't
  /// been released yet — there's no real stream to find for content like
  /// that, no matter what an indexer might claim to have.
  bool _isSelectionUnreleased() {
    if (_details == null) return false;
    if (_details!.type != 'tv') return _details!.isUnreleased;

    if (_selectedEpisode == null) return false;
    final targetEp = _episodes.firstWhere(
      (ep) => ep.episodeNumber == _selectedEpisode,
      orElse: () => Episode(
        id: -1,
        episodeNumber: -1,
        name: '',
        overview: '',
        voteAverage: 0,
      ),
    );
    return targetEp.id != -1 && targetEp.isUnreleased;
  }

  void _showNotReleasedMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: Colors.black87,
        content: Text("This hasn't been released yet."),
      ),
    );
  }

  String _formatReleaseDate(DateTime date) =>
      "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";

  /// The episode popup (tapping an episode card): the episode in its card
  /// styling, then how to watch it — its torrents and the web servers, or,
  /// with playback hidden, a button to the streaming service carrying the
  /// show (none if there isn't one). Episodes that haven't aired yet show
  /// their info only.
  void _openEpisode(Episode ep) {
    setState(() => _selectedEpisode = ep.episodeNumber);
    final m = _details ?? widget.movie;
    final image = ep.stillPath ?? m.backdrop;
    final hidePlayback = FeatureFlagsService().hidePlayback.value;
    final header = EpisodeDetailHeader(
      episode: ep,
      fallbackImage: m.backdrop,
      progress: hidePlayback
          ? null
          : SavedMoviesService().getEpisodeProgress(
                widget.movie.id,
                _selectedSeason?.seasonNumber ?? 1,
                ep.episodeNumber,
              ) ??
              ep.progress,
    );

    if (!hidePlayback && !ep.isUnreleased) {
      _playWithTorrent(header: header, backgroundImage: image);
      return;
    }

    final provider = m.streamingProvider;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black54,
      builder: (sheetContext) => EpisodeInfoSheet(
        image: image,
        header: header,
        action: hidePlayback && provider != null
            ? _WatchOnProviderButton(
                provider: provider,
                // Close the popup first, so a "couldn't open" message shows
                // on this screen rather than hidden behind the sheet.
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openProvider(provider);
                },
              )
            : null,
      ),
    );
  }

  /// The movie's popup (the Play button): just its qualities, on the
  /// episode popup's blurred backdrop (see _openEpisode) — the details
  /// screen behind it already shows everything about the movie.
  void _openMovie() {
    // The header's own image, preloaded tiny in _preloadHeader — not the
    // backdrop when the header shows the poster: that's never downloaded,
    // and the popup's background waited on it.
    final backdrop = _headerImageFor(_details ?? widget.movie);
    _playWithTorrent(
      backgroundImage: backdrop.isEmpty ? null : backdrop,
      streams: _movieStreams,
    );
  }

  void _playWithTorrent({
    Widget? header,
    String? backgroundImage,
    Future<List<TorrentStream>>? streams,
  }) async {
    if (_details == null) return;
    if (_isSelectionUnreleased()) {
      _showNotReleasedMessage();
      return;
    }

    final resolver = StreamResolver();
    int? s = _selectedSeason != null && _selectedSeason!.seasonNumber > 0
        ? _selectedSeason!.seasonNumber
        : null;
    int? e = _selectedEpisode;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        return TorrentQualitySelectorSheet(
          imdbId: _details!.imdbId ?? _details!.id,
          type: _details!.type,
          season: s,
          episode: e,
          resolver: resolver,
          movie: widget.movie,
          details: _details!,
          episodes: _episodes,
          onFallback: (provider) {
            _openWebPlayer(provider);
          },
          header: header,
          backgroundImage: backgroundImage,
          prefetchedStreams: streams,
        );
      },
    );
  }

  Future<void> _openWebPlayer(String provider) async {
    if (_details == null) return;
    if (_isSelectionUnreleased()) {
      _showNotReleasedMessage();
      return;
    }

    // Add to history with specific season/episode if TV
    int? s = _selectedSeason != null && _selectedSeason!.seasonNumber > 0
        ? _selectedSeason!.seasonNumber
        : null;
    int? e = _selectedEpisode;

    await SavedMoviesService().addToHistory(
      widget.movie,
      season: s,
      episode: e,
    );

    final url = ScraperService().getEmbedUrl(
      _details!.id,
      season: s,
      episode: e,
      imdbId: _details!.imdbId,
      provider: provider,
    );

    if (!mounted) return;

    await Navigator.push(
      context,
      PlayerRoute(
        builder: (_) => WebPlayer(
          url: url,
          onClose: () => Navigator.pop(context),
          movie: widget.movie,
          season: s,
          episode: e,
          episodes: _episodes,
          seasons: _details?.seasons,
          details: _details!,
        ),
      ),
    );

    // Refresh history state on return
    if (mounted) {
      final service = SavedMoviesService();
      setState(() {
        _episodes = _episodes.map((ep) {
          final progress = service.getEpisodeProgress(
            widget.movie.id,
            s ?? 1,
            ep.episodeNumber,
          );
          // The played copy's real length, now that it's known (see
          // TMDBService.getSeasonDetails).
          final minutes = service.getEpisodeMinutes(
            widget.movie.id,
            s ?? 1,
            ep.episodeNumber,
          );
          if (minutes != null) ep = ep.withRuntime(minutes);

          if (progress != null) return ep.withProgress(progress);
          return ep;
        }).toList();
      });
    }
  }

  Widget _buildAppBarTitle(Movie m) => MovieTitleLogo(movie: m);

  @override
  Widget build(BuildContext context) {
    // Not wrapped in ListenableBuilder(SavedMoviesService()) anymore — the
    // only thing here that depended on it (historyMovie, for the
    // Play/Resume button) now has its own narrowly-scoped ListenableBuilder
    // further down, so a favorite/history change elsewhere in the app no
    // longer rebuilds this entire screen (title, cast, episode list, etc).
    return (() {
      final m = _details ?? widget.movie;
      final bool isTv = m.type == 'tv';
      final bool hidePlayback = FeatureFlagsService().hidePlayback.value;

      return Scaffold(
        extendBodyBehindAppBar: true,
        // Scoped to the scroll controller so the fade/sticky-title rebuild
        // on scroll stays local to the AppBar instead of the whole screen.
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: ValueListenableBuilder<bool>(
            valueListenable: _showTitle,
            builder: (context, showTitle, _) {
              // No full-width bar background: the back button and the logo
              // form one frosted "water bubble" (GlassBubbleBar) — the logo's
              // bubble grows out of the back button at showTitle and
              // shrinks back into it, over 300ms.
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: showTitle ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 300),
                builder: (context, reveal, child) {
                  // Not an AppBar: that catches every tap across the whole
                  // bar, see-through or not, so the page's own buttons
                  // scrolled up under it (the season picker) couldn't be
                  // pressed. This only takes taps on the bubble itself.
                  return SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: kToolbarHeight,
                      child: Padding(
                        // Puts the bubble's circle exactly where the old
                        // 56px leading slot's padded back button sat.
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          // A text title (no logo) styled as an AppBar's.
                          child: DefaultTextStyle.merge(
                            style: Theme.of(context).appBarTheme.titleTextStyle,
                            // The logo stays mounted while hidden, so its
                            // image has usually finished loading by the
                            // time it's revealed.
                            child: GlassBubbleBar(
                              reveal: reveal,
                              leading: CircleAvatar(
                                backgroundColor: Colors.transparent,
                                child: widget.isSidePanel
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded,
                                            color: Colors.white),
                                        onPressed: widget.onClose,
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                      )
                                    // The same heavy chevron on every platform
                                    // (BackButton is an arrow on Android).
                                    : IconButton(
                                        icon: const Icon(
                                            GlassCircleButton.backIcon,
                                            color: Colors.white),
                                        tooltip:
                                            MaterialLocalizations.of(context)
                                                .backButtonTooltip,
                                        onPressed: () =>
                                            Navigator.maybePop(context),
                                        iconSize:
                                            GlassCircleButton.backIconSize,
                                        padding: EdgeInsets.zero,
                                      ),
                              ),
                              title: _buildAppBarTitle(m),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        body: _revealOverSkeleton(_loading
            ? const SizedBox.shrink()
            : Stack(
                children: [
                  // Parallax background image — kept OUTSIDE the sliver tree.
                  // A SliverToBoxAdapter stops painting its child entirely
                  // once the scroll offset passes the child's declared
                  // height, but this image's Transform.translate deliberately
                  // keeps it onscreen past that point (half-speed parallax
                  // lag). Combining the two made the sliver geometry cull the
                  // header mid-lag, which showed up as the content below it
                  // flickering in and out as the header abruptly popped in
                  // and out of existence while scrolling. Rendering it as a
                  // plain Positioned sibling — clipped by a fixed-size Stack
                  // instead of sliver geometry — keeps it continuous.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(
                      height: _headerHeight + _glowHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ValueListenableBuilder<double>(
                            // See _scrollOffset — a plain controller listener
                            // missed position corrections (e.g. after the
                            // synopsis collapses) and left this stuck.
                            valueListenable: _scrollOffset,
                            // Only the offset changes per frame: the image
                            // subtree is built once (`child`) and sits behind
                            // a RepaintBoundary, so scrolling just moves its
                            // layer instead of rebuilding and repainting it.
                            builder: (context, offset, child) =>
                                Transform.translate(
                              offset: Offset(0, -offset * 0.5),
                              child: child,
                            ),
                            child: RepaintBoundary(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ArtworkGlow(url: _headerImageFor(m)),
                                    // The picture melts into the glow
                                    // rather than fading to black.
                                    Positioned(
                                      top: 0,
                                      left: 0,
                                      right: 0,
                                      height: _headerHeight,
                                      child: ShaderMask(
                                        blendMode: BlendMode.dstIn,
                                        shaderCallback: (rect) =>
                                            const LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.white,
                                            Colors.white,
                                            Colors.transparent,
                                          ],
                                          stops: [0, 0.55, 1],
                                        ).createShader(rect),
                                        child: Hero(
                                      tag: 'movie_${m.id}',
                                      // Full-width parallax header — like the
                                      // home hero banners, this renders large
                                      // enough that TMDB's standard w1280
                                      // backdrop tier can look soft, so it
                                      // uses the full-resolution source.
                                      child: _headerImageFor(m)
                                              .toLowerCase()
                                              .endsWith('.svg')
                                          ? SvgPicture.network(
                                              _headerImageFor(m),
                                              fit: BoxFit.cover,
                                            )
                                          : CachedNetworkImage(
                                              // Preloaded behind the skeleton
                                              // (_preloadHeader) — keep the URL
                                              // and decode size in sync.
                                              imageUrl: _headerImageFor(m),
                                              fit: BoxFit.cover,
                                              // A tall poster loses its bottom
                                              // rather than its top: that's
                                              // under the fade and the title.
                                              alignment: _usesPosterHeader(m)
                                                  ? const Alignment(0, -0.4)
                                                  : Alignment.center,
                                              // Only constrain one side, not both — specifying
                                              // both distorts the image whenever the source's
                                              // aspect ratio doesn't match this exact box
                                              // (ResizeImagePolicy.exact stretches to fit both
                                              // dimensions). One dimension lets the decoder
                                              // scale the other proportionally, matching how
                                              // BoxFit.cover actually crops at paint time.
                                              memCacheWidth:
                                                  _headerDecodeSize(m).width,
                                              memCacheHeight:
                                                  _headerDecodeSize(m).height,
                                            ),
                                        ),
                                      ),
                                    ),
                                    // Shading moves with the image: darker
                                    // where the title, buttons and synopsis
                                    // sit over the glow, then to black.
                                    const DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.transparent,
                                            Color(0x80000000), // 50%
                                            Color(0xB3000000), // 70%
                                            Colors.black,
                                          ],
                                          stops: [0, 0.38, 0.6, 0.8, 1],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      // Header spacer — reserves the header's height in scroll space for
                      // the background image above, and carries the
                      // logo/title/rating overlay, which (unlike the image)
                      // scrolls in lockstep with the rest of the content
                      // instead of lagging behind.
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: _headerHeight,
                          child: Stack(
                            children: [
                              Positioned(
                                bottom: 8,
                                left: 24,
                                right: 24,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _logoUrlFor(m) != null
                                        ? (_logoUrlFor(m)!
                                                .toLowerCase()
                                                .endsWith('.svg')
                                            ? SvgPicture.network(
                                                _logoUrlFor(m)!,
                                                width: 200,
                                                fit: BoxFit.contain,
                                                alignment: Alignment.centerLeft,
                                              )
                                            : CachedNetworkImage(
                                                // Preloaded behind the skeleton
                                                // (_preloadHeader) — keep the
                                                // URL and memCacheWidth in sync.
                                                imageUrl: _logoUrlFor(m)!,
                                                width: 200,
                                                memCacheWidth: (200 *
                                                        MediaQuery.of(context)
                                                            .devicePixelRatio)
                                                    .toInt(),
                                                fit: BoxFit.contain,
                                                alignment: Alignment.centerLeft,
                                              ))
                                        : Text(
                                            m.title,
                                            style: const TextStyle(
                                              fontSize: 32,
                                              fontWeight: FontWeight.bold,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 10,
                                                ),
                                              ],
                                            ),
                                          ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          [
                                            '${m.year}',
                                            // Only what's known: no made-up
                                            // rating or "N/A".
                                            if (m.certification?.isNotEmpty ?? false)
                                              m.certification!,
                                            if (m.runtime != null &&
                                                m.runtime!.isNotEmpty &&
                                                m.runtime != 'N/A')
                                              m.runtime!,
                                          ].join('  •  '),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const Spacer(),
                                        const Icon(
                                          Icons.star_rounded,
                                          color: Colors.amber,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          m.rating,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.amber,
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Genres as quiet metadata under the
                                    // year/rating/runtime line, the way
                                    // streaming apps show them, instead of
                                    // chips competing with the buttons. A
                                    // list too long for one line scrolls.
                                    if (m.genres != null &&
                                        m.genres!.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      MarqueeText(
                                        m.genres!.join('  ·  '),
                                        separator: '  ·  ',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.white
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      SliverPadding(
                        // Close under the title block, as Apple TV's.
                        padding: EdgeInsets.fromLTRB(24, 16, 24, isTv ? 0 : 24),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            // Dynamic Torrent & Web Server Play Controls.
                            // Scoped to its own ListenableBuilder — this is the
                            // only part of the screen that needs historyMovie
                            // (for the Play/Resume label), so a favorite/history
                            // change elsewhere only rebuilds this button row,
                            // not the whole details screen.
                            ListenableBuilder(
                              listenable: SavedMoviesService(),
                              builder: (context, _) {
                                final historyMovie = SavedMoviesService()
                                    .getMovieFromHistory(widget.movie.id);

                                // Whether the "quick play" target isn't out yet,
                                // so the button can look disabled instead of
                                // looking normal but silently rejecting taps.
                                final movieUnreleased = !isTv && m.isUnreleased;
                                Episode? tvTargetEpisode;
                                if (isTv) {
                                  final targetSeasonNum =
                                      historyMovie?.currentSeason ?? 1;
                                  final targetEpNum =
                                      historyMovie?.currentEpisode ?? 1;
                                  // Best-effort: only accurate once the target
                                  // season's episodes are loaded (always true
                                  // for the common S1E1 case, since season 1
                                  // loads on details-screen open).
                                  if ((_selectedSeason?.seasonNumber ?? 1) ==
                                      targetSeasonNum) {
                                    for (final ep in _episodes) {
                                      if (ep.episodeNumber == targetEpNum) {
                                        tvTargetEpisode = ep;
                                        break;
                                      }
                                    }
                                  }
                                }
                                final tvUnreleased =
                                    tvTargetEpisode?.isUnreleased ?? false;

                                String? releaseDateText(String? raw) {
                                  if (raw == null) return null;
                                  final parsed = DateTime.tryParse(raw);
                                  if (parsed == null) return null;
                                  return 'Releases ${_formatReleaseDate(parsed)}';
                                }

                                final movieReleaseText = movieUnreleased
                                    ? releaseDateText(m.releaseDateRaw)
                                    : null;
                                final tvReleaseText = tvUnreleased
                                    ? releaseDateText(tvTargetEpisode?.airDate)
                                    : null;

                                final defaultProvider =
                                    Platform.isIOS ? 'vsembed' : 'vidlink';
                                final altProvider =
                                    Platform.isIOS ? 'vidlink' : 'vsembed';
                                final altLabel =
                                    Platform.isIOS ? 'Server 1' : 'Server 4';
                                // Streaming service carrying this title in
                                // the user's country, if any: attached to
                                // the Play pill, or replacing it while
                                // playback is hidden.
                                final provider = m.streamingProvider;

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        // Hidden entirely (not just disabled) when
                                        // FeatureFlagsService.hidePlayback is on.
                                        if (!hidePlayback) ...[
                                          if (!isTv)
                                            // Premium Direct Torrent Play Button
                                            Expanded(
                                              flex: provider != null ? 4 : 3,
                                              child: Container(
                                                height: 50,
                                                decoration: BoxDecoration(
                                                  color: movieUnreleased
                                                      ? Colors.white10
                                                      : Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  boxShadow: movieUnreleased
                                                      ? null
                                                      : [
                                                          BoxShadow(
                                                            color: Colors.white
                                                                .withOpacity(
                                                                    0.15),
                                                            blurRadius: 12,
                                                            offset: const Offset(
                                                                0, 4),
                                                          ),
                                                        ],
                                                ),
                                                child: _withProviderSegment(provider, InkWell(
                                                  onTap: movieUnreleased
                                                      ? null
                                                      : _openMovie,
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment.center,
                                                    children: [
                                                      Icon(
                                                        movieUnreleased
                                                            ? Icons
                                                                .event_available_rounded
                                                            : Icons
                                                                .play_arrow_rounded,
                                                        color: movieUnreleased
                                                            ? Colors.white54
                                                            : Colors.black,
                                                        size: movieUnreleased
                                                            ? 20
                                                            : 28,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: Text(
                                                          movieUnreleased
                                                              ? (movieReleaseText ??
                                                                  'Not yet released')
                                                              : (historyMovie?.progress !=
                                                                          null &&
                                                                      historyMovie!
                                                                              .progress! >
                                                                          0
                                                                  ? 'Resume'
                                                                  : 'Play Movie'),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          maxLines: 1,
                                                          style: TextStyle(
                                                            color: movieUnreleased
                                                                ? Colors.white54
                                                                : Colors.black,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize:
                                                                movieUnreleased
                                                                    ? 11
                                                                    : 16,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                ),
                                              ),
                                            )
                                          else
                                            // TV Show Play/Resume direct Button
                                            Expanded(
                                              flex: provider != null ? 4 : 3,
                                              child: Container(
                                                height: 50,
                                                decoration: BoxDecoration(
                                                  color: tvUnreleased
                                                      ? Colors.white10
                                                      : Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  boxShadow: tvUnreleased
                                                      ? null
                                                      : [
                                                          BoxShadow(
                                                            color: Colors.white
                                                                .withOpacity(
                                                                    0.15),
                                                            blurRadius: 12,
                                                            offset: const Offset(
                                                                0, 4),
                                                          ),
                                                        ],
                                                ),
                                                child: _withProviderSegment(provider, InkWell(
                                                  onTap: tvUnreleased
                                                      ? null
                                                      : () async {
                                                          int s = historyMovie
                                                                  ?.currentSeason ??
                                                              1;
                                                          int e = historyMovie
                                                                  ?.currentEpisode ??
                                                              1;
                                                          if (_details?.seasons !=
                                                                  null &&
                                                              _details!.seasons!
                                                                  .isNotEmpty) {
                                                            setState(() {
                                                              _selectedSeason =
                                                                  _details!
                                                                      .seasons!
                                                                      .firstWhere(
                                                                (sea) =>
                                                                    sea.seasonNumber ==
                                                                    s,
                                                                orElse: () =>
                                                                    _details!
                                                                        .seasons!
                                                                        .first,
                                                              );
                                                              _selectedEpisode =
                                                                  e;
                                                            });
                                                          } else {
                                                            _selectedEpisode = e;
                                                          }
  
                                                          await _loadSeasonDetails(
                                                              s);
                                                          // The same popup as
                                                          // tapping that
                                                          // episode's card.
                                                          final i = _episodes
                                                              .indexWhere((ep) =>
                                                                  ep.episodeNumber ==
                                                                  e);
                                                          if (i != -1) {
                                                            _openEpisode(
                                                                _episodes[i]);
                                                          } else {
                                                            _playWithTorrent();
                                                          }
                                                        },
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment.center,
                                                    children: [
                                                      Icon(
                                                        tvUnreleased
                                                            ? Icons
                                                                .event_available_rounded
                                                            : (historyMovie?.currentSeason !=
                                                                    null
                                                                ? Icons
                                                                    .play_circle_filled_rounded
                                                                : Icons
                                                                    .play_arrow_rounded),
                                                        color: tvUnreleased
                                                            ? Colors.white54
                                                            : Colors.black,
                                                        size: tvUnreleased
                                                            ? 20
                                                            : 28,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: Text(
                                                          tvUnreleased
                                                              ? (tvReleaseText ??
                                                                  'Not yet released')
                                                              : (historyMovie
                                                                          ?.currentSeason !=
                                                                      null
                                                                  ? 'Resume S${historyMovie!.currentSeason} E${historyMovie.currentEpisode}'
                                                                  : 'Play S1 E1'),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          maxLines: 1,
                                                          style: TextStyle(
                                                            color: tvUnreleased
                                                                ? Colors.white54
                                                                : Colors.black,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: tvUnreleased
                                                                ? 11
                                                                : 16,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                ),
                                              ),
                                            ),
                                          const SizedBox(width: 12),
                                        ] else if (provider != null) ...[
                                          // Playback hidden: the pill becomes
                                          // a link to the service instead.
                                          Expanded(
                                            flex: 4,
                                            child: _WatchOnProviderButton(
                                              provider: provider,
                                              onTap: () =>
                                                  _openProvider(provider),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                        ],
                                        // Trailer Button — icon-only (like the
                                        // Like button) when a streaming service
                                        // shares the row, so the Play / Watch
                                        // on pill keeps room for its label.
                                        if (m.trailerUrl != null &&
                                            provider != null)
                                          GlassActionButton(
                                            width: 50,
                                            onTap: () =>
                                                _openTrailer(m.trailerUrl!),
                                            child: const Icon(
                                              Icons.movie_creation_rounded,
                                              color: Colors.white,
                                              semanticLabel: 'Trailer',
                                            ),
                                          )
                                        else if (m.trailerUrl != null)
                                          Expanded(
                                            flex: 2,
                                            child: GlassActionButton(
                                              onTap: () =>
                                                  _openTrailer(m.trailerUrl!),
                                              child: const Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons
                                                        .movie_creation_rounded,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 8),
                                                  Text(
                                                    'Trailer',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 16,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        if (!hidePlayback || m.trailerUrl != null)
                                          const SizedBox(width: 12),
                                        // Share Button — functionality kept, just not shown right now.
                                        // Container(
                                        //   height: 50,
                                        //   width: 50,
                                        //   decoration: BoxDecoration(
                                        //     color: Colors.white10,
                                        //     borderRadius:
                                        //         BorderRadius.circular(30),
                                        //   ),
                                        //   child: InkWell(
                                        //     onTap: _shareMovie,
                                        //     borderRadius:
                                        //         BorderRadius.circular(30),
                                        //     child: const Icon(
                                        //       Icons.share_rounded,
                                        //       color: Colors.white,
                                        //     ),
                                        //   ),
                                        // ),
                                        // Like Button — moved here from the AppBar.
                                        GlassActionButton(
                                          width: 50,
                                          onTap: _toggleFavorite,
                                          child: Icon(
                                            SavedMoviesService()
                                                    .isFavorite(widget.movie.id)
                                                ? Icons.favorite_rounded
                                                : Icons.favorite_border_rounded,
                                            color: SavedMoviesService()
                                                    .isFavorite(widget.movie.id)
                                                ? AppTheme.primaryColor
                                                : Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (provider != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            top: 10, left: 4),
                                        child: _buildStreamingCredit(),
                                      ),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 24),

                            // Series: the cast lives inside the synopsis's
                            // More, keeping the page compact above the
                            // episode list. Movies have nothing below, so
                            // their cast is always shown, under it.
                            ExpandableSynopsis(
                              text: m.description,
                              extra: isTv &&
                                      m.castMembers != null &&
                                      m.castMembers!.isNotEmpty
                                  // Bleeds 24px each side, matching this
                                  // list's horizontal padding, so it
                                  // scrolls edge to edge.
                                  ? CastRow(cast: m.castMembers!, bleed: 24)
                                  : null,
                            ),
                            if (!isTv &&
                                m.castMembers != null &&
                                m.castMembers!.isNotEmpty) ...[
                              const SizedBox(height: 28),
                              CastRow(cast: m.castMembers!, bleed: 24),
                            ],

                            // TV Show: Seasons & Episodes
                            if (isTv) ...[
                              const SizedBox(height: 40),

                              // Header + Season Selector Row
                              if (m.seasons != null && m.seasons!.isNotEmpty)
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      "Episodes",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    // Season picker — shared with the
                                    // player's episode browser.
                                    SeasonPicker(
                                      seasons: m.seasons!
                                          .where(
                                            (s) =>
                                                s.seasonNumber > 0 ||
                                                s.seasonNumber ==
                                                    _selectedSeason
                                                        ?.seasonNumber,
                                          )
                                          .toList(),
                                      current:
                                          _selectedSeason?.seasonNumber ?? 1,
                                      onSelected: (val) {
                                        setState(() {
                                          _selectedSeason =
                                              m.seasons!.firstWhere(
                                            (s) => s.seasonNumber == val,
                                          );
                                          _selectedEpisode =
                                              null; // Reset episode
                                        });
                                        _loadSeasonDetails(val);
                                      },
                                    ),
                                  ],
                                ),

                              const SizedBox(height: 16),
                            ],
                          ]),
                        ),
                      ),

                      // Episode grid — a separate sliver (not nested inside the
                      // regular-content SliverList above) so it's genuinely lazy
                      // via SliverGrid.builder, instead of the old shrinkWrap:
                      // true + NeverScrollableScrollPhysics ListView.builder,
                      // which forced every episode row to build up front
                      // regardless of scroll position. Matters a lot for shows
                      // with long seasons (100+ episodes).
                      if (isTv)
                        if (!_loadingEpisodes && _episodes.isEmpty)
                          const SliverPadding(
                            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
                            sliver: SliverToBoxAdapter(
                              child: Text(
                                "No episodes available.",
                                style: TextStyle(color: Colors.white54),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                            // Two columns of Apple TV-style episode cards;
                            // still a lazy sliver (built as they scroll in).
                            sliver: SliverLayoutBuilder(
                              builder: (context, constraints) {
                                const gap = 12.0;
                                final cardWidth =
                                    (constraints.crossAxisExtent - gap) / 2;
                                return SliverGrid.builder(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    crossAxisSpacing: gap,
                                    mainAxisSpacing: gap,
                                    mainAxisExtent: EpisodeCard.heightFor(
                                      cardWidth,
                                      MediaQuery.textScalerOf(context),
                                    ),
                                  ),
                                  // Skeleton cards while the season loads.
                                  itemCount: _loadingEpisodes
                                      ? 6
                                      : _episodes.length,
                                  itemBuilder: (context, index) {
                                    if (_loadingEpisodes) {
                                      return const EpisodeCardSkeleton();
                                    }
                                    final ep = _episodes[index];
                                    final currentProgress = hidePlayback
                                        ? null
                                        : SavedMoviesService()
                                                .getEpisodeProgress(
                                              widget.movie.id,
                                              _selectedSeason?.seasonNumber ??
                                                  1,
                                              ep.episodeNumber,
                                            ) ??
                                            ep.progress;
                                    return EpisodeCard(
                                      episode: ep,
                                      fallbackImage: m.backdrop,
                                      progress: currentProgress,
                                      hidePlayback: hidePlayback,
                                      // The episode popup — also with
                                      // playback hidden (see _openEpisode).
                                      // Unaired episodes' cards are greyed
                                      // out and ignore taps (EpisodeCard).
                                      onTap: () => _openEpisode(ep),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: MediaQuery.of(context).padding.bottom,
                        ),
                      ),
                    ],
                  ),
                ],
              )),
      );
    })();
  }

  /// Skeleton → page reveal, same approach as the startup splash in
  /// main.dart: once loaded, the page is built *underneath* the still-
  /// opaque skeleton (so its expensive first frames — layout, uploading the
  /// big header images — happen out of sight), then the skeleton fades off
  /// it, instead of hard-cutting between the two in one heavy frame.
  Widget _revealOverSkeleton(Widget page) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Catches the page scroll view's notifications (see _scrollOffset).
        NotificationListener<Notification>(
          onNotification: _onPageScroll,
          child: page,
        ),
        if (!_skeletonDone)
          IgnorePointer(
            ignoring: !_loading,
            child: AnimatedOpacity(
              opacity: _skeletonFading ? 0 : 1,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              onEnd: () {
                if (_skeletonFading && mounted) {
                  setState(() => _skeletonDone = true);
                }
              },
              child: const ColoredBox(
                color: AppTheme.scaffoldColor,
                child: SkeletonDetails(),
              ),
            ),
          ),
      ],
    );
  }
}

class TorrentQualitySelectorSheet extends StatefulWidget {
  final String imdbId;
  final String type;
  final int? season;
  final int? episode;
  final StreamResolver resolver;
  final Movie movie;
  final Movie details;
  final List<Episode> episodes;
  final Function(String) onFallback;
  final Function(TorrentStream, String resolvedUrl, int? torrentId,
      List<TorrentStream> updatedStreams)? onStreamSelected;
  final bool resolveOnSelect;

  /// Makes this the episode / movie popup: the sources on an
  /// EpisodeSheetFrame showing [backgroundImage] (the still / backdrop)
  /// blurred behind, with [header] (a DetailHeader — episodes only)
  /// scrolling above them.
  final Widget? header;
  final String? backgroundImage;

  /// The torrents, if the caller already started looking them up (the
  /// movie popup does, on page load). Looked up afresh when null — or when
  /// that lookup came back empty, which is also how a failed one ends.
  final Future<List<TorrentStream>>? prefetchedStreams;

  const TorrentQualitySelectorSheet({
    required this.imdbId,
    required this.type,
    this.season,
    this.episode,
    required this.resolver,
    required this.movie,
    required this.details,
    required this.episodes,
    required this.onFallback,
    this.onStreamSelected,
    this.resolveOnSelect = true,
    this.header,
    this.backgroundImage,
    this.prefetchedStreams,
  });

  /// "Alternative Web Servers (No Torrenting)" is hidden for now; flip this
  /// to bring the menu back. (EpisodeBrowser has the same switch.)
  static const bool showWebServers = false;

  @override
  State<TorrentQualitySelectorSheet> createState() =>
      _TorrentQualitySelectorSheetState();
}

class _TorrentQualitySelectorSheetState
    extends State<TorrentQualitySelectorSheet> {
  List<TorrentStream>? _streams;
  // What the sheet actually lists: one entry per quality, each holding its
  // torrents best-first (see StreamResolver.qualityOptions).
  List<QualityOption>? _options;
  int? _recommendedTier;
  bool _loading = true;
  String? _error;
  // The quality being started, and how that's going — shown on its row
  // (see QualityOptionList.starting).
  QualityOption? _startingOption;
  String? _resolvingMessage;
  // Why the last tapped stream failed to start. Shown inside the sheet —
  // a SnackBar would land on the details screen *behind* this modal sheet.
  String? _resolveError;
  String? _lastPlayedHash;
  // The likely picks, connecting ahead of a tap (see StreamResolver.warmUp).
  List<TorrentStream> _warmed = const [];

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  @override
  void dispose() {
    widget.resolver.coolDown(_warmed);
    super.dispose();
  }

  Future<void> _loadStreams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String key = widget.season != null && widget.episode != null
          ? 'last_played_torrent_${widget.imdbId}_${widget.season}_${widget.episode}'
          : 'last_played_torrent_${widget.imdbId}';
      _lastPlayedHash = prefs.getString(key);

      final prefetched = widget.prefetchedStreams == null
          ? null
          : await widget.prefetchedStreams;
      final list = prefetched != null && prefetched.isNotEmpty
          // A copy: the reordering below mustn't change the shared list.
          ? List.of(prefetched)
          : await widget.resolver.getAvailableStreams(
              imdbId: widget.imdbId,
              type: widget.type,
              season: widget.season,
              episode: widget.episode,
              title: widget.details,
            );

      if (mounted) {
        // The resolver sorts its overall pick first — that's the quality
        // to recommend. (Read before the last-played reordering below.)
        final recommendedTier =
            list.isEmpty ? null : StreamResolver.tierOf(list.first);

        if (_lastPlayedHash != null && list.isNotEmpty) {
          final idx = list.indexWhere((s) =>
              s.infoHash.toLowerCase() == _lastPlayedHash!.toLowerCase());
          if (idx != -1) {
            final lastPlayed = list.removeAt(idx);
            list.insert(0, lastPlayed);
          }
        }

        setState(() {
          _streams = list;
          _options = StreamResolver.qualityOptions(
            list,
            preferHash: _lastPlayedHash,
          );
          _recommendedTier = recommendedTier;
          _loading = false;
        });
        // Not for a movie: its page already did, and owns it — closing
        // this popup mustn't end the page's head start.
        if (widget.prefetchedStreams == null) {
          _warmed = StreamResolver.headStartCandidates(list,
              lastPlayedHash: _lastPlayedHash);
          final s = widget.season, e = widget.episode;
          widget.resolver.warmUp(
            _warmed,
            resumeAt: s != null && e != null
                ? SavedMoviesService().getEpisodeProgress(widget.movie.id, s, e)
                : SavedMoviesService()
                    .getMovieFromHistory(widget.movie.id)
                    ?.progress,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to find torrent sources.';
          _loading = false;
        });
      }
    }
  }

  void _selectQuality(QualityOption option) async {
    final stream = option.best;
    if (widget.onStreamSelected != null && !widget.resolveOnSelect) {
      Navigator.pop(context);
      widget.onStreamSelected!(
        stream,
        '',
        null,
        _streams ?? [stream],
      );
      return;
    }

    setState(() {
      _startingOption = option;
      _resolvingMessage = 'Connecting…';
      _resolveError = null;
    });

    try {
      // Start the quality's best torrent, automatically trying its others
      // if it fails or times out — Torrentio's seed counts are often
      // stale, so one dead pick shouldn't be a dead end. Only the same
      // quality is tried, so the user never silently gets a lower one.
      // Closing the popup (unmounting this) abandons the start.
      final resolved = await widget.resolver.resolveWithFallback(
        stream,
        option.streams,
        isCancelled: () => !mounted,
      );
      final resolvedStream = resolved.stream;
      final result = resolved.result;

      // Save last played torrent infohash — the one that actually resolved,
      // not necessarily the one originally tapped.
      final prefs = await SharedPreferences.getInstance();
      final String key = widget.season != null && widget.episode != null
          ? 'last_played_torrent_${widget.imdbId}_${widget.season}_${widget.episode}'
          : 'last_played_torrent_${widget.imdbId}';
      await prefs.setString(key, resolvedStream.infoHash);

      // Record which movie/episode this download is and how big it's
      // supposed to be, so Settings > Storage can show something more
      // useful than a bare infoHash (see TorrentDownloadRegistry).
      await TorrentDownloadRegistry.save(
        resolvedStream.infoHash,
        TorrentDownloadInfo(
          movieId: widget.movie.id,
          imdbId: widget.imdbId,
          title: widget.movie.title,
          image: widget.movie.image,
          season: widget.season,
          episode: widget.episode,
          totalBytes: TorrentDownloadRegistry.parseSizeBytes(resolvedStream.size),
        ),
      );

      // Closed during the saves above: stop the torrent, and don't count
      // it as watched.
      if (!mounted) {
        widget.resolver.pause(result.torrentId);
        return;
      }

      // Add to history
      await SavedMoviesService().addToHistory(
        widget.movie,
        season: widget.season,
        episode: widget.episode,
      );

      if (!mounted) return;
      Navigator.pop(context); // Pop bottom sheet

      if (widget.onStreamSelected != null) {
        widget.onStreamSelected!(
          resolvedStream,
          result.streamUrl,
          result.torrentId,
          _streams ?? [stream],
        );
        return;
      }

      // Navigate to premium native player
      await Navigator.push(
        context,
        PlayerRoute(
          builder: (_) => PlayerScreen(
            url: result.streamUrl,
            torrentId: result.torrentId,
            streamId: result.streamId,
            selectedStream: resolvedStream,
            availableStreams: _streams ?? [stream],
            movie: widget.movie,
            details: widget.details,
            season: widget.season,
            episode: widget.episode,
            episodes: widget.episodes,
          ),
        ),
      );
    } on ResolveCancelledException {
      // The popup was closed — nothing to report.
    } catch (e) {
      if (mounted) {
        setState(() {
          _startingOption = null;
          _resolvingMessage = null;
          _resolveError = 'Couldn\'t start ${option.name}: '
              '${e.toString().replaceFirst(RegExp(r'^(Exception|Bad state): '), '')}\n'
              'Try another quality.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final bottomPadding =
        (isLandscape ? 10 : 20) + MediaQuery.of(context).padding.bottom;

    // The episode / movie popup: the qualities on the cards' blurred-still
    // backdrop, below the episode's header (see DetailHeader) if there is
    // one. Sized to its content, up to most of the screen (like
    // EpisodeInfoSheet), so a short popup isn't padded out with empty
    // space — growing smoothly as the qualities load in.
    if (widget.header != null || widget.backgroundImage != null) {
      return EpisodeSheetFrame(
        frosted: true,
        image: widget.backgroundImage,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                MediaQuery.sizeOf(context).height * (isLandscape ? 0.95 : 0.9),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: CustomScrollView(
                    shrinkWrap: true,
                    // Pulling past the top drags the sheet (EpisodeSheetFrame).
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      if (widget.header != null)
                        SliverToBoxAdapter(child: widget.header),
                      SliverPadding(
                        // Without a header, clear the frame's drag handle.
                        padding: EdgeInsets.fromLTRB(
                            20, widget.header != null ? 16 : 32, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: _buildTitleRow(context, closeButton: false),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        sliver: _buildSources(isLandscape),
                      ),
                    ],
                  ),
                ),
                if (TorrentQualitySelectorSheet.showWebServers)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        20, isLandscape ? 8 : 12, 20, bottomPadding),
                    child: _buildWebServersMenu(context),
                  )
                else
                  SizedBox(height: bottomPadding),
              ],
            ),
          ),
        ),
      );
    }

    return DraggableScrollableSheet(
      initialChildSize: isLandscape ? 0.85 : 0.6,
      minChildSize: isLandscape ? 0.45 : 0.4,
      maxChildSize: isLandscape ? 0.95 : 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0C0C0C),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: Colors.white12, width: 0.5),
            ),
          ),
          padding: EdgeInsets.only(
            top: isLandscape ? 6 : 8,
            left: 20,
            right: 20,
            bottom: bottomPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              _buildTitleRow(context, closeButton: true),
              SizedBox(height: isLandscape ? 8 : 16),
              Expanded(
                child: CustomScrollView(
                  controller: scrollController,
                  slivers: [_buildSources(isLandscape)],
                ),
              ),
              if (TorrentQualitySelectorSheet.showWebServers) ...[
                SizedBox(height: isLandscape ? 8 : 16),
                _buildWebServersMenu(context),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildTitleRow(BuildContext context, {required bool closeButton}) {
    return Row(
      children: [
        const Expanded(child: QualitySectionLabel('Choose quality')),
        if (closeButton && _resolvingMessage == null)
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: Colors.white38, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
      ],
    );
  }

  /// The sheet's scrolling body, as a sliver: the last start attempt's
  /// error, then the current state — searching, an error, nothing found,
  /// or the qualities (which also show a start in progress).
  Widget _buildSources(bool isLandscape) {
    Widget message(List<Widget> children) => SliverToBoxAdapter(
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        );

    final Widget state;
    if (_loading) {
      state = const SliverToBoxAdapter(child: QualityOptionListSkeleton());
    } else if (_error != null) {
      state = message([
        SizedBox(height: isLandscape ? 10 : 20),
        Center(
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
        SizedBox(height: isLandscape ? 10 : 20),
      ]);
    } else if (_options == null || _options!.isEmpty) {
      state = message([
        SizedBox(height: isLandscape ? 10 : 20),
        const Center(
          child: Text(
            'Not available to stream right now.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
        if (TorrentQualitySelectorSheet.showWebServers) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Try "Alternative Web Servers" below instead.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3), fontSize: 12),
            ),
          ),
        ],
        SizedBox(height: isLandscape ? 10 : 20),
      ]);
    } else {
      state = SliverToBoxAdapter(child: _buildOptionList(_options!));
    }

    return SliverMainAxisGroup(
      slivers: [
        if (_resolveError != null && _resolvingMessage == null)
          SliverToBoxAdapter(child: _buildResolveError()),
        state,
      ],
    );
  }

  Widget _buildResolveError() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: Colors.red[900]!.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.error_outline_rounded,
                color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _resolveError!,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, height: 1.35),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded,
                color: Colors.white70, size: 18),
            onPressed: () => setState(() => _resolveError = null),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionList(List<QualityOption> options) {
    bool isLastPlayed(QualityOption option) =>
        _lastPlayedHash != null &&
        option.streams.any((s) =>
            s.infoHash.toLowerCase() == _lastPlayedHash!.toLowerCase());
    final hasLastPlayed = options.any(isLastPlayed);

    return QualityOptionList(
      options: options,
      onSelected: _selectQuality,
      starting: _startingOption,
      startingMessage: _resolvingMessage,
      tagFor: (option) => isLastPlayed(option)
          ? 'Last watched'
          : (option.tier == _recommendedTier ? 'Recommended' : null),
      // Resuming is the likeliest pick when there's something to resume.
      isPrimary: (option) => hasLastPlayed
          ? isLastPlayed(option)
          : option.tier == _recommendedTier,
    );
  }

  /// "Alternative Web Servers (No Torrenting)": the embed web players.
  Widget _buildWebServersMenu(BuildContext context) {
    return Center(
      child: PopupMenuButton<String>(
        offset: const Offset(0, -150),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        color: Colors.grey[950],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.language_rounded,
                  size: 16, color: Colors.white.withOpacity(0.5)),
              const SizedBox(width: 6),
              Text(
                'Alternative Web Servers (No Torrenting)',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_up_rounded,
                  size: 16, color: Colors.white.withOpacity(0.5)),
            ],
          ),
        ),
        itemBuilder: (context) {
          final defaultProvider = Platform.isIOS ? 'vsembed' : 'vidlink';
          final altProvider = Platform.isIOS ? 'vidlink' : 'vsembed';
          final altLabel = Platform.isIOS ? 'Server 1' : 'Server 4';
          return [
            PopupMenuItem(
              value: defaultProvider,
              child: Text(
                Platform.isIOS ? 'Server 4' : 'Server 1',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            const PopupMenuItem(
              value: 'moviesapi',
              child: Text(
                'Server 2',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            const PopupMenuItem(
              value: '2embed',
              child: Text(
                'Server 3',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            PopupMenuItem(
              value: altProvider,
              child: Text(
                altLabel,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ];
        },
        onSelected: (val) {
          Navigator.pop(context);
          widget.onFallback(val);
        },
      ),
    );
  }
}

/// A streaming service's square app-icon logo, rounded like an app icon:
/// bundled for the major services (instant), otherwise loaded from TMDB,
/// falling back to its initial if the image can't load.
class ProviderLogo extends StatelessWidget {
  final StreamingProvider provider;
  final double size;

  const ProviderLogo({required this.provider, required this.size});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: Colors.black,
      child: Text(
        provider.name.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: size * 0.5,
        ),
      ),
    );
    final asset = provider.bundledLogoAsset;
    final logo = provider.logoUrl;
    final Widget image;
    if (asset != null) {
      image = Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    } else if (logo != null) {
      image = CachedNetworkImage(
        imageUrl: logo,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      );
    } else {
      image = fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: image,
    );
  }
}

/// Stand-in for the Play pill while playback is hidden: same white pill,
/// with the service's logo and "Watch on {service}".
class _WatchOnProviderButton extends StatelessWidget {
  final StreamingProvider provider;
  final VoidCallback onTap;

  const _WatchOnProviderButton({required this.provider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: _PillInk(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ProviderLogo(provider: provider, size: 26),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Watch on ${provider.name}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lets InkWell ripples show on an opaque pill (the white Play / Watch on
/// buttons). An InkWell paints on the nearest Material, which sat below
/// the pill's Container colour — so the solid white hid the ripple, while
/// the translucent Like / Trailer buttons let it show through. This puts
/// a transparent Material above the colour, with a dark ripple, since the
/// dark theme's light grey one doesn't show on white.
class _PillInk extends StatelessWidget {
  final Widget child;

  const _PillInk({required this.child});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        splashColor: Colors.black12,
        highlightColor: Colors.black12,
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

