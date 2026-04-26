import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import '../theme/app_theme.dart';
import '../widgets/skeletons.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import '../services/scraper_service.dart';
import '../services/saved_movies_service.dart';
import 'web_player/web_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui'; // For BackdropFilter
import '../widgets/custom_app_bar.dart';

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

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  Movie? _details;
  bool _loading = true;
  final ScrollController _scrollController = ScrollController();
  double _opacity = 0.0;
  bool _isFavorite = false;
  bool _showAppBarTitle = false;

  // TV Show State
  List<Episode> _episodes = [];
  Season? _selectedSeason;
  int? _selectedEpisode;
  bool _loadingEpisodes = false;

  Future<void> _shareMovie() async {
    final m = _details ?? widget.movie;
    const downloadUrl =
        'https://drive.google.com/drive/folders/1ftzQcKIUkB2sKwInoSdMG7-SH4rPf96i?usp=sharing';
    final smartLink = 'https://script.google.com/macros/s/AKfycbzEwmEgC4JXWXz4TPHUUxPon_56ZN4VsOKq7FAw_3rWgRi2L4KIZAx1rs_HZ94-1h6IVg/exec?id=${m.id}&type=${m.type}';
    
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
        await Dio().download(m.image!, path);
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
    _loadDetails();
    _checkFavorite();
    _scrollController.addListener(_onScroll);
  }

  void _checkFavorite() {
    setState(() {
      _isFavorite = SavedMoviesService().isFavorite(widget.movie.id);
    });
  }

  Future<void> _toggleFavorite() async {
    await SavedMoviesService().toggleFavorite(_details ?? widget.movie);
    _checkFavorite();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    // Fade in sticky header background - matching home screen logic (divisor 200)
    double newOpacity = (offset / 200).clamp(0.0, 1.0);
    if (newOpacity != _opacity) {
      setState(() => _opacity = newOpacity);
    }

    // Toggle AppBar Title visibility (sticky logo)
    final showTitle = offset > 350;
    if (showTitle != _showAppBarTitle) {
      setState(() => _showAppBarTitle = showTitle);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    final d = await TMDBService().getDetails(
      widget.movie.id,
      type: widget.movie.type,
    );
    if (mounted) {
      setState(() {
        _details = d ?? widget.movie;
        _loading = false;

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
          _loadSeasonDetails(_selectedSeason!.seasonNumber);
        }
      });
    }
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
    // We still get the main "saved" movie to check if the show itself is in history?
    // Actually, getEpisodeProgress checks the granular map, which is what we want.

    final processedEpisodes = episodes.map((e) {
      final progress = service.getEpisodeProgress(
        widget.movie.id,
        seasonNum,
        e.episodeNumber,
      );

      if (progress != null) {
        return Episode(
          id: e.id,
          episodeNumber: e.episodeNumber,
          name: e.name,
          overview: e.overview,
          stillPath: e.stillPath,
          airDate: e.airDate,
          voteAverage: e.voteAverage,
          progress: progress,
        );
      }
      return e;
    }).toList();

    if (mounted) {
      setState(() {
        _episodes = processedEpisodes;
        _loadingEpisodes = false;
      });
    }
  }

  Future<void> _openWebPlayer(String provider) async {
    if (_details == null) return;

    // Add to history with specific season/episode if TV
    int? s = _selectedSeason != null && _selectedSeason!.seasonNumber > 0
        ? _selectedSeason!.seasonNumber
        : null;
    int? e = _selectedEpisode;

    await SavedMoviesService().addToHistory(
      widget.movie,
      season: s,
      episode: e,
      // Don't set progress here - let the player track it
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
      MaterialPageRoute(
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
            s ?? 1, // Default to season 1 if null (should handle specials?)
            ep.episodeNumber,
          );

          if (progress != null) {
            return Episode(
              id: ep.id,
              episodeNumber: ep.episodeNumber,
              name: ep.name,
              overview: ep.overview,
              stillPath: ep.stillPath,
              airDate: ep.airDate,
              voteAverage: ep.voteAverage,
              progress: progress,
            );
          }
          return ep;
        }).toList();
      });
    }
  }

  Widget _buildAppBarTitle(Movie m) {
    if (m.logoUrl != null) {
      if (m.logoUrl!.toLowerCase().endsWith('.svg')) {
        return Container(
          constraints: const BoxConstraints(maxWidth: 120),
          child: SvgPicture.network(
            m.logoUrl!,
            height: 28,
            alignment: Alignment.centerLeft,
            fit: BoxFit.contain,
          ),
        );
      } else {
        return Container(
          constraints: const BoxConstraints(maxWidth: 120),
          child: CachedNetworkImage(
            imageUrl: m.logoUrl!,
            height: 28,
            alignment: Alignment.centerLeft,
            fit: BoxFit.contain,
          ),
        );
      }
    }
    return Text(
      m.title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SavedMoviesService(),
      builder: (context, _) {
        final m = _details ?? widget.movie;
        final bool isTv = m.type == 'tv';
        final historyMovie = SavedMoviesService().getMovieFromHistory(widget.movie.id);

        return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: CustomAppBar(
        scrollOffset: _scrollController.hasClients ? _scrollController.offset : 0.0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: CircleAvatar(
            backgroundColor: Colors.black26,
            child: widget.isSidePanel
                ? IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: widget.onClose,
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                  )
                : const BackButton(color: Colors.white),
          ),
        ),
        title: AnimatedOpacity(
          opacity: _showAppBarTitle ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: _showAppBarTitle ? _buildAppBarTitle(m) : null,
        ),
        showActions: false,
        actions: [
          IconButton(
            icon: Icon(
              _isFavorite ? Icons.favorite : Icons.favorite_border,
              color: _isFavorite ? AppTheme.primaryColor : Colors.white,
            ),
            onPressed: _toggleFavorite,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const SkeletonDetails()
          : SingleChildScrollView(
              controller: _scrollController,
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Parallax Header
                  SizedBox(
                    height: 450,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ListenableBuilder(
                          listenable: _scrollController,
                          builder: (context, child) {
                            double offset = 0;
                            if (_scrollController.hasClients) {
                              offset = _scrollController.offset;
                            }
                            return Transform.translate(
                              offset: Offset(0, offset * 0.5),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Hero(
                                    tag: 'movie_${m.id}',
                                    child: (m.backdrop ?? m.posterUrl ?? '')
                                            .toLowerCase()
                                            .endsWith('.svg')
                                        ? SvgPicture.network(
                                            m.backdrop ?? m.posterUrl ?? '',
                                            fit: BoxFit.cover,
                                          )
                                        : CachedNetworkImage(
                                            imageUrl:
                                                m.backdrop ?? m.posterUrl ?? '',
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                  // Gradient moves with image
                                  Container(
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.black,
                                        ],
                                        stops: [0.4, 1.0],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        Positioned(
                          bottom: 20,
                          left: 24,
                          right: 24,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              m.logoUrl != null
                                  ? (m.logoUrl!.toLowerCase().endsWith('.svg')
                                      ? SvgPicture.network(
                                          m.logoUrl!,
                                          width: 200,
                                          fit: BoxFit.contain,
                                          alignment: Alignment.centerLeft,
                                        )
                                      : CachedNetworkImage(
                                          imageUrl: m.logoUrl!,
                                          width: 200,
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
                                    '${m.year}  •  ${m.certification ?? "PG-13"}  •  ${m.runtime ?? "N/A"}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const Spacer(),
                                  const Icon(
                                    Icons.star,
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
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Dynamic Server Logic
                        () {
                          final defaultProvider = Platform.isIOS ? 'vsembed' : 'vidlink';
                          final altProvider = Platform.isIOS ? 'vidlink' : 'vsembed';
                          final altLabel = Platform.isIOS ? 'Server 1' : 'Server 4';
                          
                          return Row(
                            children: [
                              if (!isTv)
                                // Split Play Button (Main / Alternatives) for Movies
                                Expanded(
                                  flex: 3,
                                  child: Container(
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    child: Row(
                                      children: [
                                        // Main Server
                                        Expanded(
                                          child: InkWell(
                                            onTap: () => _openWebPlayer(defaultProvider),
                                            borderRadius: const BorderRadius.horizontal(
                                              left: Radius.circular(30),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                const Icon(
                                                  Icons.play_arrow_rounded,
                                                  color: Colors.black,
                                                  size: 28,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  historyMovie?.progress != null && historyMovie!.progress! > 0
                                                      ? 'Resume'
                                                      : (Platform.isIOS ? 'Server 4' : 'Server 1'),
                                                  style: const TextStyle(
                                                    color: Colors.black,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 16,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        // Divider
                                        Container(
                                          width: 1,
                                          height: 30,
                                          color: Colors.black12,
                                        ),
                                        // Dropdown
                                        PopupMenuButton<String>(
                                          icon: const Icon(
                                            Icons.arrow_drop_down,
                                            color: Colors.black,
                                          ),
                                          offset: const Offset(0, 50),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          color: Colors.white,
                                          itemBuilder: (context) => [
                                            const PopupMenuItem(
                                              value: 'moviesapi',
                                              child: Text(
                                                'Server 2',
                                                style: TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            const PopupMenuItem(
                                              value: 'vidking',
                                              child: Text(
                                                'Server 3',
                                                style: TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: altProvider,
                                              child: Text(
                                                altLabel,
                                                style: const TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                          onSelected: (val) {
                                            _openWebPlayer(val);
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              else
                                // TV Show Play/Resume Button
                                Expanded(
                                  flex: 3,
                                  child: Container(
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    child: InkWell(
                                      onTap: () async {
                                        int s = historyMovie?.currentSeason ?? 1;
                                        int e = historyMovie?.currentEpisode ?? 1;
                                        if (_details?.seasons != null && _details!.seasons!.isNotEmpty) {
                                          setState(() {
                                            _selectedSeason = _details!.seasons!.firstWhere(
                                              (sea) => sea.seasonNumber == s,
                                              orElse: () => _details!.seasons!.first,
                                            );
                                            _selectedEpisode = e;
                                          });
                                        } else {
                                          _selectedEpisode = e;
                                        }
                                        
                                        await _loadSeasonDetails(s);
                                        _openWebPlayer(defaultProvider);
                                      },
                                      borderRadius: BorderRadius.circular(30),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            historyMovie?.currentSeason != null
                                                ? Icons.play_circle_filled
                                                : Icons.play_arrow_rounded,
                                            color: Colors.black,
                                            size: 28,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            historyMovie?.currentSeason != null
                                                ? 'Resume S${historyMovie!.currentSeason} E${historyMovie.currentEpisode}'
                                                : 'Play S1 E1',
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 12),
                              // Trailer Button
                              if (m.trailerUrl != null)
                                Expanded(
                                  flex: 2,
                                  child: Container(
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Colors.white10,
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    child: InkWell(
                                      onTap: () async {
                                        final uri = Uri.parse(m.trailerUrl!);
                                        if (await canLaunchUrl(uri)) {
                                          await launchUrl(
                                            uri,
                                            mode: LaunchMode.externalApplication,
                                          );
                                        }
                                      },
                                      borderRadius: BorderRadius.circular(30),
                                      child: const Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.movie_creation_outlined,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Trailer',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 12),
                              // Share Button
                              Container(
                                height: 50,
                                width: 50,
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                child: InkWell(
                                  onTap: _shareMovie,
                                  borderRadius: BorderRadius.circular(30),
                                  child: const Icon(
                                    Icons.share_outlined,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }(),
                        const SizedBox(height: 24),

                        Text(
                          m.description,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: Colors.white70,
                          ),
                        ),

                        if (m.cast != null && m.cast!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.5,
                              ),
                              children: [
                                const TextSpan(
                                  text: "Starring: ",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextSpan(
                                  text: m.cast!.join(", "),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 32),

                        // Genres
                        if (m.genres != null)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: m.genres!
                                .map(
                                  (g) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.white24),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      g,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),

                        // TV Show: Seasons & Episodes
                        if (isTv) ...[
                          const SizedBox(height: 40),

                          // Header + Season Selector Row
                          if (m.seasons != null && m.seasons!.isNotEmpty)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "Episodes",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                // Minimalist Netflix-style Season Selector
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.white24),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      value: _selectedSeason?.seasonNumber,
                                      dropdownColor: Colors.grey[900],
                                      icon: const Icon(
                                        Icons.arrow_drop_down,
                                        color: Colors.white,
                                      ),
                                      isDense: true,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      items: m.seasons!
                                          .where(
                                            (s) =>
                                                s.seasonNumber > 0 ||
                                                s.seasonNumber ==
                                                    _selectedSeason
                                                        ?.seasonNumber,
                                          )
                                          .map(
                                            (s) => DropdownMenuItem(
                                              value: s.seasonNumber,
                                              child: Text(
                                                s.seasonNumber == 0
                                                    ? 'Specials'
                                                    : 'Season ${s.seasonNumber}',
                                              ),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() {
                                            _selectedSeason =
                                                m.seasons!.firstWhere(
                                              (s) => s.seasonNumber == val,
                                            );
                                            _selectedEpisode =
                                                null; // Reset episode
                                          });
                                          _loadSeasonDetails(val);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),

                          const SizedBox(height: 16),

                          if (_loadingEpisodes)
                            const ShimmerList()
                          else if (_episodes.isEmpty)
                            const Text(
                              "No episodes available.",
                              style: TextStyle(color: Colors.white54),
                            )
                          else
                            ListView.builder(
                              padding: EdgeInsets.zero,
                              physics: const NeverScrollableScrollPhysics(),
                              shrinkWrap: true,
                              itemCount: _episodes.length,
                              itemBuilder: (context, index) {
                                final ep = _episodes[index];
                                bool isFuture = false;
                                String? formattedDate;

                                if (ep.airDate != null) {
                                  try {
                                    final date = DateTime.parse(ep.airDate!);
                                    if (date.isAfter(DateTime.now())) {
                                      isFuture = true;
                                      // Format: DD/MM/YYYY
                                      formattedDate =
                                          "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
                                    }
                                  } catch (_) {}
                                }

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 16),
                                  child: InkWell(
                                    onTap: isFuture
                                        ? null
                                        : () {
                                            setState(() {
                                              _selectedEpisode =
                                                  ep.episodeNumber;
                                            });
                                            _openWebPlayer(Platform.isIOS ? 'vsembed' : 'vidlink');
                                          },
                                    borderRadius: BorderRadius.circular(4),
                                    child: Row(
                                      children: [
                                        // Thumbnail
                                        Container(
                                          width: 140,
                                          height: 80,
                                          margin: const EdgeInsets.only(
                                            right: 12,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            image: DecorationImage(
                                              image: CachedNetworkImageProvider(
                                                ep.stillPath ??
                                                    m.backdrop ??
                                                    '',
                                              ),
                                              fit: BoxFit.cover,
                                              colorFilter: isFuture
                                                  ? const ColorFilter.mode(
                                                      Colors.black54,
                                                      BlendMode.darken,
                                                    )
                                                  : null,
                                              opacity: isFuture ? 0.6 : 1.0,
                                            ),
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              isFuture
                                                  ? const Center(
                                                      child: Icon(
                                                        Icons
                                                            .lock_clock, // Lock icon for future episodes
                                                        color: Colors.white54,
                                                        size: 24,
                                                      ),
                                                    )
                                                  : Container(
                                                      color: Colors.black26,
                                                      child: const Center(
                                                        child: Icon(
                                                          Icons
                                                              .play_circle_outline,
                                                          color: Colors.white,
                                                          size: 32,
                                                        ),
                                                      ),
                                                    ),
                                              // Progress Bar
                                              if (ep.progress != null &&
                                                  ep.progress! > 0)
                                                Positioned(
                                                  bottom: 0,
                                                  left: 0,
                                                  right: 0,
                                                  child:
                                                      LinearProgressIndicator(
                                                    value: ep.progress,
                                                    backgroundColor:
                                                        Colors.white10,
                                                    valueColor:
                                                        const AlwaysStoppedAnimation<
                                                            Color>(
                                                      AppTheme.primaryColor,
                                                    ),
                                                    minHeight: 3,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),

                                        // Info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${ep.episodeNumber}. ${ep.name}',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: isFuture
                                                      ? Colors.white54
                                                      : Colors.white,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                ep.overview.isNotEmpty
                                                    ? ep.overview
                                                    : "No description available.",
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              isFuture && formattedDate != null
                                                  ? Text(
                                                      'Available on: $formattedDate',
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: AppTheme
                                                            .primaryColor, // Highlight release date
                                                        fontStyle:
                                                            FontStyle.italic,
                                                      ),
                                                    )
                                                  : Text(
                                                      '${ep.voteAverage.toStringAsFixed(1)} ★',
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        color: Colors.white54,
                                                      ),
                                                    ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: MediaQuery.of(context).padding.bottom),
                ],
              ),
            ),
          );
      },
    );
  }
}
