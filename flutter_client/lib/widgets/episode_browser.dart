import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import '../models/movie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/audio_language_service.dart';
import '../services/saved_movies_service.dart';
import '../services/torrent/torrent_index_service.dart';
import '../services/torrent/last_played_torrents.dart';
import '../services/torrent/stream_resolver.dart';
import 'episode_card.dart';
import 'glass_blur.dart';
import 'quality_option_list.dart';
import 'floating_bottom_nav_bar.dart' show kNavButtonHeight;
import 'glass_bubble_bar.dart' show GlassBubbleBar, MovieTitleLogo;
import 'season_picker.dart';
import 'smooth_scroll_controller.dart';
import 'tv_focus.dart';

/// YouTube-style, full-screen episode browser for the in-player "Episodes"
/// button. Two states:
///  - Grid: a 4-column vertical grid of episode thumbnails for the season
///    being browsed.
///  - Detail + source: after tapping an episode, splits into the episode's
///    thumbnail/details on the left and a live-fetched list of torrent
///    qualities + web player servers on the right.
///
/// This widget never resolves a stream itself — it only reports the user's
/// *choice* (a [TorrentStream] or a web player provider string) via
/// [onTorrentChosen]/[onWebPlayerChosen], so the caller (PlayerScreen) can
/// reuse its existing resolve + loading-overlay flow.
class EpisodeBrowser extends StatefulWidget {
  final List<Episode> episodes;
  final List<Season>? seasons;
  final Movie movie;
  final Movie details;
  final String imdbId;
  /// The season currently being browsed (may differ from what's playing).
  final int currentSeason;
  final int playingSeason;
  final int playingEpisode;
  final StreamResolver resolver;
  final ValueChanged<int> onSeasonChanged;
  final VoidCallback onClose;

  /// The copy playing (of [playingEpisode]): its quality is marked as
  /// playing in that episode's list.
  final TorrentStream? playingStream;

  /// The audio language was changed in an episode's list (it's saved by
  /// then): what's playing should follow it.
  final VoidCallback? onAudioLanguageChanged;

  /// [stream] is the chosen quality's best torrent; [allStreams] is every
  /// torrent found for the episode (for falling back and for the player's
  /// Quality menu).
  final void Function(Episode episode, int season, TorrentStream stream,
      List<TorrentStream> allStreams) onTorrentChosen;
  final void Function(Episode episode, int season, String provider)
      onWebPlayerChosen;

  /// A panel down the side of a computer's wide window (see PlayerScreen),
  /// a phone screen wide, instead of the whole screen: two columns of
  /// episodes, and an episode's details and qualities down the panel.
  final bool asPanel;

  /// The side panel's TapRegion group (see PlayerScreen): the panel, its
  /// season menu and the Episodes button — a click anywhere else closes
  /// the panel, as one outside a menu closes that.
  static const Object panelTapGroup = #episodePanel;

  const EpisodeBrowser({
    super.key,
    this.asPanel = false,
    required this.episodes,
    this.seasons,
    required this.movie,
    required this.details,
    required this.imdbId,
    required this.currentSeason,
    required this.playingSeason,
    required this.playingEpisode,
    required this.resolver,
    this.playingStream,
    this.onAudioLanguageChanged,
    required this.onSeasonChanged,
    required this.onClose,
    required this.onTorrentChosen,
    required this.onWebPlayerChosen,
  });

  @override
  State<EpisodeBrowser> createState() => _EpisodeBrowserState();
}

class _EpisodeBrowserState extends State<EpisodeBrowser> {
  Episode? _selectedEpisode;
  final ScrollController _gridScrollController = SmoothScrollController();
  bool _hasScrolled = false;

  // Where the grid was scrolled to when an episode was opened: put back on
  // returning to it, which builds it anew (from the top, otherwise — the
  // playing episode it had scrolled to on opening gone off the top).
  double? _gridOffsetToRestore;

  int get _crossAxisCount => widget.asPanel ? 2 : 4;
  double get _gridPadding => widget.asPanel ? 16.0 : 24.0;
  // The details screen's card gap.
  static const double _gap = 12.0;

  double _itemWidthFor(double gridWidth) {
    final availableWidth = gridWidth - _gridPadding * 2;
    return (availableWidth - _gap * (_crossAxisCount - 1)) / _crossAxisCount;
  }

  // EpisodeCards are a fixed height for their width.
  double _itemHeightFor(double gridWidth) => EpisodeCard.heightFor(
        _itemWidthFor(gridWidth),
        MediaQuery.textScalerOf(context),
      );

  void _scrollToCurrentEpisode(double gridWidth) {
    if (_hasScrolled) return;
    if (widget.currentSeason != widget.playingSeason) return;
    final index = widget.episodes
        .indexWhere((e) => e.episodeNumber == widget.playingEpisode);
    if (index <= 0) return; // already on row 0, no scroll needed
    _hasScrolled = true;
    final row = index ~/ _crossAxisCount;
    final offset = (row * (_itemHeightFor(gridWidth) + _gap) - _gridPadding / 2)
        .clamp(0.0, _gridScrollController.position.maxScrollExtent);
    _gridScrollController.jumpTo(offset);
  }

  // The header floats over the top of the grid (see _buildGrid): its row,
  // and where the grid's first row starts, under it.
  static const double _headerTop = 12;
  static const double _gridTop = _headerTop + 44 + 16;

  @override
  void dispose() {
    _gridScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Edge to edge, behind a camera cutout like the video: the grid sits in
    // a SafeArea, and the episode view keeps its own content clear of it
    // (see _buildDetailAndSource) so its backdrop can still fill the screen.
    // As a side panel: on the player's frosted glass (the menus' — see
    // PlayerScreen._episodeBrowserLayer), with no backdrop of its own.
    return Material(
      color: widget.asPanel ? Colors.transparent : Colors.black,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.04, 0.0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: _selectedEpisode == null
            ? KeyedSubtree(
                key: const ValueKey('grid_view'),
                // On the show's blurred backdrop, like the details
                // screen's popups, edge to edge.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (!widget.asPanel)
                      EpisodeBackdrop(
                        image: widget.details.backdrop ?? widget.movie.backdrop,
                        dim: 0.6,
                      ),
                    SafeArea(child: _buildGrid()),
                  ],
                ),
              )
            : KeyedSubtree(
                key: ValueKey('detail_view_${_selectedEpisode!.episodeNumber}'),
                child: _buildDetailAndSource(_selectedEpisode!),
              ),
      ),
    );
  }

  // ─────────────────────────── Grid view ───────────────────────────

  /// The episodes, the whole screen high, scrolling under a floating
  /// header — the title, season picker and close button as glass islands,
  /// as on the app's pages — rather than below a header strip that cut
  /// the cards off along its edge.
  Widget _buildGrid() {
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _gridScrollController.hasClients) {
                  final restore = _gridOffsetToRestore;
                  // (Not the outgoing grid, fading out as an episode
                  // opens: the one coming back.)
                  if (restore != null && _selectedEpisode == null) {
                    _gridOffsetToRestore = null;
                    _gridScrollController.jumpTo(restore.clamp(0.0,
                        _gridScrollController.position.maxScrollExtent));
                  } else {
                    _scrollToCurrentEpisode(constraints.maxWidth);
                  }
                }
              });
              return GridView.builder(
                controller: _gridScrollController,
                padding: EdgeInsets.fromLTRB(
                    _gridPadding, _gridTop, _gridPadding, _gridPadding),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _crossAxisCount,
                  crossAxisSpacing: _gap,
                  mainAxisSpacing: _gap,
                  mainAxisExtent: _itemHeightFor(constraints.maxWidth),
                ),
                itemCount: widget.episodes.length,
                itemBuilder: (context, index) =>
                    _buildGridCard(widget.episodes[index]),
              );
            },
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _buildHeader(),
        ),
      ],
    );
  }

  /// Close, the show's logo (or name), and the season picker: one piece
  /// of glass, each bubble growing out of the last (GlassBubbleBar), as
  /// the details screen's back button and title — floating over the grid.
  Widget _buildHeader() {
    final seasons = widget.seasons?.where((s) => s.seasonNumber > 0).toList();
    final picker = seasons == null || seasons.isEmpty
        ? null
        : SeasonPicker(
            bare: true,
            seasons: seasons,
            current: widget.currentSeason,
            onSelected: widget.onSeasonChanged,
          );
    final close = CircleAvatar(
      backgroundColor: Colors.transparent,
      child: IconButton(
        icon: const Icon(Icons.close_rounded, color: Colors.white),
        tooltip: 'Close',
        onPressed: widget.onClose,
        iconSize: 20,
        padding: EdgeInsets.zero,
      ),
    );
    // In the side panel, beside the playing video, the show's logo is
    // already on screen: just the season picker and close, in the right
    // corner — one piece of glass, as the details screen's back button and
    // title (GlassBubbleBar), mirrored: close in the corner, the season
    // bubble grown out of it to the left.
    if (widget.asPanel) {
      return Padding(
        padding:
            EdgeInsets.fromLTRB(_gridPadding, _headerTop, _gridPadding, 0),
        child: Align(
          alignment: Alignment.centerRight,
          child: seasons == null || seasons.isEmpty
              ? GlassCircleButton(
                  icon: Icons.close_rounded,
                  onPressed: widget.onClose,
                )
              : GlassBubbleBar(
                  reveal: 1,
                  leadingOnRight: true,
                  leading: close,
                  titlePadding: 0,
                  // The bubble's full height, so all of it takes the click.
                  title: SizedBox(
                    height: kNavButtonHeight,
                    child: SeasonPicker(
                      bare: true,
                      large: true,
                      menuTapGroup: EpisodeBrowser.panelTapGroup,
                      seasons: seasons,
                      current: widget.currentSeason,
                      onSelected: widget.onSeasonChanged,
                    ),
                  ),
                ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(_gridPadding, _headerTop, _gridPadding, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GlassBubbleBar(
          reveal: 1,
          leading: close,
          // The full details: the copy passed as movie often has no logo,
          // which left the name in plain text.
          title: MovieTitleLogo(movie: widget.details),
          trailing: picker,
        ),
      ),
    );
  }

  /// Whether [ep] (of the season being browsed) is the one playing.
  bool _isPlaying(Episode ep) =>
      widget.currentSeason == widget.playingSeason &&
      ep.episodeNumber == widget.playingEpisode;

  /// The details screen's episode card (see EpisodeCard) — unaired
  /// episodes greyed out and inert, the playing one marked.
  Widget _buildGridCard(Episode ep) {
    final progress = SavedMoviesService().getEpisodeProgress(
          widget.movie.id,
          widget.currentSeason,
          ep.episodeNumber,
        ) ??
        ep.progress;
    final card = EpisodeCard(
      episode: ep,
      fallbackImage: widget.details.backdrop ?? widget.movie.backdrop,
      progress: progress,
      playing: _isPlaying(ep),
      onTap: () => setState(() {
        if (_gridScrollController.hasClients) {
          _gridOffsetToRestore = _gridScrollController.offset;
        }
        _selectedEpisode = ep;
      }),
    );
    // On a TV, the remote starts on the episode that's playing.
    return _isPlaying(ep) ? TvAutoSelect(child: card) : card;
  }

  // ─────────────────────── Detail + source view ───────────────────────

  /// The details screen's episode popup (EpisodeSheetFrame +
  /// EpisodeDetailHeader + the qualities), laid out sideways: on the
  /// episode's blurred still, its header on the left and the qualities on
  /// the right, with frosted back / close buttons over the top corners.
  ///
  /// The backdrop and the still run edge to edge, under a camera cutout,
  /// like the video does; the text, buttons and qualities keep clear of it.
  Widget _buildDetailAndSource(Episode ep) {
    final safe = MediaQuery.paddingOf(context);
    final fallback = widget.details.backdrop ?? widget.movie.backdrop;
    final progress = SavedMoviesService().getEpisodeProgress(
          widget.movie.id,
          widget.currentSeason,
          ep.episodeNumber,
        ) ??
        ep.progress;

    // The side panel: down it instead (_buildDetailColumn).
    if (widget.asPanel) {
      return _buildDetailColumn(ep, fallback, progress);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: EpisodeBackdrop(image: ep.stillPath ?? fallback, dim: 0.6),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: EpisodeDetailHeader(
                  episode: ep,
                  fallbackImage: fallback,
                  progress: progress,
                  sideways: true,
                  textInset: EdgeInsets.only(
                    left: safe.left,
                    bottom: safe.bottom,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Padding(
                // Clear of the close button, and of a cutout on the right.
                padding: EdgeInsets.only(top: 52 + safe.top, right: safe.right),
                child: _EpisodeSourcePicker(
                  key: ValueKey(
                      '${widget.currentSeason}_${ep.episodeNumber}'),
                  resolver: widget.resolver,
                  imdbId: widget.imdbId,
                  details: widget.details,
                  season: widget.currentSeason,
                  episode: ep.episodeNumber,
                  playingStream: _isPlaying(ep) ? widget.playingStream : null,
                  onAudioLanguageChanged: widget.onAudioLanguageChanged,
                  onTorrentChosen: (stream, allStreams) =>
                      widget.onTorrentChosen(
                          ep, widget.currentSeason, stream, allStreams),
                  onWebPlayerChosen: (provider) => widget.onWebPlayerChosen(
                      ep, widget.currentSeason, provider),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          top: 12 + safe.top,
          left: 16 + safe.left,
          child: GlassCircleButton(
            icon: GlassCircleButton.backIcon,
            iconSize: GlassCircleButton.backIconSize,
            onPressed: () => setState(() => _selectedEpisode = null),
          ),
        ),
        Positioned(
          top: 12 + safe.top,
          right: 16 + safe.right,
          child: GlassCircleButton(
            icon: Icons.close_rounded,
            onPressed: widget.onClose,
          ),
        ),
      ],
    );
  }

  /// [_buildDetailAndSource] in the side panel (see [EpisodeBrowser.
  /// asPanel]), a phone screen wide: as the details screen's episode popup
  /// on a phone — the still across the top, the episode's name, time and
  /// description over its foot, the qualities under them — on the panel's
  /// frosted glass, scrolling as one. Back and close float over
  /// the top corners.
  Widget _buildDetailColumn(Episode ep, String? fallback, double? progress) {
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EpisodeDetailHeader(
                  episode: ep,
                  fallbackImage: fallback,
                  progress: progress,
                ),
                _EpisodeSourcePicker(
                  key: ValueKey('${widget.currentSeason}_${ep.episodeNumber}'),
                  inCard: true,
                  resolver: widget.resolver,
                  imdbId: widget.imdbId,
                  details: widget.details,
                  season: widget.currentSeason,
                  episode: ep.episodeNumber,
                  playingStream: _isPlaying(ep) ? widget.playingStream : null,
                  onAudioLanguageChanged: widget.onAudioLanguageChanged,
                  onTorrentChosen: (stream, allStreams) =>
                      widget.onTorrentChosen(
                          ep, widget.currentSeason, stream, allStreams),
                  onWebPlayerChosen: (provider) => widget.onWebPlayerChosen(
                      ep, widget.currentSeason, provider),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          child: GlassCircleButton(
            icon: GlassCircleButton.backIcon,
            iconSize: GlassCircleButton.backIconSize,
            onPressed: () => setState(() => _selectedEpisode = null),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: GlassCircleButton(
            icon: Icons.close_rounded,
            onPressed: widget.onClose,
          ),
        ),
      ],
    );
  }
}

/// Right-panel source list: fetches available torrent streams for one
/// episode and lets the user pick a quality (or, when [_showWebServers] is
/// on, a web player server) — purely a picker, it never resolves anything
/// itself.
class _EpisodeSourcePicker extends StatefulWidget {
  final StreamResolver resolver;
  final String imdbId;
  final Movie details;
  final int season;
  final int episode;
  final void Function(TorrentStream stream, List<TorrentStream> allStreams)
      onTorrentChosen;
  final ValueChanged<String> onWebPlayerChosen;

  /// The copy playing, when this is the episode playing: its quality is
  /// marked, and can't be picked (see QualityOptionList.isCurrent).
  final TorrentStream? playingStream;

  /// The copy playing was picked again in another audio language (saved
  /// by then): what's playing should switch to it. See
  /// EpisodeBrowser.onAudioLanguageChanged.
  final VoidCallback? onAudioLanguageChanged;

  /// The web player servers are hidden for now, like the Play popup's
  /// (see TorrentQualitySelectorSheet.showWebServers).
  static const bool _showWebServers = false;

  /// In the side panel's episode view (see _buildDetailColumn), under the
  /// episode's header: as tall as its rows (the view scrolls as one), and
  /// inset as the header's text is.
  final bool inCard;

  const _EpisodeSourcePicker({
    super.key,
    this.inCard = false,
    required this.resolver,
    required this.imdbId,
    required this.details,
    required this.season,
    required this.episode,
    required this.onTorrentChosen,
    required this.onWebPlayerChosen,
    this.playingStream,
    this.onAudioLanguageChanged,
  });

  @override
  State<_EpisodeSourcePicker> createState() => _EpisodeSourcePickerState();
}

class _EpisodeSourcePickerState extends State<_EpisodeSourcePicker> {
  List<TorrentStream>? _streams;
  List<QualityOption>? _options;
  bool _loading = true;
  String? _error;
  // The likely picks, connecting ahead of a tap (see StreamResolver.warmUp).
  List<TorrentStream> _warmed = const [];
  // The audio language the list is in: the one saved for the series
  // (what's playing) until another is picked to look at. Only saved once
  // a quality is picked in it (see _choose) — looking changes nothing.
  AudioLanguage? _language;
  // Audio languages with no copy: greyed out in the picker.
  Set<AudioLanguage> _noCopiesIn = const {};

  @override
  void initState() {
    super.initState();
    // Back to the saved language when it's changed in the player's Audio
    // menu.
    AudioLanguageService().changes.addListener(_followSaved);
    _load();
  }

  void _followSaved() {
    final saved = AudioLanguageService().of(widget.details);
    if (saved == _language) return;
    _language = saved;
    _reload();
  }

  @override
  void dispose() {
    AudioLanguageService().changes.removeListener(_followSaved);
    widget.resolver.coolDown(_warmed);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    widget.resolver.coolDown(_warmed);
    _warmed = const [];
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }

  /// Picked in the list's Audio row: the qualities listed in it, to look
  /// at. Nothing playing changes, and nothing's saved, until a quality is
  /// picked (see [_choose]).
  void _showLanguage(AudioLanguage choice) {
    if (choice == _language) return;
    _language = choice;
    _reload();
  }

  /// Whether the list is in the language what's playing is in.
  bool get _inPlayingLanguage =>
      _language == null || _language == AudioLanguageService().of(widget.details);

  /// A quality picked: its language saved for the whole series if it's
  /// another, then played — or, for the copy already playing (now wanted
  /// in another language), just its soundtrack switched.
  Future<void> _choose(QualityOption option) async {
    if (_choosing) return;
    _choosing = true;
    try {
      final languages = AudioLanguageService();
      final language = _language;
      final changed =
          language != null && language != languages.of(widget.details);
      if (changed) await languages.set(widget.details, language);
      if (!mounted) return;
      final playing = widget.playingStream;
      if (changed &&
          playing != null &&
          option.best.infoHash.toLowerCase() ==
              playing.infoHash.toLowerCase()) {
        widget.onAudioLanguageChanged?.call();
        return;
      }
      widget.onTorrentChosen(option.best, _streams!);
    } finally {
      _choosing = false;
    }
  }

  // A pick is being handled (see [_choose]): a second tap is ignored.
  bool _choosing = false;

  Future<void> _load() async {
    try {
      final languages = AudioLanguageService();
      await languages.ensureLoaded();
      _language ??= languages.of(widget.details);
      final list = await widget.resolver.getAvailableStreams(
        imdbId: widget.imdbId,
        type: 'tv',
        season: widget.season,
        episode: widget.episode,
        title: widget.details,
        audioLanguage: _language,
      );
      // A language with no copy can't be picked (greyed out in the
      // picker); listed in one, the qualities move to the other.
      var noCopiesIn = <AudioLanguage>{};
      if (AudioLanguageService.appliesTo(widget.details)) {
        final shown = _language!;
        final other = shown == AudioLanguage.original
            ? AudioLanguage.english
            : AudioLanguage.original;
        final inOther = await widget.resolver.getAvailableStreams(
          imdbId: widget.imdbId,
          type: 'tv',
          season: widget.season,
          episode: widget.episode,
          title: widget.details,
          audioLanguage: other,
        );
        if (!mounted) return;
        if (list.isEmpty && inOther.isNotEmpty) {
          _language = other;
          return _load();
        }
        noCopiesIn = {if (list.isEmpty) shown, if (inOther.isEmpty) other};
      }
      if (mounted) {
        setState(() {
          _streams = list;
          _noCopiesIn = noCopiesIn;
          _options = StreamResolver.qualityOptions(list,
              preferHash: widget.playingStream?.infoHash);
          _loading = false;
        });
        // The episode playing needs no head start.
        if (widget.playingStream != null) return;
        final prefs = await SharedPreferences.getInstance();
        final lastPlayed = await LastPlayedTorrents.lastPlayed(
            prefs,
            'last_played_torrent_'
            '${widget.imdbId}_${widget.season}_${widget.episode}',
            widget.details,
            language: _language);
        if (!mounted) return;
        _warmed = StreamResolver.headStartCandidates(
          list,
          lastPlayedHash: lastPlayed,
        );
        widget.resolver.warmUp(
          _warmed,
          resumeAt: SavedMoviesService()
              .getEpisodeProgress(widget.details.id, widget.season, widget.episode),
        );
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: widget.inCard
          ? const EdgeInsets.fromLTRB(20, 12, 20, 20)
          : const EdgeInsets.fromLTRB(8, 12, 24, 24),
      child: ListView(
        shrinkWrap: widget.inCard,
        physics: widget.inCard ? const NeverScrollableScrollPhysics() : null,
        padding: widget.inCard ? EdgeInsets.zero : null,
        children: [
          // English or the original soundtrack, for a series not made in
          // English: lists the qualities in it (see _showLanguage).
          if (AudioLanguageService.appliesTo(widget.details)) ...[
            AudioLanguagePicker(
              title: widget.details,
              selected: _language,
              unavailable: _noCopiesIn,
              enabled: !_loading,
              onChanged: _showLanguage,
            ),
            const SizedBox(height: 16),
          ],
          const QualitySectionLabel('Choose quality'),
          const SizedBox(height: 10),
          if (_loading)
            const QualityOptionListSkeleton(compact: true)
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.white54))
          else if (_options == null || _options!.isEmpty)
            const Text(
              'Not available to stream right now.',
              style: TextStyle(color: Colors.white54),
            )
          else
            _buildOptionList(_options!),
          if (_EpisodeSourcePicker._showWebServers) ...[
            const SizedBox(height: 24),
            const Text(
              'Web Player',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildWebPlayerOptions(),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionList(List<QualityOption> options) {
    // The resolver sorts its overall pick first (see getAvailableStreams).
    final recommendedTier = StreamResolver.tierOf(_streams!.first);
    // Marked as playing only in the language it's playing in.
    final playing = _inPlayingLanguage ? widget.playingStream : null;
    final playingTier = playing == null ? null : StreamResolver.tierOf(playing);
    return QualityOptionList(
      options: options,
      compact: true,
      isCurrent: (option) => option.tier == playingTier,
      tagFor: (option) => option.tier == playingTier
          ? 'Playing'
          : (option.tier == recommendedTier ? 'Recommended' : null),
      // The episode playing: nothing's the obvious next pick.
      isPrimary: (option) =>
          playingTier == null && option.tier == recommendedTier,
      onSelected: _choose,
    );
  }

  Widget _buildWebPlayerOptions() {
    final defaultProvider = Platform.isIOS ? 'vsembed' : 'vidlink';
    final altProvider = Platform.isIOS ? 'vidlink' : 'vsembed';
    final servers = <String, String>{
      defaultProvider: Platform.isIOS ? 'Server 4' : 'Server 1',
      'moviesapi': 'Server 2',
      '2embed': 'Server 3',
      altProvider: Platform.isIOS ? 'Server 1' : 'Server 4',
    };

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: servers.entries
          .map(
            (entry) => OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => widget.onWebPlayerChosen(entry.key),
              child: Text(entry.value),
            ),
          )
          .toList(),
    );
  }
}
