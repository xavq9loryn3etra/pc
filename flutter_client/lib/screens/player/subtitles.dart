part of '../player_screen.dart';

/// The shown subtitles' timing: being checked (glowing blocks in their
/// place), known to fit, or none of the language's copies fits so far.
enum _SubtitleTiming { checking, ready, noFit }

extension _PlayerSubtitles on _PlayerScreenState {
  /// Subtitles just above the seek bar while the controls are up (they
  /// were under it), at the foot again once they're gone — moved smoothly.
  void _placeSubtitles() {
    var bottom = 24.0;
    if (_controlsVisible && !_showSettingsPanel) {
      final box = _bottomBarKey.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        final barTop = _topLeftInPlayer(box).dy;
        bottom = MediaQuery.sizeOf(context).height - barTop + 12;
      }
    }
    if ((bottom - _subtitleBottom.value).abs() < 1) return;
    _subtitleBottom.value = bottom;
    _videoKey.currentState?.setSubtitleViewPadding(
      EdgeInsets.fromLTRB(16, 0, 16, bottom),
      duration: const Duration(milliseconds: 250),
    );
  }

  TextStyle _subtitleStyle() {
    final track = _selectedSubtitle;
    return TextStyle(
      // Keep Sinhala punctuation and spaces in the same font as the words.
      fontFamily: track != null && _getLanguageName(track.lang) == 'Sinhala'
          ? 'NotoSansSinhala'
          : null,
      height: 1.4,
      fontSize: 38,
      letterSpacing: 0,
      wordSpacing: 0,
      color: _isPlaying ? Colors.white : Colors.transparent,
      fontWeight: TvDevice.isTv ? FontWeight.w500 : FontWeight.normal,
      backgroundColor: _isPlaying
          ? const Color(0xaa000000)
          : Colors.transparent,
      fontFamilyFallback: ['NotoSansSinhala'],
    );
  }

  String _getLanguageName(String code) {
    final cleanCode = code.toLowerCase().trim();
    switch (cleanCode) {
      case 'eng':
      case 'en':
        return 'English';
      case 'spa':
      case 'es':
        return 'Spanish';
      case 'fre':
      case 'fra':
      case 'fr':
        return 'French';
      case 'ger':
      case 'deu':
      case 'de':
        return 'German';
      case 'ita':
      case 'it':
        return 'Italian';
      case 'por':
      case 'pt':
        return 'Portuguese';
      case 'rus':
      case 'ru':
        return 'Russian';
      case 'chi':
      case 'zho':
      case 'zh':
        return 'Chinese';
      case 'jpn':
      case 'ja':
        return 'Japanese';
      case 'ara':
      case 'ar':
        return 'Arabic';
      case 'tur':
      case 'tr':
        return 'Turkish';
      case 'dut':
      case 'nld':
      case 'nl':
        return 'Dutch';
      case 'swe':
      case 'sv':
        return 'Swedish';
      case 'nor':
      case 'no':
        return 'Norwegian';
      case 'dan':
      case 'da':
        return 'Danish';
      case 'fin':
      case 'fi':
        return 'Finnish';
      case 'pol':
      case 'pl':
        return 'Polish';
      case 'ind':
      case 'id':
        return 'Indonesian';
      case 'vie':
      case 'vi':
        return 'Vietnamese';
      case 'hin':
      case 'hi':
        return 'Hindi';
      case 'sin':
      case 'si':
        return 'Sinhala';
      case 'tam':
      case 'ta':
        return 'Tamil';
      case 'tel':
      case 'te':
        return 'Telugu';
      case 'mal':
      case 'ml':
        return 'Malayalam';
      case 'kan':
      case 'kn':
        return 'Kannada';
      case 'ben':
      case 'bn':
        return 'Bengali';
      case 'urd':
      case 'ur':
        return 'Urdu';
      case 'may':
      case 'msa':
      case 'ms':
        return 'Malay';
      case 'tha':
      case 'th':
        return 'Thai';
      case 'kor':
      case 'ko':
        return 'Korean';
      case 'per':
      case 'fas':
      case 'fa':
        return 'Persian';
      case 'heb':
      case 'he':
        return 'Hebrew';
      case 'ell':
      case 'gre':
      case 'el':
        return 'Greek';
      case 'pob':
      case 'pb':
        return 'Portuguese (Brazil)';
      case 'hrv':
      case 'scr':
      case 'hr':
        return 'Croatian';
      case 'alb':
      case 'sqi':
      case 'sq':
        return 'Albanian';
      case 'srp':
      case 'scc':
      case 'sr':
        return 'Serbian';
      case 'bos':
      case 'bs':
        return 'Bosnian';
      case 'slv':
      case 'sl':
        return 'Slovenian';
      case 'mac':
      case 'mkd':
      case 'mk':
        return 'Macedonian';
      case 'bul':
      case 'bg':
        return 'Bulgarian';
      case 'ron':
      case 'rum':
      case 'ro':
        return 'Romanian';
      case 'hun':
      case 'hu':
        return 'Hungarian';
      case 'ces':
      case 'cze':
      case 'cs':
        return 'Czech';
      case 'slk':
      case 'slo':
      case 'sk':
        return 'Slovak';
      case 'ukr':
      case 'uk':
        return 'Ukrainian';
      case 'est':
      case 'et':
        return 'Estonian';
      case 'lav':
      case 'lv':
        return 'Latvian';
      case 'lit':
      case 'lt':
        return 'Lithuanian';
      case 'ice':
      case 'isl':
      case 'is':
        return 'Icelandic';
      case 'cat':
      case 'ca':
        return 'Catalan';
      case 'baq':
      case 'eus':
      case 'eu':
        return 'Basque';
      case 'glg':
      case 'gl':
        return 'Galician';
      case 'geo':
      case 'kat':
      case 'ka':
        return 'Georgian';
      case 'arm':
      case 'hye':
      case 'hy':
        return 'Armenian';
      case 'aze':
      case 'az':
        return 'Azerbaijani';
      case 'kaz':
      case 'kk':
        return 'Kazakh';
      case 'uzb':
      case 'uz':
        return 'Uzbek';
      case 'tgl':
      case 'fil':
      case 'tl':
        return 'Filipino';
      case 'zht':
      case 'zhe':
        return 'Chinese (Traditional)';
      case 'spn':
      case 'ea':
        return 'Spanish (Latin America)';
      case 'nep':
      case 'ne':
        return 'Nepali';
      case 'mar':
      case 'mr':
        return 'Marathi';
      case 'pan':
      case 'pa':
        return 'Punjabi';
      case 'guj':
      case 'gu':
        return 'Gujarati';
      case 'swa':
      case 'sw':
        return 'Swahili';
      case 'afr':
      case 'af':
        return 'Afrikaans';
      case 'mon':
      case 'mn':
        return 'Mongolian';
      case 'khm':
      case 'km':
        return 'Khmer';
      case 'bur':
      case 'mya':
      case 'my':
        return 'Burmese';
      case 'lao':
      case 'lo':
        return 'Lao';
      case 'kur':
      case 'ku':
        return 'Kurdish';
      case 'pus':
      case 'ps':
        return 'Pashto';
      case 'amh':
      case 'am':
        return 'Amharic';
      default:
        return code.toUpperCase();
    }
  }

  /// Deletes the retimed subtitle files written to the temp folder (see
  /// _retimeFromReferences) and forgets them: they were for one file.
  void _discardRetimedFiles() {
    for (final path in [..._retimedPaths.values, ..._driftPaths.values]) {
      File(path).delete().ignore();
    }
    _retimedPaths.clear();
    _driftPaths.clear();
    _driftPoints.clear();
  }

  /// Everything learnt about subtitles' timing: it was for one file (another
  /// copy, or episode, is timed afresh). Called inside setState.
  void _forgetSubtitleTiming() {
    _discardRetimedFiles();
    _subtitleTimings.clear();
    _autoSynced.clear();
    _autoSyncTries.clear();
    _autoSyncSeen.clear();
    _heardStretches.clear();
    _listened.clear();
    _testedOn.clear();
    _watchedRanges.clear();
    _nextListenAt = Duration.zero;
    _noFitLanguage = null;
    _retimedWith.clear();
    _referenceTimed.clear();
    // Another video: subtitles that didn't fit the last may fit this one.
    _rejectedSubtitles.clear();
    _kindCache.clear();
    _conflictCache.clear();
    _cuesFailed.clear();
    _resyncing = null;
    _resyncKept = null;
    _distrusted.clear();
  }

  /// Before opening another copy of the same video (a quality switch, a
  /// reconnect): the old file's built-in tracks, and one picked from them,
  /// don't belong to the new file — each file's tracks are numbered afresh,
  /// so the old number could be another language there, or nothing. The
  /// viewer's language is kept (saved when they picked it), so the new
  /// file's track in it is picked once its tracks are read; a downloaded
  /// track stays on meanwhile. Called inside setState.
  void _forgetFileSubtitles() {
    _stopSinhala();
    _forgetSubtitleTiming();
    // Made for the old file isn't made for this one (its fingerprint is
    // looked up again once it plays).
    _externalSubtitles = [
      for (final s in _externalSubtitles)
        if (s.matchesFile)
          SubtitleTrackData(
            id: s.id,
            url: s.url,
            lang: s.lang,
            label: s.label,
            releaseName: s.releaseName,
            releaseGroup: s.releaseGroup,
          )
        else
          s,
    ];
    _embeddedSubtitles = [];
    _userPickedSubtitleForThisVideo = false;
    if (_selectedSubtitle?.isEmbedded ?? false) _selectedSubtitle = null;
    _availableSubtitles = [..._externalSubtitles];
  }

  static bool _isPictureSubtitle(String? codec) {
    final c = (codec ?? '').toLowerCase();
    return c.contains('pgs') ||
        c.contains('dvd_sub') ||
        c.contains('dvdsub') ||
        c.contains('vobsub') ||
        c.contains('dvb_sub') ||
        c.contains('dvbsub') ||
        c.contains('xsub');
  }

  /// The subtitle tracks the player was given from a download (sub-add:
  /// see _applySubtitleTrackToPlayer) — its id → the file's url. They're
  /// in its track list with the video's own, and media_kit doesn't tell
  /// them apart; mpv's own list does.
  Future<Map<String, String>> _addedSubtitleTracks() async {
    try {
      final raw =
          await (player.platform as NativePlayer).getProperty('track-list');
      final list = jsonDecode(raw);
      if (list is! List) return const {};
      return {
        for (final t in list)
          if (t is Map && t['type'] == 'sub' && t['external'] == true)
            '${t['id']}': '${t['external-filename'] ?? ''}',
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _onMpvTracksChanged(Tracks tracks) async {
    if (!mounted) return;
    _scheduleAudioCheck();
    // Downloaded subtitles given to the player aren't the video's own:
    // they'd be listed twice, the second time as "Embedded in video" —
    // and picked first, as if made for it.
    final added = await _addedSubtitleTracks();
    if (!mounted) return;
    final embedded = <SubtitleTrackData>[];
    for (final s in tracks.subtitle) {
      if (s.id == 'no' || s.id == 'auto' || s.uri) continue;
      if (added.containsKey(s.id)) continue;
      // Picture subtitles (Blu-ray PGS, DVD VobSub, DVB) can't be shown:
      // the subtitles are drawn from mpv's text, and these have none.
      // Left out, so a text track or a downloaded one is picked instead.
      if (_isPictureSubtitle(s.codec)) continue;
      final lang = (s.language ?? '').trim();
      final title = (s.title ?? '').trim();
      if (lang.isEmpty && title.isEmpty) continue;
      embedded.add(SubtitleTrackData(
        id: 'embedded:${s.id}',
        url: s.id,
        lang: lang.isNotEmpty ? lang : title,
        label: title.isNotEmpty ? title : null,
        isEmbedded: true,
      ));
    }

    // Sort non-forced / full dialogue tracks ahead of forced / signs / SDH
    // tracks so auto-selection picks full dialogue first.
    int trackRank(SubtitleTrackData t) {
      final l = (t.label ?? '').toLowerCase();
      if (l.contains('forced') || l.contains('sign')) return 2;
      if (l.contains('sdh') || l.contains('cc')) return 1;
      return 0;
    }

    embedded.sort((a, b) => trackRank(a).compareTo(trackRank(b)));
    _embeddedSubtitles = embedded;
    BuiltInSubtitles.noteTracks(_currentStream.infoHash, embedded);
    _rebuildAvailableSubtitles();
  }

  Future<void> _loadSubtitles() async {
    final imdbId = widget.details.imdbId ?? widget.movie.imdbId;
    if (imdbId == null || imdbId.isEmpty) {
      print('Subtitle load skipped: No IMDB ID available.');
      return;
    }

    if (mounted) {
      _updateState(() => _isLoadingSubtitles = true);
    }

    try {
      final isTv = widget.movie.type == 'tv';
      // (Subtitles made for this very file are looked for once the video
      // plays: see _fingerprintSubtitles.)
      final stream = _currentStream;
      final videoSizeBytes =
          TorrentDownloadRegistry.parseSizeBytes(stream.size);
      List<SubtitleTrackData> subs;
      final imdbEpisode = isTv ? await _imdbEpisode(imdbId) : null;
      if (!mounted) return;
      if (imdbEpisode != null) {
        subs = await SubtitleService().fetchSubtitles(
          imdbId,
          season: imdbEpisode.$1,
          episode: imdbEpisode.$2,
          videoSizeBytes: videoSizeBytes,
          filename: stream.name,
        );
      } else {
        subs = await SubtitleService().fetchSubtitles(
          imdbId,
          videoSizeBytes: videoSizeBytes,
          filename: stream.name,
        );
      }

      if (!mounted) return;
      // Not those named for another episode (uploaded under this one).
      if (imdbEpisode != null) {
        final wanted = [
          imdbEpisode,
          if (_currentSeason != null && _currentEpisode != null)
            (_currentSeason!, _currentEpisode!),
        ];
        final before = subs.length;
        subs = [
          for (final s in subs)
            if (!SubtitleService.namesAnotherEpisode(s, wanted)) s,
        ];
        if (subs.length < before) {
          print('[subtitles] ${before - subs.length} left out: named for '
              'another episode');
        }
      }
      // Made for the same release first (see rank): the language's first
      // is the one picked.
      subs = SubtitleService.rank(subs, '${stream.title}\n${stream.name}');
      print('[subtitles] ${subs.length} found');

      // Any found meanwhile by the file's fingerprint (see
      // _fingerprintSubtitles) kept, first: this list knows nothing of it.
      final exact = [
        for (final s in _externalSubtitles)
          if (s.matchesFile) s,
      ];
      final exactIds = {for (final s in exact) s.id};
      _externalSubtitles = [
        ...exact,
        for (final s in subs)
          if (!exactIds.contains(s.id)) s,
      ];
      _updateState(() => _isLoadingSubtitles = false);
      await _rebuildAvailableSubtitles();
    } catch (e) {
      print('Error loading subtitles: $e');
      if (mounted) {
        _updateState(() => _isLoadingSubtitles = false);
      }
    }
  }

  /// The episode playing in IMDb's numbering, which the subtitle finder
  /// (OpenSubtitles) goes by, like the stream finders — for long anime it
  /// isn't TMDB's, shown in the app (One Piece: TMDB's season 12 episode
  /// 408 is IMDb's season 13 episode 27). Asked by TMDB's numbers, it found
  /// nothing or another episode's: no subtitles, so no Sinhala either.
  /// Null without a season and episode.
  Future<(int, int)?> _imdbEpisode(String imdbId) async {
    final season = _currentSeason;
    final episode = _currentEpisode;
    if (season == null || episode == null) return null;
    return EpisodeNumbering().toImdb(
      imdbId: imdbId,
      tmdbId: widget.details.id,
      season: season,
      episode: episode,
    );
  }

  /// Subtitles made for this very file — found by its fingerprint (its size
  /// and first and last 64 KB) — added to the list, first: they're in time
  /// with it from the start, so one in the language being watched is
  /// switched to at once (see _rebuildAvailableSubtitles). Looked for as
  /// soon as the video plays, not before: on a torrent, reading the file's
  /// end has the engine fetch it first, which slowed starting (the subtitle
  /// list waited on it). Its two 64 KB reads never take over playback's
  /// (the engine's serve_range).
  Future<void> _fingerprintSubtitles() async {
    final url = _streamUrl;
    final imdbId = widget.details.imdbId ?? widget.movie.imdbId;
    if (url.isEmpty || imdbId == null || _fingerprinted == url) return;
    _fingerprinted = url;
    final fingerprint = await SubtitleService().videoFingerprint(url);
    if (!mounted || _streamUrl != url) return;
    if (fingerprint == null) {
      print('[subtitles] no fingerprint');
      return;
    }
    final isTv = widget.movie.type == 'tv';
    final imdbEpisode = isTv ? await _imdbEpisode(imdbId) : null;
    if (!mounted || _streamUrl != url) return;
    final found = await SubtitleService().fetchSubtitles(
      imdbId,
      season: imdbEpisode?.$1,
      episode: imdbEpisode?.$2,
      videoSizeBytes: fingerprint.size,
      filename: _currentStream.name,
      videoHash: fingerprint.hash,
    );
    final exact = found.where((s) => s.matchesFile).toList();
    print('[subtitles] fingerprint ${fingerprint.hash}: '
        '${exact.length} made for this file');
    if (!mounted || _streamUrl != url || exact.isEmpty) return;
    final ids = {for (final s in exact) s.id};
    _externalSubtitles = [
      ...exact,
      ..._externalSubtitles.where((s) => !ids.contains(s.id)),
    ];
    // Picked again: one made for this file now comes first in its
    // language, and is switched to.
    await _rebuildAvailableSubtitles();
  }

  /// The timings confirmed for copies of this video before (see
  /// _rememberTiming), every copy's: one known to fit is picked at once,
  /// not checked afresh behind another.
  Future<void> _loadSavedTimings() async {
    final url = _streamUrl;
    final store = SubtitleTimingStore();
    await store.init();
    if (!mounted || _streamUrl != url) return;
    for (final s in _externalSubtitles) {
      if (_autoSynced.contains(s.id) ||
          _referenceTimed.contains(s.id) ||
          _distrusted.contains(s.id)) {
        continue;
      }
      final saved = store.kept(_timingKey(s));
      if (saved == null) continue;
      _autoSynced.add(s.id);
      _subtitleTimings[s.id] = (delay: saved.delay, speed: saved.speed);
    }
  }

  Future<void> _rebuildAvailableSubtitles() async {
    // After this, whatever stays selected: retimed if it can be now.
    Future<void>.delayed(Duration.zero, _retimeSelected);
    await _loadSavedTimings();
    await _loadSeriesTimings();
    if (!mounted) return;
    final sinhala = _sinhalaTrack();
    // Each language's best first (the panel shows one per language).
    final ordered = [..._embeddedSubtitles, ..._externalSubtitles];
    final position = {for (var i = 0; i < ordered.length; i++) ordered[i].id: i};
    ordered.sort((a, b) {
      final byRank = _copyRank(a).compareTo(_copyRank(b));
      return byRank != 0 ? byRank : position[a.id]!.compareTo(position[b.id]!);
    });
    final combined = <SubtitleTrackData>[
      if (sinhala != null) sinhala,
      ...ordered,
    ];
    if (mounted) {
      _updateState(() {
        _availableSubtitles = combined;
        // The one shown, as the list has it now: found again by the file's
        // fingerprint, it's "made for this file" only in the new entry.
        final shown = _selectedSubtitle;
        final fresh = shown == null
            ? null
            : combined.where((s) => s.id == shown.id).firstOrNull;
        if (fresh != null && !identical(fresh, shown)) {
          _selectedSubtitle = fresh;
        }
      });
    }

    // The language: the viewer's choice for this video (or off), else
    // their usual one. The copy in it is the app's to pick, and to swap
    // as better ones turn up: built into the file, made for it, or timed
    // (see _copyRank) — Netflix-style, one button per language.
    final String language;
    if (_userPickedSubtitleForThisVideo) {
      final chosen = _selectedSubtitle;
      if (chosen == null) return; // Turned off.
      language = _getLanguageName(chosen.lang);
    } else {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _userPickedSubtitleForThisVideo) return;
      final preferred =
          prefs.getString(_PlayerScreenState._subtitleLangPrefKey) ?? 'eng';
      if (preferred.isEmpty) {
        if (_selectedSubtitle != null) {
          await _selectSubtitle(null, remember: false);
        }
        return;
      }
      language = _getLanguageName(preferred);
    }

    // Sinhala chosen and none made by people: made from English, with the
    // viewer's Gemini key.
    final bestMatch = _bestSubtitleIn(language) ??
        (language == 'Sinhala' && GeminiKeyService().hasKey ? sinhala : null);
    // The language with nothing to show for it (yet, or every copy ruled
    // out): left be — the panel says none fits — rather than turned off.
    final shown = _selectedSubtitle;
    if (bestMatch == null &&
        (_userPickedSubtitleForThisVideo ||
            (shown != null && _getLanguageName(shown.lang) == language))) {
      return;
    }
    if (!mounted) return;
    if (bestMatch?.id != _selectedSubtitle?.id) {
      if (bestMatch != null && _selectedSubtitle != null) {
        print('[subtitles] switching to ${bestMatch.id} '
            '(${_isTimed(bestMatch) ? 'timed' : 'better match'})');
      }
      await _selectSubtitle(bestMatch, remember: false);
    }
  }

  /// Hearing a dub: English sound on a title not made in English — then
  /// subtitles written for the dub fit, and the usual ones (a translation
  /// of the original voices, built into the file or not) don't.
  bool get _hearingDub =>
      AudioLanguageService.appliesTo(widget.details) &&
      AudioLanguageService().of(widget.details) == AudioLanguage.english;

  /// How well [s] suits what's heard, best (0) first: written for what's
  /// heard (the dub's, when that's on; otherwise the original dialogue's)
  /// — built into this file or made for it first — then the rest that
  /// follow the dialogue, then signs-only tracks. Ones whose length rules
  /// them out (see _fitsLength) last.
  int _subtitleRank(SubtitleTrackData s) {
    if (_rejectedSubtitles.contains(s.id)) return 6;
    final kind = _kindOf(s);
    if (kind == SubtitleKind.signsOnly) return 5;
    if (_subtitleSourceConflicts(s)) return 4;
    final fitsWhatsHeard = _hearingDub ? _followsDub(s) : !_followsDub(s);
    if (fitsWhatsHeard) return s.isEmbedded || s.matchesFile ? 0 : 1;
    return s.isEmbedded || s.matchesFile ? 2 : 3;
  }

  bool _subtitleSourceConflicts(SubtitleTrackData track) =>
      !track.isEmbedded &&
      _conflictCache.putIfAbsent(
          track.id,
          () =>
              SubtitleService.likeness(track,
                  '${_currentStream.title}\n${_currentStream.name}') <
              0);

  /// SubtitleService.kindOf, worked out once per subtitle: it's asked for
  /// every copy each time copies are ranked (its name read by patterns).
  SubtitleKind _kindOf(SubtitleTrackData s) =>
      _kindCache.putIfAbsent(s.id, () => SubtitleService.kindOf(s));

  /// The copy picked in a language: one known to be in time with this
  /// video before any that isn't (shown now, rather than glowing blocks for
  /// minutes; a better one that's timed later takes over) — and among
  /// those, by [_subtitleRank]. Signs-only and ruled-out ones last, timed
  /// or not.
  int _copyRank(SubtitleTrackData s) {
    final rank = _subtitleRank(s);
    if (rank >= 5) return 20 + rank;
    return (_isTimed(s) ? 0 : 10) + rank;
  }

  /// Whether [s] is known to be in time with the video playing: built into
  /// it, made for it, retimed against a subtitle that is, or confirmed by
  /// listening (or, shown, when this copy played before: see
  /// _selectSubtitle). Only these are shown; the rest wait behind glowing
  /// blocks while they're checked.
  bool _isTimed(SubtitleTrackData s) {
    final source = s.translatedFrom ?? s;
    if (source.isEmbedded || _autoSynced.contains(s.id)) return true;
    // Doubted by the viewer (see _resyncSubtitles): only listening says.
    if (_distrusted.contains(source.id)) return false;
    return _referenceTimed.contains(source.id) ||
        (source.matchesFile && !_subtitleSourceConflicts(source));
  }

  /// Whether [s] follows the title's English dub: English captions, or
  /// made for a dubbed version, of a title not made in English. (Captions
  /// in another language follow something else: the Japanese "[cc]" of an
  /// anime, its Japanese voices.)
  bool _followsDub(SubtitleTrackData s) =>
      AudioLanguageService.appliesTo(widget.details) &&
      _kindOf(s) == SubtitleKind.forDub &&
      _getLanguageName(s.lang) == 'English';

  /// For the subtitle menu: what [s] follows, when its name says and it's
  /// worth telling — the English dub, or the original voices.
  String? _subtitleFollows(SubtitleTrackData s) {
    if (_kindOf(s) != SubtitleKind.forDub) return null;
    if (_followsDub(s)) return 'Follows the English dub';
    if (AudioLanguageService.appliesTo(widget.details) &&
        _getLanguageName(s.lang) ==
            AudioLanguageService.originalOf(widget.details).name) {
      return 'Captions of the ${AudioLanguageService.originalOf(widget.details).name} voices';
    }
    return null;
  }

  /// The subtitles to pick for the viewer in [languageName], or null.
  SubtitleTrackData? _bestSubtitleIn(String languageName) {
    final pool = [
      ..._embeddedSubtitles.where((s) => _getLanguageName(s.lang) == languageName),
      ..._externalSubtitles.where((s) =>
          s.url.isNotEmpty &&
          !_rejectedSubtitles.contains(s.id) &&
          _getLanguageName(s.lang) == languageName),
    ];
    if (pool.isEmpty) return null;
    final position = {for (var i = 0; i < pool.length; i++) pool[i].id: i};
    pool.sort((a, b) {
      final byRank = _copyRank(a).compareTo(_copyRank(b));
      return byRank != 0 ? byRank : position[a.id]!.compareTo(position[b.id]!);
    });
    return pool.first;
  }

  /// For the subtitle menu: hearing a dub, with subtitles in its language
  /// shown that weren't written for it (none were found that were).
  String? get _subtitleFitNote {
    final track = _selectedSubtitle;
    if (track == null || !_hearingDub || track.translatedFrom != null) {
      return null;
    }
    final heard = AudioLanguageService().languageFor(widget.details).name;
    if (_getLanguageName(track.lang) != heard) return null;
    if (_followsDub(track)) return null;
    final original = AudioLanguageService.originalOf(widget.details).name;
    return 'No subtitles made for the $heard dub were found. These follow '
        'the $original voices, so the words may differ.';
  }

  /// The list changed (subtitles found, or found by the file's
  /// fingerprint): the subtitle shown retimed against references, if it
  /// couldn't be before for want of them (see _retimeFromReferences).
  void _retimeSelected() {
    final track = _selectedSubtitle;
    if (track != null && !track.isEmbedded) _retimeFromReferences(track);
  }

  Future<void> _applySubtitleTrackToPlayer(SubtitleTrackData? track) async {
    // One subtitle at a time: the subtitle view shows mpv's secondary
    // subtitle under the main one, and with one set the same line showed
    // twice (the video's own English track and the downloaded one).
    try {
      await (player.platform as NativePlayer)
          .setProperty('secondary-sid', 'no');
    } catch (_) {}
    if (track == null || track.url.isEmpty) {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else if (track.isEmbedded) {
      await player.setSubtitleTrack(
        SubtitleTrack(track.url, track.label, track.lang),
      );
    } else if (track.translatedFrom != null) {
      final sinhala = await _sinhalaFor(track);
      if (!mounted || _selectedSubtitle?.id != track.id) return;
      if (sinhala == null) {
        await player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await _showSubtitleFile(sinhala.path, track.lang);
      }
    } else {
      // Its retimed copy, when there is one (see _retimeFromReferences).
      await _showSubtitleFile(
          _retimedPaths[track.id] ?? _driftPaths[track.id] ?? track.url,
          track.lang);
    }
  }

  /// Shows the subtitle file at [url] (a download, or one written here).
  Future<void> _showSubtitleFile(String url, String lang) async {
    // Given to the player before (this video): pick that track again,
    // rather than adding the file another time.
    final added = await _addedSubtitleTracks();
    final id = added.entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (id != null) {
      await player.setSubtitleTrack(
        SubtitleTrack(id, _getLanguageName(lang), lang),
      );
    } else {
      await player.setSubtitleTrack(
        SubtitleTrack.uri(url, title: _getLanguageName(lang), language: lang),
      );
    }
  }

  /// The language [widget.details] was made in, by name ("Malayalam").
  String get _titleLanguage => AudioLanguageService.appliesTo(widget.details)
      ? AudioLanguageService.originalOf(widget.details).name
      : 'English';

  /// Sinhala made from downloaded subtitles, offered when there are some
  /// to make it from and none in Sinhala by people: from English ones
  /// first (the most common, and the most carefully made), else ones in
  /// the title's own language (a Japanese film's Japanese), else another
  /// widely used language, else whatever there is. From the track it's
  /// being made from already, if there's one.
  SubtitleTrackData? _sinhalaTrack() {
    bool inSinhala(SubtitleTrackData s) =>
        _getLanguageName(s.lang) == 'Sinhala';
    if (_externalSubtitles.any(inSinhala) ||
        _embeddedSubtitles.any(inSinhala)) {
      return null;
    }
    final usable = [
      for (final s in _externalSubtitles)
        if (s.url.isNotEmpty) s,
    ];
    if (usable.isEmpty) return null;
    final own = _titleLanguage;
    int rank(SubtitleTrackData s) {
      final name = _getLanguageName(s.lang);
      if (name == 'English') return 0;
      if (name == own) return 1;
      final i = _PlayerScreenState._otherSources.indexOf(name);
      return i < 0 ? 100 : 2 + i;
    }

    // The best ranked, the list's own order (best match first) among equals.
    var best = usable.first;
    for (final s in usable) {
      if (rank(s) < rank(best)) best = s;
    }
    final from = usable.where((s) => s.id == _sinhalaFrom).firstOrNull ?? best;
    return SubtitleTrackData(
      id: 'sinhala:${from.id}',
      url: 'sinhala:${from.id}',
      lang: 'sin',
      label: 'Auto-translated',
      translatedFrom: from,
    );
  }

  /// The text [from] has now: its retimed copy when there is one.
  Future<String> _englishFor(SubtitleTrackData from) async {
    final retimed = _retimedPaths[from.id];
    if (retimed != null) {
      try {
        return await File(retimed).readAsString();
      } catch (_) {}
    }
    return _subtitleText(from);
  }

  /// The Sinhala subtitles for [track], started if they aren't yet. Null
  /// without a Gemini key, or when they can't be made (said so).
  Future<SinhalaSubtitles?> _sinhalaFor(SubtitleTrackData track) {
    final from = track.translatedFrom!;
    final starting = _sinhalaStarting;
    if (_sinhalaFrom == from.id && starting != null) return starting;
    _stopSinhala();
    if (!GeminiKeyService().hasKey) return Future.value(null);
    _updateState(() => _sinhalaFrom = from.id);
    return _sinhalaStarting = () async {
      final url = _streamUrl;
      try {
        final english = await _englishFor(from);
        final episode = _currentSeason != null && _currentEpisode != null
            ? ' (S$_currentSeason E$_currentEpisode)'
            : '';
        final job = await SubtitleTranslator.start(
          english: english,
          title: '${widget.details.title}$episode',
          sourceLanguage: _getLanguageName(from.lang),
          titleLanguage: _titleLanguage,
          from: _currentPosition.inMilliseconds / 1000,
        );
        if (!mounted || _streamUrl != url || _sinhalaFrom != from.id) {
          job.stop();
          return null;
        }
        _updateState(() => _sinhala = job);
        job.updates.addListener(_onSinhalaUpdate);
        job.waitingForScene.addListener(_onSinhalaSceneChanged);
        job.problem.addListener(_onSinhalaProblem);
        // Retimed against references if it can be: the Sinhala follows.
        _retimeFromReferences(from);
        return job;
      } catch (e) {
        print('[sinhala] $e');
        if (mounted) {
          showAppMessage(
            context,
            e is TranslationStopped
                ? e.message
                : "Couldn't make Sinhala subtitles for this.",
            error: true,
          );
        }
        if (mounted && _streamUrl == url && _sinhalaFrom == from.id) {
          _updateState(() {
            _sinhalaStarting = null;
            _sinhalaFrom = null;
          });
        }
        return null;
      }
    }();
  }

  /// How much the subtitles' size is scaled: media_kit's own measure (the
  /// screen's area against a 1920 x 1080 one), but never under 55% — on a
  /// phone on its side that came to 42%, the lines small to read. With the
  /// size raised to 38 from 32: about 21 on a phone (13.5 before), 30 on a
  /// laptop (25.6), 38 on a big screen (32).
  ///
  /// On a TV, 40% bigger: it's watched from across the room, and the same
  /// share of the screen as a laptop's (about 3.5% of its height a line)
  /// read small from the sofa. About 5% of it, as TV apps' subtitles.
  TextScaler _subtitleScaler(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final area = size.width * size.height / (1920 * 1080);
    final scale = math.max(0.55, math.sqrt(area.clamp(0.0, 1.0)));
    return TextScaler.linear(TvDevice.isTv ? scale * 1.4 : scale);
  }

  /// The Sinhala row's "Add key": the Gemini key's steps and paste box
  /// (GeminiKeyForm) over the film, paused meanwhile. Saved, Sinhala
  /// subtitles start at once, and the film carries on.
  Future<void> _addGeminiKey() async {
    final wasPlaying = _isPlaying;
    if (wasPlaying) await player.pause();
    if (!mounted) return;
    await showGeminiKeyDialog(context, title: 'Sinhala subtitles');
    if (!mounted) return;
    if (GeminiKeyService().hasKey) {
      final sinhala = _sinhalaTrack();
      if (sinhala != null) await _selectSubtitle(sinhala);
    }
    if (wasPlaying && mounted) await player.play();
  }

  void _stopSinhala() {
    final job = _sinhala;
    if (job != null) {
      job.updates.removeListener(_onSinhalaUpdate);
      job.waitingForScene.removeListener(_onSinhalaSceneChanged);
      job.problem.removeListener(_onSinhalaProblem);
      job.stop();
      File(job.path).delete().ignore();
    }
    _sinhala = null;
    _sinhalaFrom = null;
    _sinhalaStarting = null;
  }

  Future<void> _applySubtitleTimingToMpv() async {
    final mpv = player.platform as NativePlayer;
    await mpv.setProperty(
        'sub-delay', _subtitleDelaySeconds.toStringAsFixed(2));
    await mpv.setProperty('sub-speed', _subtitleSpeed.toStringAsFixed(6));
  }

  /// [_autoSyncRecheck], for the video playing: a sixth of it, between 4
  /// and 8 minutes — a 22-minute episode was checked only twice after its
  /// first sync.
  Duration get _autoSyncRecheckEvery {
    if (_duration <= Duration.zero) return _PlayerScreenState._autoSyncRecheck;
    final sixth = _duration ~/ 6;
    if (sixth < const Duration(minutes: 4)) return const Duration(minutes: 4);
    return sixth > _PlayerScreenState._autoSyncRecheck ? _PlayerScreenState._autoSyncRecheck : sixth;
  }

  /// Whether subtitles whose lines are [cues] can be this video's at all,
  /// by their length: their last line well past the end, or their lines
  /// stopping before halfway, they're another film's or episode's. (Some
  /// leeway: subtitles for a 25 fps copy run 4% long.)
  bool _fitsLength(List<SubtitleCue> cues) {
    if (_duration <= Duration.zero) return true;
    final length = _duration.inMilliseconds / 1000;
    final last = cues.fold<double>(0, (m, c) => c.end > m ? c.end : m);
    return cues.isNotEmpty && last <= length * 1.08 + 60 && last >= length * 0.5;
  }

  /// Where [track]'s lines are kept (see _cuesOf): its retimed copy's,
  /// once retimed (see _retimeFromReferences), as that's what's shown.
  String _cueKey(SubtitleTrackData track) =>
      _retimedPaths[(track.translatedFrom ?? track).id] ?? track.url;

  /// [track]'s lines (when each is on screen) as shown — retimed, if it is
  /// — downloaded and read once; a download under way is shared.
  Future<List<SubtitleCue>> _cuesOf(SubtitleTrackData track) {
    final key = _cueKey(track);
    final done = _subtitleCues[key];
    if (done != null) return Future.value(done);
    return _cuesLoading[key] ??= () async {
      try {
        final text = track.translatedFrom != null
            ? await _subtitleText(track)
            : await _englishFor(track);
        // Off the screen's thread: a dozen files read at once held it up
        // (and the video with it) on a TV.
        final cues = await _parseCuesInBackground(text);
        _subtitleCues[key] = cues;
        _cuesFailed.remove(track.url);
        return cues;
      } catch (_) {
        _cuesFailed.add(track.url);
        rethrow;
      } finally {
        _cuesLoading.remove(key);
      }
    }();
  }

  /// The viewer pressed the subtitles' sync button: they look out of time.
  /// What was decided about them is forgotten — made for the file or
  /// retimed, they're doubted too — and they, with the language's other
  /// copies, are tested afresh against the sound heard so far: often an
  /// answer in a moment (a better copy switched to, or theirs moved);
  /// otherwise listening goes on as at the start. They stay on screen
  /// meanwhile.
  Future<void> _resyncSubtitles() async {
    final track = _selectedSubtitle;
    if (track == null || track.isEmbedded || _resyncing != null) return;
    final source = track.translatedFrom ?? track;
    print('[sync] the viewer asked to sync ${track.lang} (${track.id}) again');
    final kept = _isTimed(track)
        ? (delay: _subtitleDelaySeconds, speed: _subtitleSpeed)
        : null;
    _updateState(() {
      _resyncing = track.id;
      _resyncKept = kept;
      _distrusted
        ..add(source.id)
        ..add(track.id);
      _autoSynced.remove(track.id);
      _autoSyncTries.remove(track.id);
      // Every copy heard afresh, against every stretch kept.
      _autoSyncSeen.clear();
      _testedOn.clear();
      _noFitLanguage = null;
      _nextListenAt = Duration.zero;
    });
    await _testCopies();
  }

  /// A sync the viewer asked for found nothing clearer — in a fight, or
  /// music, stretches can disagree — for subtitles that were in time
  /// before: they stay as they were, rather than being taken away.
  void _keepTimingAfterResync(SubtitleTrackData track) {
    final kept = _resyncKept;
    _resyncing = null;
    _resyncKept = null;
    if (kept == null) return;
    final source = track.translatedFrom ?? track;
    _distrusted
      ..remove(source.id)
      ..remove(track.id);
    if (!_isTimed(track)) {
      _autoSynced.add(track.id);
      _subtitleTimings[track.id] = kept;
    }
    _autoSyncTries[track.id] =
        (tries: 0, next: _currentPosition + _autoSyncRecheckEvery);
    print('[sync] nothing clearer found; the timing it had is kept');
  }

  /// The copies tested against each listen while [selected] isn't timed:
  /// the best few in its language (the app swaps to whichever fits) — and
  /// the best English and original-language ones, whose timing, once
  /// confirmed, the language's can borrow (see _retimeFromReferences).
  /// Sinhala made from English: itself (its lines are the English's).
  List<SubtitleTrackData> _copiesToTest(SubtitleTrackData selected) {
    if (selected.isEmbedded) return const [];
    if (selected.translatedFrom != null) return [selected];
    final language = _getLanguageName(selected.lang);
    // (Ones timed already — made for the file, retimed — need no listening;
    // one timed by listening is checked again on its own.)
    bool usable(SubtitleTrackData s) =>
        s.url.isNotEmpty &&
        !_rejectedSubtitles.contains(s.id) &&
        _kindOf(s) != SubtitleKind.signsOnly &&
        !_isTimed(s);
    final position = {
      for (var i = 0; i < _externalSubtitles.length; i++)
        _externalSubtitles[i].id: i,
    };
    final own = [
      for (final s in _externalSubtitles)
        if (usable(s) && _getLanguageName(s.lang) == language) s,
    ]..sort((a, b) {
        final byRank = _copyRank(a).compareTo(_copyRank(b));
        return byRank != 0 ? byRank : position[a.id]!.compareTo(position[b.id]!);
      });
    final copies = own.take(_PlayerScreenState._copiesTested).toList();
    if (!copies.any((s) => s.id == selected.id) && usable(selected)) {
      copies.add(selected);
    }
    for (final other in {'English', _titleLanguage}..remove(language)) {
      final best = _bestSubtitleIn(other);
      if (best != null && !best.isEmbedded && usable(best)) copies.add(best);
    }
    return copies;
  }

  /// Whether a copy of [copies] is yet to be tested against some sound
  /// kept.
  bool _untested(List<SubtitleTrackData> copies) {
    for (final h in _heardStretches) {
      if (h.url != _streamUrl) continue;
      for (final c in copies) {
        if (!_testedOn.contains('${c.id}@${h.start}')) return true;
      }
    }
    return false;
  }

  /// The subtitles' timing, checked by listening while the video plays: a
  /// second, silent player decodes a stretch of the sound already
  /// downloaded (watched, or buffered ahead) — the one with the most
  /// dialogue — and every copy in the language is tested against it (see
  /// _testCopies). A copy is timed once two separate stretches agree; the
  /// app switches to it. Never given up: while nothing fits, it listens on
  /// through the film (less often once the panel says so), and once timed
  /// it checks again now and then (a copy can drift). Not for subtitles
  /// built into the file or made for it, which are in time already.
  void _maybeAutoSync(Duration pos) {
    _noteWatched(pos);
    final track = _selectedSubtitle;
    if (track == null ||
        track.isEmbedded ||
        _autoSyncing ||
        _testingCopies ||
        _isMediaOpening ||
        _switchingQuality ||
        _duration <= Duration.zero) {
      return;
    }
    final source = track.translatedFrom ?? track;
    if (!_distrusted.contains(source.id) &&
        (_referenceTimed.contains(source.id) ||
            (source.matchesFile && !_subtitleSourceConflicts(source)))) {
      return;
    }
    // Not more than every couple of seconds: picking a stretch reads every
    // line, and a failed download isn't asked for again at once.
    final now = DateTime.now();
    if (now.isBefore(_nextSyncLook)) return;
    _nextSyncLook = now.add(const Duration(seconds: 2));
    final timed = _autoSynced.contains(track.id);
    // Sound already heard: the copies (a language just picked) against it,
    // at once.
    if (!timed &&
        _heardStretches.any((h) => h.url == _streamUrl) &&
        _untested(_copiesToTest(track))) {
      unawaited(_testCopies());
      return;
    }
    if (!_isPlaying || _isBuffering) return;
    if (timed) {
      final tried = _autoSyncTries[track.id];
      if (tried != null && pos < tried.next) return;
    } else if (pos < _nextListenAt) {
      return;
    }
    // Where the talking is, by this copy's lines — or, it not downloading,
    // another's (or none: then the first free stretch), so the language's
    // other copies are still tested.
    final own = _subtitleCues[_cueKey(track)];
    if (own == null && !_cuesFailed.contains(track.url)) {
      unawaited(_cuesOf(track).then((_) {}, onError: (Object e) {
        print('[sync] subtitles not downloaded: $e');
      }));
      return;
    }
    final cues = own ??
        _copiesToTest(track)
            .map((c) => _subtitleCues[_cueKey(c)])
            .nonNulls
            .firstOrNull ??
        const <SubtitleCue>[];
    final stretch = SubtitleSync.bestStretch(
      cues: cues,
      available: _downloadedRanges(pos),
      length: _PlayerScreenState._listenLength.inMilliseconds / 1000,
      heard: _listened,
    );
    if (stretch == null) return;
    _autoSync(track, from: stretch.start, to: stretch.end);
  }

  /// Whether the sound being heard has a centre channel (5.1, 7.1): where
  /// films put the dialogue, listened to alone (see SubtitleSync.
  /// decodeSound). Asked of the player once per copy.
  Future<bool> _soundHasCentre() async {
    final url = _streamUrl;
    final known = _centreKnown;
    if (known != null && known.url == url) return known.centre;
    var centre = false;
    try {
      final raw =
          await (player.platform as NativePlayer).getProperty('track-list');
      final list = jsonDecode(raw);
      if (list is List) {
        for (final t in list) {
          if (t is Map && t['type'] == 'audio' && t['selected'] == true) {
            final n = t['demux-channel-count'];
            final layout = '${t['demux-channels'] ?? ''}';
            centre = (n is num && n >= 6) ||
                layout.contains('5.1') ||
                layout.contains('7.1');
          }
        }
      }
    } catch (_) {}
    _centreKnown = (url: url, centre: centre);
    return centre;
  }

  /// Watching moved on to [pos]: the stretch being watched grows, or (a
  /// jump) a new one starts.
  void _noteWatched(Duration pos) {
    final step = pos - _autoSyncLastPos;
    final was = _autoSyncLastPos;
    _autoSyncLastPos = pos;
    // A jump: the waits till the next listen (by position in the video)
    // carry on from the new spot — going back doesn't stop listening.
    if (step < Duration.zero || step > const Duration(seconds: 3)) {
      Duration moved(Duration next) =>
          pos + (next > was ? next - was : Duration.zero);
      _nextListenAt = moved(_nextListenAt);
      _autoSyncTries.updateAll(
          (_, t) => (tries: t.tries, next: moved(t.next)));
    }
    final at = pos.inMilliseconds / 1000;
    final last = _watchedRanges.lastOrNull;
    if (last != null &&
        step >= Duration.zero &&
        step <= const Duration(seconds: 3) &&
        at >= last.end - 0.5) {
      _watchedRanges.last = (start: last.start, end: at);
    } else if (last == null || at != last.end) {
      _watchedRanges.add((start: at, end: at));
    }
  }

  /// The video downloaded here, in seconds: what's been watched, and what
  /// the player has buffered ahead of [pos] — listening there never waits
  /// for the download, nor competes with playback for it.
  List<({double start, double end})> _downloadedRanges(Duration pos) {
    final at = pos.inMilliseconds / 1000;
    final ahead = player.state.buffer.inMilliseconds / 1000;
    final ranges = [
      ..._watchedRanges,
      if (ahead > at) (start: at, end: ahead),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <({double start, double end})>[];
    for (final r in ranges) {
      final last = merged.lastOrNull;
      if (last != null && r.start <= last.end + 1) {
        if (r.end > last.end) merged.last = (start: last.start, end: r.end);
      } else {
        merged.add(r);
      }
    }
    return merged;
  }

  /// Listens to the sound from [from] to [to] seconds (a second, silent
  /// player: SubtitleSync.decodeSound) — kept, and every copy tested
  /// against it (_testCopies); or, [track] being timed already, checked
  /// against it again, and moved if two separate stretches agree on
  /// another timing.
  Future<void> _autoSync(
    SubtitleTrackData track, {
    required double from,
    required double to,
  }) async {
    final url = _streamUrl;
    final checking = !_autoSynced.contains(track.id);
    _autoSyncing = true;
    _listened.add((start: from, end: to));
    // The screen's frames meanwhile: how long the screen's thread (which
    // also shows the video) was held up, logged — a TV's video stuttered
    // while subtitles were synced.
    var frames = 0, late = 0;
    var worst = Duration.zero;
    void onFrames(List<FrameTiming> timings) {
      for (final t in timings) {
        frames++;
        final busy = t.buildDuration;
        if (busy > const Duration(milliseconds: 16)) late++;
        if (busy > worst) worst = busy;
      }
    }
    SchedulerBinding.instance.addTimingsCallback(onFrames);
    // And the video's own dropped frames (what a viewer sees as stutter).
    Future<int> dropped() async {
      try {
        final mpv = player.platform as NativePlayer;
        return int.tryParse(await mpv.getProperty('frame-drop-count')) ?? 0;
      } catch (_) {
        return 0;
      }
    }
    final droppedBefore = await dropped();
    final took = Stopwatch()..start();
    print('[sync] listening: ${from.round()}–${to.round()} s of the video'
        '${await _soundHasCentre() ? ' (centre channel)' : ''}, '
        'for ${track.lang} subtitles (${track.id})'
        '${checking ? '' : ', checking again'}');
    try {
      final audio = player.state.track.audio.id;
      final centre = await _soundHasCentre();
      final pcm = await SubtitleSync.decodeSound(
        url,
        start: from,
        end: to,
        audioTrack: audio == 'auto' || audio == 'no' ? null : audio,
        // Stop as soon as the player closes or the video changes.
        isCancelled: () => !mounted || _streamUrl != url,
        // Gently on a TV or a slow phone, where it made the video stutter.
        gentle: TvDevice.isTv || VisualEffectsService().isSlowDevice,
        centreOnly: centre,
      );
      if (!mounted || _streamUrl != url) return;
      if (pcm == null || pcm.length < 60 * SubtitleSync.sampleRate) {
        print("[sync] couldn't get the sound "
            '(${took.elapsedMilliseconds} ms)');
        return;
      }
      final end = from + pcm.length / SubtitleSync.sampleRate;
      print('[sync] heard ${from.round()}–${end.round()} s '
          '(${took.elapsedMilliseconds} ms)');
      _heardStretches.add((url: url, start: from, end: end, pcm: pcm));
      if (_heardStretches.length > _PlayerScreenState._stretchesKept) {
        _heardStretches.removeAt(0);
      }
      if (!checking) await _recheckTiming(track, url, from, end, pcm);
    } catch (e) {
      print('[sync] failed: $e');
    } finally {
      _autoSyncing = false;
      if (mounted && _streamUrl == url) {
        if (checking) {
          _nextListenAt = _currentPosition +
              (_subtitleTiming == _SubtitleTiming.noFit
                  ? _PlayerScreenState._noFitGap
                  : _PlayerScreenState._listenGap);
        } else {
          _autoSyncTries[track.id] =
              (tries: 0, next: _currentPosition + _autoSyncRecheckEvery);
        }
      }
    }
    if (checking && mounted && _streamUrl == url) await _testCopies();
    SchedulerBinding.instance.removeTimingsCallback(onFrames);
    final droppedNow = mounted ? await dropped() - droppedBefore : 0;
    print('[frames] while listening: $frames frames, $late over 16 ms, '
        'the longest ${worst.inMilliseconds} ms; '
        '$droppedNow video frames dropped');
  }

  /// [track], timed already, against another stretch of the sound: moved
  /// only when two separate stretches agree on a timing [_autoSyncMinChange]
  /// or more from the one it has.
  Future<void> _recheckTiming(SubtitleTrackData track, String url,
      double start, double end, Int16List pcm) async {
    final cues = await _cuesOf(track);
    final result = (await _findTimingsInBackground(pcm, start, [cues])).single;
    _testedOn.add('${track.id}@$start');
    print('[sync] ${track.lang} again ${start.round()}–${end.round()} s: '
        '$result');
    if (result == null || !mounted || _streamUrl != url) return;
    if (await _followDrift(track, result, (start + end) / 2)) return;
    final evidence =
        _autoSyncSeen.putIfAbsent(track.id, SubtitleTimingEvidence.new);
    if (!evidence.confirms(result, start, end)) return;
    final delay = (result.delay * 100).round() / 100;
    final selected = _selectedSubtitle?.id == track.id;
    final now = selected
        ? (delay: _subtitleDelaySeconds, speed: _subtitleSpeed)
        : _subtitleTimings[track.id];
    if (now != null &&
        (now.delay - delay).abs() < _PlayerScreenState._autoSyncMinChange &&
        (now.speed - result.speed).abs() < 0.001) {
      print('[sync] still in time');
      return;
    }
    print('[sync] moved: ${result.delay.toStringAsFixed(2)} s, '
        'speed ${result.speed.toStringAsFixed(4)}');
    await _applyConfirmedTiming(track, (delay: delay, speed: result.speed),
        at: (start + end) / 2);
  }

  /// A clear answer for [track] (timed already) at [at] seconds of the
  /// video, a little off from its timing there: the subtitles drift from
  /// this copy (made for a slightly different cut — Street Fighter's DONNY
  /// subtitle was 42.3 s early at 52 min, 47.1 s at 57 min), so they're
  /// retimed piece by piece (SubtitleRetime) to the delays found along
  /// the way, rather than one delay for the whole film. Only for a strong
  /// answer within [_driftReach] of the timing there; a bigger jump needs
  /// two stretches agreeing, as before. Whether it was taken.
  Future<bool> _followDrift(
      SubtitleTrackData track, SubtitleSyncResult result, double at) async {
    final points = _driftPoints[track.id];
    // Its overall timing (while drifting, the file carries the timing and
    // the player none: see below).
    final timing =
        _subtitleTimings['drift:${track.id}'] ?? _subtitleTimings[track.id];
    if (points == null || points.isEmpty || timing == null) return false;
    // Not for Sinhala (made from English as it comes), nor one retimed
    // against references already.
    if (track.translatedFrom != null || _retimedPaths.containsKey(track.id)) {
      return false;
    }
    final strong = result.score >= 0.15 && result.margin >= 0.05;
    if (!strong || (result.speed - timing.speed).abs() > 0.001) return false;
    var here = points.first;
    for (final p in points) {
      if ((p.at - at).abs() < (here.at - at).abs()) here = p;
    }
    final off = (result.delay - here.delay).abs();
    if (off > _PlayerScreenState._driftReach) return false;
    points
      ..add((at: at, delay: (result.delay * 100).round() / 100))
      ..sort((a, b) => a.at.compareTo(b.at));
    if (points.length > 40) points.removeAt(0);
    if (off < _PlayerScreenState._autoSyncMinChange) {
      print('[sync] still in time here');
      return true;
    }
    final delays = points.map((p) => p.delay);
    final spread = delays.reduce(math.max) - delays.reduce(math.min);
    if (spread < _PlayerScreenState._autoSyncMinChange) return true;
    print('[sync] drifting: ${result.delay.toStringAsFixed(2)} s at '
        '${(at / 60).toStringAsFixed(1)} min (was ${here.delay} s there); '
        'retimed piece by piece');
    final url = _streamUrl;
    try {
      final text = await _subtitleText(track);
      final map = TimingMap(timing.speed, [
        for (final p in points) (at: p.at, delay: p.delay),
      ]);
      final retimed = SubtitleRetime.retime(text, map);
      final ext = text.contains('[Events]')
          ? 'ass'
          : text.trimLeft().startsWith('WEBVTT')
              ? 'vtt'
              : 'srt';
      final temp = await getTemporaryDirectory();
      final file = File('${temp.path}${Platform.pathSeparator}'
          'popcorn_drift_${track.id}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await file.writeAsString(retimed);
      if (!mounted || _streamUrl != url) {
        await file.delete();
        return true;
      }
      final old = _driftPaths[track.id];
      _driftPaths[track.id] = file.path;
      if (old != null) File(old).delete().ignore();
      if (_selectedSubtitle?.id == track.id) {
        _updateState(() {
          _subtitleDelaySeconds = 0;
          _subtitleSpeed = 1;
        });
        await _applySubtitleTimingToMpv();
        await _applySubtitleTrackToPlayer(track);
      }
      // The file carries the timing now; [timing] stays as its overall one
      // (kept for next time, and for going back to it).
      _subtitleTimings[track.id] = (delay: 0.0, speed: 1.0);
      _subtitleTimings['drift:${track.id}'] = timing;
    } catch (e) {
      print('[sync] retiming for drift failed: $e');
    }
    return true;
  }

  /// Series: where [s]'s timing carries over between episodes — the show,
  /// the video's release (group and kind of source) and the subtitle's.
  /// Null when either release is too vague to tell.
  String? _seriesTimingKey(SubtitleTrackData s) {
    if (widget.details.type != 'tv') return null;
    final videoName = _currentStream.title.split('\n').first;
    final videoGroup = _releaseGroupOf(videoName);
    final subGroup =
        s.releaseGroup?.toLowerCase() ?? _releaseGroupOf(s.releaseName ?? '');
    if (videoGroup == null || subGroup == null) return null;
    return '${widget.details.id}|$videoGroup|'
        '${SubtitleService.sourceOf(videoName)}|$subGroup|'
        '${SubtitleService.sourceOf(s.releaseName ?? '')}';
  }

  static final _releaseGroupPattern = RegExp(
      r'-([A-Za-z0-9]+)(?:\[[^\]]*\])?(?:\.(?:mkv|mp4|avi|srt|ass))?\s*$');

  /// The release group at the end of a release name ("…H264-NTb" → "ntb").
  static String? _releaseGroupOf(String name) => _releaseGroupPattern
      .firstMatch(name.trim())
      ?.group(1)
      ?.toLowerCase();

  static const _seriesTimingsKey = 'subtitle_series_timings';

  /// The series timings (see _seriesTimingKey), read once.
  Future<void> _loadSeriesTimings() async {
    if (_seriesTimings != null) return;
    final prefs = await SharedPreferences.getInstance();
    final found = <String, ({double delay, double speed})>{};
    try {
      final raw = jsonDecode(prefs.getString(_seriesTimingsKey) ?? '{}');
      if (raw is Map) {
        for (final e in raw.entries) {
          final v = e.value;
          if (v is Map && v['d'] is num && v['s'] is num) {
            found['${e.key}'] = (
              delay: (v['d'] as num).toDouble(),
              speed: (v['s'] as num).toDouble(),
            );
          }
        }
      }
    } catch (_) {}
    _seriesTimings = found;
  }

  /// [s]'s timing confirmed: kept for the series' next episodes.
  Future<void> _rememberSeriesTiming(
      SubtitleTrackData s, ({double delay, double speed}) timing) async {
    final key = _seriesTimingKey(s);
    if (key == null) return;
    (_seriesTimings ??= {})[key] = timing;
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> stored;
    try {
      stored = Map<String, dynamic>.from(
          jsonDecode(prefs.getString(_seriesTimingsKey) ?? '{}') as Map);
    } catch (_) {
      stored = {};
    }
    stored[key] = {
      'd': timing.delay,
      's': timing.speed,
      't': DateTime.now().millisecondsSinceEpoch,
    };
    // The 200 latest.
    if (stored.length > 200) {
      final byAge = stored.entries.toList()
        ..sort((a, b) => ((a.value as Map)['t'] as num? ?? 0)
            .compareTo((b.value as Map)['t'] as num? ?? 0));
      for (final e in byAge.take(stored.length - 200)) {
        stored.remove(e.key);
      }
    }
    await prefs.setString(_seriesTimingsKey, jsonEncode(stored));
  }

  /// What listening's found for [c] so far — on a series, starting from
  /// the timing its releases had in an earlier episode (see
  /// _seriesTimingKey), so one listen agreeing confirms it.
  SubtitleTimingEvidence _evidenceFor(SubtitleTrackData c) {
    final evidence = SubtitleTimingEvidence();
    final key = _seriesTimingKey(c);
    final known = key == null ? null : _seriesTimings?[key];
    if (known != null) {
      evidence.seed(known.delay, known.speed);
      print('[sync] ${c.id}: starting from the earlier episode\'s timing '
          '(${known.delay} s)');
    }
    return evidence;
  }

  /// [track]'s timing confirmed: kept (for this copy, next time too), and
  /// put on screen if it's the one shown.
  Future<void> _applyConfirmedTiming(
      SubtitleTrackData track, ({double delay, double speed}) timing,
      {double? at}) async {
    _autoSynced.add(track.id);
    _subtitleTimings[track.id] = timing;
    _subtitleTimings.remove('drift:${track.id}');
    // One timing for the film again: points along it start afresh.
    _driftPoints[track.id] = [
      if (at != null) (at: at, delay: timing.delay),
    ];
    final drifted = _driftPaths.remove(track.id);
    if (drifted != null) File(drifted).delete().ignore();
    unawaited(_rememberSeriesTiming(track, timing));
    _autoSyncTries[track.id] =
        (tries: 0, next: _currentPosition + _autoSyncRecheckEvery);
    // (Not for one shown retimed: the timing's on top of its retimed copy,
    // which next time may not be.)
    if (!_retimedPaths.containsKey((track.translatedFrom ?? track).id)) {
      unawaited(_rememberTiming(track, timing: timing));
    }
    if (_selectedSubtitle?.id == track.id) {
      _updateState(() {
        _subtitleDelaySeconds = timing.delay;
        _subtitleSpeed = timing.speed;
      });
      await _applySubtitleTimingToMpv();
      if (drifted != null) await _applySubtitleTrackToPlayer(track);
    }
  }

  /// Every copy to test (_copiesToTest) against every stretch of sound kept
  /// it hasn't been yet: a fraction of a second each, off the screen's
  /// thread. Copies whose length rules them out are left out for good. A
  /// copy two separate stretches agree on is timed — and switched to, if
  /// it's in the language being watched; another language's lends its
  /// timing (see _retimeFromReferences). After [_noFitAfter] stretches with
  /// none of the language's fitting, the panel says so.
  Future<void> _testCopies() async {
    final track = _selectedSubtitle;
    if (_testingCopies || track == null || _isTimed(track)) return;
    final url = _streamUrl;
    final copies = _copiesToTest(track);
    if (copies.isEmpty) return;
    _testingCopies = true;
    final confirmed = <SubtitleTrackData>[];
    var rejected = false;
    try {
      final cues = <String, List<SubtitleCue>>{};
      await Future.wait(copies.map((c) async {
        try {
          cues[c.id] = await _cuesOf(c);
        } catch (e) {
          print('[sync] ${c.id} not downloaded: $e');
        }
      }));
      if (!mounted || _streamUrl != url) return;
      for (final c in copies) {
        final lines = cues[c.id];
        if (lines == null || c.translatedFrom != null || _fitsLength(lines)) {
          continue;
        }
        final last = lines.fold<double>(0, (m, l) => l.end > m ? l.end : m);
        print("[subtitles] ${c.id} doesn't fit: last line at ${last.round()} "
            's, video ${_duration.inSeconds} s long');
        _rejectedSubtitles.add(c.id);
        cues.remove(c.id);
        rejected = true;
      }
      for (final h in [..._heardStretches]) {
        if (h.url != url) continue;
        final batch = [
          for (final c in copies)
            if (!_testedOn.contains('${c.id}@${h.start}')) c,
        ];
        // Not downloadable, or ruled out: not tried again on this sound.
        for (final c in batch) {
          if (cues[c.id] == null) _testedOn.add('${c.id}@${h.start}');
        }
        batch.removeWhere((c) => cues[c.id] == null);
        if (batch.isEmpty) continue;
        final took = Stopwatch()..start();
        final List<SubtitleSyncResult?> results;
        try {
          results = await _findTimingsInBackground(
              h.pcm, h.start, [for (final c in batch) cues[c.id]!]);
        } catch (e) {
          // Not tried again on this sound (it would fail again).
          print('[sync] testing failed: $e');
          for (final c in batch) {
            _testedOn.add('${c.id}@${h.start}');
          }
          continue;
        }
        if (!mounted || _streamUrl != url) return;
        print('[sync] ${batch.length} subtitles against '
            '${h.start.round()}–${h.end.round()} s '
            '(${took.elapsedMilliseconds} ms):');
        for (var i = 0; i < batch.length; i++) {
          final c = batch[i];
          final r = results[i];
          _testedOn.add('${c.id}@${h.start}');
          print('[sync]   ${c.lang} ${c.id}: $r');
          if (r == null || _autoSynced.contains(c.id)) continue;
          final evidence = _autoSyncSeen.putIfAbsent(c.id, () => _evidenceFor(c));
          if (!evidence.confirms(r, h.start, h.end)) continue;
          print('[sync] ${c.lang} ${c.id} timed: two stretches agree on '
              '${r.delay.toStringAsFixed(2)} s');
          await _applyConfirmedTiming(
              c, (delay: (r.delay * 100).round() / 100, speed: r.speed),
              at: (h.start + h.end) / 2);
          confirmed.add(c);
          if (!mounted || _streamUrl != url) return;
        }
      }
    } catch (e) {
      print('[sync] testing failed: $e');
    } finally {
      _testingCopies = false;
    }
    if (!mounted || _streamUrl != url) return;
    final language = _getLanguageName(track.lang);
    if (confirmed.isNotEmpty || rejected) {
      // A timed copy of the language now comes first: switched to. One of
      // another language: the language's retimed against it.
      if (confirmed.isNotEmpty) _noFitLanguage = null;
      await _rebuildAvailableSubtitles();
      _retimeSelected();
    }
    final shown = _selectedSubtitle;
    if (shown != null &&
        !_isTimed(shown) &&
        _resyncing != shown.id &&
        _getLanguageName(shown.lang) == language &&
        _noFitLanguage != language) {
      // Every copy of the language tested against enough separate
      // stretches (or ruled out by its length), and none fits: said so
      // (listening goes on).
      final own = [
        for (final c in _copiesToTest(shown))
          if (_getLanguageName(c.lang) == language) c,
      ];
      final heardEnough = own.isEmpty ||
          own.every((c) =>
              _testedOn.where((k) => k.startsWith('${c.id}@')).length >=
              _PlayerScreenState._noFitAfter);
      if (heardEnough) {
        print('[sync] none of the $language subtitles fit so far; '
            'listening on');
        _noFitLanguage = language;
      }
    }
    // A sync the viewer asked for: done once the subtitles shown are timed
    // (theirs, or another copy switched to) — or, every copy heard enough
    // and none fitting, the panel says so.
    final asked = _resyncing;
    if (asked != null && shown != null && shown.id == asked && !_isTimed(shown)) {
      final own = [
        for (final c in _copiesToTest(shown))
          if (_getLanguageName(c.lang) == language) c,
      ];
      if (own.isEmpty ||
          own.every((c) =>
              _testedOn.where((k) => k.startsWith('${c.id}@')).length >=
              _PlayerScreenState._noFitAfter)) {
        if (_resyncKept != null) {
          _keepTimingAfterResync(shown);
        } else {
          print('[sync] none of the $language subtitles fit so far');
          _resyncing = null;
          _noFitLanguage = language;
        }
      }
    } else if (asked != null) {
      _resyncing = null;
      _resyncKept = null;
    }
    if (mounted) _updateState(() {});
  }

  /// [track]'s text (an SRT, VTT or ASS file), downloaded once.
  Future<String> _subtitleText(SubtitleTrackData track) async {
    // Sinhala made from English: the English's lines, at the same times.
    if (track.translatedFrom != null) return _englishFor(track.translatedFrom!);
    final cached = _subtitleTexts[track.url];
    if (cached != null) return cached;
    final response = await _PlayerScreenState._subtitleDio.get<String>(
      track.url,
      options: Options(responseType: ResponseType.plain),
    );
    return _subtitleTexts[track.url] = response.data ?? '';
  }

  /// [track] retimed against reference subtitles, in any language — what's
  /// compared is when lines are on screen — piece by piece along the video
  /// (SubtitleRetime). One known to fit this very copy is enough on its
  /// own: made for this file, or timed by listening (two stretches agreed;
  /// its timing applied first). Otherwise two made for a copy like this
  /// one (its kind of source: Blu-ray, web, TV), from different release
  /// groups, have to agree. Instant beside listening, which needs minutes
  /// of sound — and right where a subtitle drifts from the copy: Ghosts
  /// S1E8's web-rip English one is 2.6 s off its Blu-ray copy at the start
  /// and 5.6 s by the end, in steps at the ad breaks, which no one delay
  /// fits. Tried again whenever the references change (a subtitle made for
  /// the file found late, another timed by listening); meanwhile listening
  /// goes on.
  Future<void> _retimeFromReferences(SubtitleTrackData track) async {
    if (!mounted || _closing) return;
    // Sinhala made from English: the English is retimed, and the Sinhala
    // follows it (see below).
    if (track.translatedFrom != null) {
      return _retimeFromReferences(track.translatedFrom!);
    }
    // (Timed by listening: kept — its own sound's say beats another
    // subtitle's.)
    if (track.isEmbedded ||
        _retimedPaths.containsKey(track.id) ||
        _referenceTimed.contains(track.id) ||
        _autoSynced.contains(track.id) ||
        (track.matchesFile && !_subtitleSourceConflicts(track))) {
      return;
    }
    final stream = _currentStream;
    final video = '${stream.title}\n${stream.name}';
    bool usable(SubtitleTrackData s) =>
        s.id != track.id &&
        s.url.isNotEmpty &&
        !_rejectedSubtitles.contains(s.id) &&
        _kindOf(s) != SubtitleKind.signsOnly;
    // Known to fit this copy: made for the file, or timed by listening.
    final fitting = [
      for (final s in _externalSubtitles)
        if (usable(s) &&
            ((s.matchesFile && !_subtitleSourceConflicts(s)) ||
                (_autoSynced.contains(s.id) &&
                    _subtitleTimings[s.id] != null)))
          s,
    ];
    // Made for a copy like it: two that agree. (Not for one made for this
    // release, as in time as they are.)
    final alike = SubtitleService.sourceOf(video) == null ||
            SubtitleService.likeness(track, video) >= 4
        ? <SubtitleTrackData>[]
        : ([
            for (final s in _externalSubtitles)
              if (usable(s) &&
                  !fitting.contains(s) &&
                  SubtitleService.likeness(s, video) >= 2)
                s,
          ]..sort((a, b) => SubtitleService.likeness(b, video)
              .compareTo(SubtitleService.likeness(a, video))));
    if (fitting.isEmpty && alike.length < 2) return;
    final picked = [...fitting.take(2), ...alike.take(4)];
    // The same references as last time: no use trying again.
    final signature = picked.map((r) => r.id).join(',');
    if (_retimedWith[track.id] == signature) return;
    _retimedWith[track.id] = signature;
    final url = _streamUrl;
    final took = Stopwatch()..start();
    try {
      final text = await _subtitleText(track);
      final refTexts = await Future.wait(picked.map(_subtitleText));
      final map = await _retimeMapInBackground(
        text,
        refTexts,
        [
          for (final r in picked)
            (r.releaseGroup ?? r.releaseName ?? r.id).toLowerCase(),
        ],
        [for (final r in picked) fitting.contains(r)],
        [
          for (final r in picked)
            r.matchesFile ? null : _subtitleTimings[r.id],
        ],
      );
      if (!mounted || _streamUrl != url) return;
      if (map == null) {
        print('[sync] references (${picked.map((r) => r.lang).join(', ')}) '
            "don't line up; listening on");
        return;
      }
      final ext = text.contains('[Events]')
          ? 'ass'
          : text.trimLeft().startsWith('WEBVTT')
              ? 'vtt'
              : 'srt';
      final temp = await getTemporaryDirectory();
      if (!mounted || _streamUrl != url) return;
      final file = File('${temp.path}${Platform.pathSeparator}'
          'popcorn_sub_${track.id}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      final retimed = SubtitleRetime.retime(text, map);
      await file.writeAsString(retimed);
      if (!mounted || _streamUrl != url) {
        await file.delete();
        return;
      }
      _retimedPaths[track.id] = file.path;
      // Sinhala made from it: its lines move with it.
      if (_sinhalaFrom == track.id) await _sinhala?.retime(retimed);
      if (!mounted || _streamUrl != url) return;
      // A timing kept from listening was for the file as it came.
      final key = _timingKey(track);
      unawaited(SubtitleTimingStore().forget(key));
      _autoSynced.remove(track.id);
      print('[sync] retimed by references '
          '(${picked.map((r) => '${r.lang}${fitting.contains(r) ? ', fits' : ''}').join('; ')}) in '
          '${took.elapsedMilliseconds} ms: $map');
      _subtitleTimings[track.id] = (delay: 0.0, speed: 1.0);
      _updateState(() => _referenceTimed.add(track.id));
      final shown = _selectedSubtitle;
      if (shown != null &&
          (shown.id == track.id || shown.translatedFrom?.id == track.id)) {
        _updateState(() {
          _subtitleDelaySeconds = 0;
          _subtitleSpeed = 1;
        });
        await _applySubtitleTimingToMpv();
        await _applySubtitleTrackToPlayer(shown);
      } else {
        // Timed now: the language's pick, if it's the language watched.
        await _rebuildAvailableSubtitles();
      }
    } catch (e) {
      print('[sync] retiming failed: $e');
    }
  }

  /// _retimeMap, off the screen's thread. (Static: nothing of the screen
  /// goes with it.)
  static Future<TimingMap?> _retimeMapInBackground(
    String text,
    List<String> refTexts,
    List<String> groups,
    List<bool> fits,
    List<({double delay, double speed})?> timings,
  ) =>
      Isolate.run(() => _retimeMap(text, refTexts, groups, fits, timings));

  /// [text]'s timing map against the references [refTexts] (each shown at
  /// its [timings], if any): one known to fit this copy ([fits]) alone,
  /// otherwise two from different release [groups] that agree, averaged.
  /// Null if none do.
  static TimingMap? _retimeMap(
    String text,
    List<String> refTexts,
    List<String> groups,
    List<bool> fits,
    List<({double delay, double speed})?> timings,
  ) {
    final cues = SubtitleSync.parseCues(text);
    final maps = [
      for (var i = 0; i < refTexts.length; i++)
        SubtitleRetime.mapAgainst(cues, [
          for (final c in SubtitleSync.parseCues(refTexts[i]))
            if (timings[i] case final t?)
              SubtitleCue(c.start * t.speed + t.delay, c.end * t.speed + t.delay)
            else
              c,
        ]),
    ];
    for (var i = 0; i < maps.length; i++) {
      if (fits[i] && maps[i] != null) return maps[i];
    }
    for (var i = 0; i < maps.length; i++) {
      for (var j = i + 1; j < maps.length; j++) {
        final a = maps[i], b = maps[j];
        if (a == null || b == null || fits[i] || fits[j]) continue;
        if (groups[i] == groups[j]) continue;
        if (a.agreesWith(b)) return a.averagedWith(b);
      }
    }
    return null;
  }

  /// The shown subtitles' timing (see _SubtitleTiming).
  _SubtitleTiming? get _subtitleTiming {
    final track = _selectedSubtitle;
    if (track == null) return null;
    if (_isTimed(track) || _resyncing == track.id) {
      return _SubtitleTiming.ready;
    }
    return _noFitLanguage == _getLanguageName(track.lang)
        ? _SubtitleTiming.noFit
        : _SubtitleTiming.checking;
  }

  /// What the quiet bar in the subtitles' place says (see
  /// _buildSubtitleActivity), or null when there's none: Sinhala being made
  /// for the scene (said in Sinhala), or the timing being checked.
  String? _subtitleActivityLabel(_SubtitleTiming? timing) {
    final source = _selectedSubtitle?.translatedFrom;
    if (timing == _SubtitleTiming.noFit) return null;
    if (source != null && source.id == _sinhalaFrom &&
        (_sinhala?.waitingForScene.value ?? _sinhalaStarting != null)) {
      return 'සිංහල උපසිරැසි සකසමින්…';
    }
    return timing == _SubtitleTiming.checking
        ? 'Syncing subtitles…'
        : null;
  }

  /// The subtitle panel's word on the timing, or null. (While it's being
  /// checked, the subtitles' sync button turns instead.)
  String? get _subtitleSyncNote => switch (_subtitleTiming) {
        _SubtitleTiming.noFit =>
          'None of the ${_getLanguageName(_selectedSubtitle!.lang)} '
              'subtitles found match this video so far. Popcorn keeps '
              'checking.',
        _ => null,
      };

  /// Where [track]'s timing for the copy playing is kept between visits.
  String _timingKey(SubtitleTrackData track) =>
      'subtitle_timing2_${_currentStream.infoHash.toLowerCase()}_${track.id}';

  /// Keeps [track]'s timing ([timing], or the one set now) for the next
  /// time this copy plays with it — using its confirmation marker.
  Future<void> _rememberTiming(
    SubtitleTrackData track, {
    ({double delay, double speed})? timing,
  }) async {
    final t = timing ?? (delay: _subtitleDelaySeconds, speed: _subtitleSpeed);
    await SubtitleTimingStore().remember(_timingKey(track), t);
  }

  /// [track]'s timing kept from an earlier visit (see _rememberTiming).
  Future<({double delay, double speed})?> _savedTiming(
    SubtitleTrackData track,
  ) =>
      SubtitleTimingStore().timingOf(_timingKey(track));

  /// SubtitleSync.parseCues, off the screen's thread. (Static: a closure
  /// made in the screen's methods would carry the screen along, which an
  /// isolate can't be sent.)
  static Future<List<SubtitleCue>> _parseCuesInBackground(String text) =>
      Isolate.run(() => SubtitleSync.parseCues(text));

  /// SubtitleSync.findAll, off the screen's thread: a few hundred
  /// milliseconds' sums on a phone for the sound, a fraction of a second
  /// for each copy. (Static: nothing of the screen goes with it.)
  static Future<List<SubtitleSyncResult?>> _findTimingsInBackground(
    Int16List pcm,
    double start,
    List<List<SubtitleCue>> cueSets,
  ) =>
      Isolate.run(() =>
          SubtitleSync.findAll(pcm, windowStart: start, cueSets: cueSets));

  /// Shows [track] (null = subtitles off). A choice the viewer made
  /// ([remember]) becomes their preference for every video after this
  /// one — see _loadSubtitles.
  Future<void> _selectSubtitle(
    SubtitleTrackData? track, {
    bool remember = true,
  }) async {
    final request = ++_subtitleSelectionRequest;
    if (remember) {
      _userPickedSubtitleForThisVideo = true;
    }
    final old = _selectedSubtitle;
    if (old != null) {
      _subtitleTimings[old.id] =
          (delay: _subtitleDelaySeconds, speed: _subtitleSpeed);
    }
    var timing = track == null ? null : _subtitleTimings[track.id];
    if (track != null && timing == null) {
      final url = _streamUrl;
      // Confirmed when this copy was played before.
      final saved = await _savedTiming(track);
      if (!mounted || _streamUrl != url || request != _subtitleSelectionRequest) return;
      if (saved != null) {
        timing = (delay: saved.delay, speed: saved.speed);
        _autoSynced.add(track.id);
      }
    }
    final retime = (timing?.delay ?? 0.0) != _subtitleDelaySeconds ||
        (timing?.speed ?? 1.0) != _subtitleSpeed;
    if (!mounted) return; // Closed while the saved timing was read.
    _updateState(() {
      if (track?.id != _resyncing) {
        _resyncing = null;
        _resyncKept = null;
      }
      _selectedSubtitle = track;
      _subtitleDelaySeconds = timing?.delay ?? 0.0;
      _subtitleSpeed = timing?.speed ?? 1.0;
    });
    if (retime) await _applySubtitleTimingToMpv();
    if (!mounted) return;
    if (remember) {
      final lang = track?.lang ?? '';
      SharedPreferences.getInstance().then((prefs) async {
        // The same choice again isn't a change to sync.
        if (prefs.getString(_PlayerScreenState._subtitleLangPrefKey) == lang) return;
        SyncLedger().touch('settings', _PlayerScreenState._subtitleLangPrefKey);
        await prefs.setString(_PlayerScreenState._subtitleLangPrefKey, lang);
      });
    }
    await _applySubtitleTrackToPlayer(track);
    if (track != null) _retimeFromReferences(track);
  }
}
