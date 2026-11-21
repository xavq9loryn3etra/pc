part of '../player_screen.dart';

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
    for (final path in _retimedPaths.values) {
      File(path).delete().ignore();
    }
    _retimedPaths.clear();
  }

  /// Before opening another copy of the same video (a quality switch, a
  /// reconnect): the old file's built-in tracks, and one picked from them,
  /// don't belong to the new file — each file's tracks are numbered afresh,
  /// so the old number could be another language there, or nothing. The
  /// viewer's language is kept (saved when they picked it), so the new
  /// file's track in it is picked once its tracks are read; a downloaded
  /// track stays on meanwhile. Called inside setState.
  void _forgetFileSubtitles() {
    _discardRetimedFiles();
    _stopSinhala();
    _subtitleTimings.clear();
    _autoSyncDone.clear();
    _autoSynced.clear();
    _autoSyncTries.clear();
    _heard = null;
    _heardTried.clear();
    _autoSyncSeen.clear();
    _autoSyncFrom.clear();
    _retimeTried.clear();
    _referenceTimed.clear();
    // Another video: subtitles that didn't fit the last may fit this one.
    _rejectedSubtitles.clear();
    _fitChecked.clear();
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

      _externalSubtitles = subs;
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
  /// with it from the start. Looked for a little after the video starts
  /// playing, not before: on a torrent, reading the file's end has the
  /// engine fetch it first, which slowed starting (the subtitle list
  /// waited on it, and the reads ran on after giving up).
  Future<void> _fingerprintSubtitles() async {
    final url = _streamUrl;
    final imdbId = widget.details.imdbId ?? widget.movie.imdbId;
    if (url.isEmpty || imdbId == null || _fingerprinted == url) return;
    _fingerprinted = url;
    await Future<void>.delayed(const Duration(seconds: 15));
    if (!mounted || _streamUrl != url) return;
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
    // Picked again (unless the viewer chose): one made for this file now
    // comes first in its language.
    await _rebuildAvailableSubtitles();
  }

  Future<void> _rebuildAvailableSubtitles() async {
    // After this, whatever stays selected: retimed if it can be now.
    Future<void>.delayed(Duration.zero, _retimeSelected);
    final sinhala = _sinhalaTrack();
    // Each language’s best first, including when trying another track.
    final ordered = [..._embeddedSubtitles, ..._externalSubtitles];
    final position = {for (var i = 0; i < ordered.length; i++) ordered[i].id: i};
    ordered.sort((a, b) {
      final byRank = _subtitleRank(a).compareTo(_subtitleRank(b));
      return byRank != 0 ? byRank : position[a.id]!.compareTo(position[b.id]!);
    });
    final combined = <SubtitleTrackData>[
      if (sinhala != null) sinhala,
      ...ordered,
    ];
    if (mounted) {
      _updateState(() {
        _availableSubtitles = combined;
      });
    }

    // If the viewer hasn't manually picked a track for this video yet,
    // pick the best match for their preferred language — always preferring
    // an embedded MKV track (which is muxed directly with this exact video
    // stream and has zero framerate/cut drift) over an external SRT.
    if (_userPickedSubtitleForThisVideo) {
      // Even if an external track was auto-selected moments before mpv
      // finished parsing the MKV's embedded tracks, upgrade to the embedded
      // track in the same language automatically.
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _userPickedSubtitleForThisVideo) return;
    final preferred = prefs.getString(_PlayerScreenState._subtitleLangPrefKey) ?? 'eng';
    if (preferred.isEmpty) {
      if (_selectedSubtitle != null) {
        await _selectSubtitle(null, remember: false);
      }
      return;
    }

    final targetLangName = _getLanguageName(preferred);
    // Sinhala chosen before and none made by people: made from English,
    // with the viewer's Gemini key.
    final bestMatch = _bestSubtitleIn(targetLangName) ??
        (targetLangName == 'Sinhala' && GeminiKeyService().hasKey
            ? sinhala
            : null);

    if (bestMatch?.id != _selectedSubtitle?.id) {
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
  /// follow the dialogue, then signs-only tracks. Ones found not to fit
  /// (see _tryAnotherSubtitle) last.
  int _subtitleRank(SubtitleTrackData s) {
    if (_rejectedSubtitles.contains(s.id)) return 6;
    final kind = SubtitleService.kindOf(s);
    if (kind == SubtitleKind.signsOnly) return 5;
    if (_subtitleSourceConflicts(s)) return 4;
    final fitsWhatsHeard = _hearingDub ? _followsDub(s) : !_followsDub(s);
    if (fitsWhatsHeard) return s.isEmbedded || s.matchesFile ? 0 : 1;
    return s.isEmbedded || s.matchesFile ? 2 : 3;
  }

  bool _subtitleSourceConflicts(SubtitleTrackData track) =>
      !track.isEmbedded && SubtitleService.likeness(track,
          '${_currentStream.title}\n${_currentStream.name}') < 0;

  SubtitleTrackData? get _anotherSubtitle {
    final selected = _selectedSubtitle;
    if (selected == null) return null;
    final language = _getLanguageName(selected.lang);
    final alternatives = _availableSubtitles.where((track) =>
        track.url.isNotEmpty &&
        !_rejectedSubtitles.contains(track.id) &&
        _getLanguageName(track.lang) == language &&
        (track.translatedFrom == null || GeminiKeyService().hasKey)).toList();
    if (alternatives.isEmpty) return null;
    final current = alternatives.indexWhere((track) => track.id == selected.id);
    final next = alternatives[(current + 1) % alternatives.length];
    return next.id == selected.id ? null : next;
  }

  Future<void> _selectAnotherSubtitle() async {
    final track = _anotherSubtitle;
    if (track == null) return;
    await _selectSubtitle(track);
    if (mounted && !_closing && _selectedSubtitle?.id == track.id) {
      showAppMessage(context, 'Switched subtitle');
    }
  }

  /// Whether [s] follows the title's English dub: English captions, or
  /// made for a dubbed version, of a title not made in English. (Captions
  /// in another language follow something else: the Japanese "[cc]" of an
  /// anime, its Japanese voices.)
  bool _followsDub(SubtitleTrackData s) =>
      AudioLanguageService.appliesTo(widget.details) &&
      SubtitleService.kindOf(s) == SubtitleKind.forDub &&
      _getLanguageName(s.lang) == 'English';

  /// For the subtitle menu: what [s] follows, when its name says and it's
  /// worth telling — the English dub, or the original voices.
  String? _subtitleFollows(SubtitleTrackData s) {
    if (SubtitleService.kindOf(s) != SubtitleKind.forDub) return null;
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
      final byRank = _subtitleRank(a).compareTo(_subtitleRank(b));
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
      await _showSubtitleFile(_retimedPaths[track.id] ?? track.url, track.lang);
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

  /// An external dialogue track may be replaced if its length rules it out.
  bool _canTryAnother(SubtitleTrackData track) =>
      !track.isEmbedded &&
      (!track.matchesFile || _subtitleSourceConflicts(track)) &&
      track.translatedFrom == null &&
      SubtitleService.kindOf(track) != SubtitleKind.signsOnly &&
      _selectedSubtitle?.id == track.id;

  /// Whether [track]'s length fits the video: its last line well past the
  /// end, or its lines stopping before halfway, it's another film's or
  /// episode's. (Some leeway: subtitles for a 25 fps copy run 4% long.)
  Future<void> _checkSubtitleFits(SubtitleTrackData track) async {
    final url = _streamUrl;
    try {
      var cues = _subtitleCues[track.url];
      if (cues == null) {
        cues = SubtitleSync.parseCues(await _subtitleText(track));
        _subtitleCues[track.url] = cues;
      }
      if (!mounted || _streamUrl != url || _duration <= Duration.zero) return;
      final length = _duration.inMilliseconds / 1000;
      final last = cues.fold<double>(0, (m, c) => c.end > m ? c.end : m);
      final fits = cues.isNotEmpty &&
          last <= length * 1.08 + 60 &&
          last >= length * 0.5;
      if (!fits) {
        await _tryAnotherSubtitle(
            track,
            'last line at ${last.round()} s, '
            'video ${length.round()} s long');
      }
    } catch (e) {
      print('[subtitles] length check failed: $e');
    }
  }

  /// [wrong] doesn't fit this video: the next best subtitles in its
  /// language instead, saying so — up to three tried.
  Future<void> _tryAnotherSubtitle(SubtitleTrackData wrong, String why) async {
    if (!mounted || !_canTryAnother(wrong)) return;
    _rejectedSubtitles.add(wrong.id);
    final language = _getLanguageName(wrong.lang);
    final triedHere = _externalSubtitles
        .where((s) =>
            _rejectedSubtitles.contains(s.id) &&
            _getLanguageName(s.lang) == language)
        .length;
    final best = triedHere >= 3 ? null : _bestSubtitleIn(language);
    final next = best == null || best.id == wrong.id ? null : best;
    print("[subtitles] ${wrong.id} doesn't fit ($why): "
        "${next == null ? 'kept, none other to try' : 'trying ${next.id}'}");
    if (next == null) return;
    showAppMessage(context, "Those subtitles didn't match. Trying another…");
    await _selectSubtitle(next, remember: false);
  }

  /// Auto Sync, by itself: a downloaded subtitle's timing is set by when
  /// people talk (see _autoSync) — from the sound already heard of this
  /// video when there is some (another subtitle picked: lined up at once),
  /// otherwise from the next few minutes from where the video began
  /// playing here, soon after it starts; tried again a little later when
  /// that wasn't clear, up to [_autoSyncMaxTries] times, and checked again
  /// now and then once synced. Skipped for subtitles in the video file, which are
  /// made for it.
  void _maybeAutoSync(Duration pos) {
    // Watching carried on from where it last jumped (a seek, a new video).
    final step = pos - _autoSyncLastPos;
    _autoSyncLastPos = pos;
    if (_watchedFrom == null ||
        step < Duration.zero ||
        step > const Duration(seconds: 3)) {
      _watchedFrom = pos;
    }
    final track = _selectedSubtitle;
    if (track == null ||
        track.isEmbedded ||
        _referenceTimed.contains(track.id) ||
        _speechTimingCheck != null ||
        _autoSyncDone.contains(track.id) ||
        _isMediaOpening ||
        _switchingQuality ||
        _duration <= Duration.zero) {
      return;
    }
    // The right film or episode's at all? By its length (once).
    if (_canTryAnother(track) && _fitChecked.add(track.id)) {
      unawaited(_checkSubtitleFits(track));
    }
    // The sound's been heard already: this subtitle against it, now.
    final heard = _heard;
    if (heard != null &&
        heard.url == _streamUrl &&
        !_autoSynced.contains(track.id) &&
        _heardTried.add(track.id)) {
      _autoSync(track, heard: heard);
      return;
    }
    if (!_isPlaying || _isBuffering) return;
    if (pos - _watchedFrom! < _PlayerScreenState._autoSyncFirst) return;
    final tried = _autoSyncTries[track.id];
    if (tried != null && pos < tried.next) return;
    // From where watching began here: what's been watched, and enough of
    // what's next (the player's fetching it anyway) to have a long enough
    // stretch.
    var from = _watchedFrom!;
    var to = pos + const Duration(seconds: 10);
    if (to - from < _PlayerScreenState._autoSyncShortest) to = from + _PlayerScreenState._autoSyncShortest;
    if (to - from > _PlayerScreenState._autoSyncLongest) from = to - _PlayerScreenState._autoSyncLongest;
    // Not clear yet: the next stretch after the last one heard.
    final after = _autoSyncFrom[track.id];
    if (after != null && after + _PlayerScreenState._autoSyncShortest <= _duration) {
      from = after;
      to = after + _PlayerScreenState._autoSyncShortest;
    }
    // Listening reads the stream as fast as it can: only once the player
    // has a good lead on the video, so it never competes with playback
    // for a slow stream. (Tried again on the next tick.)
    if (player.state.buffer - pos < _PlayerScreenState._autoSyncMinLead) return;
    _autoSyncFrom.remove(track.id);
    _autoSync(track, from: from, to: to > _duration ? _duration : to);
  }

  /// Sets [track]'s timing by when people talk — in the sound from [from]
  /// to [to], heard by a second, silent player, or the sound [heard]
  /// already — matched against the subtitles' (SubtitleSync); any
  /// language. Only when the match is clear; otherwise left as it is, to
  /// try again.
  Future<void> _autoSync(
    SubtitleTrackData track, {
    Duration? from,
    Duration? to,
    ({String url, double start, Int16List pcm})? heard,
  }) async {
    final url = _streamUrl;
    _updateState(() {
      _speechTimingCheck = (stream: _streamId, track: track.id);
    });
    final took = Stopwatch()..start();
    var clear = false;
    Duration? checkFrom;
    print('[sync] ${heard != null ? 'matching what was heard' : 'listening'}'
        ': ${track.lang} subtitles (${track.id})'
        '${heard != null ? '' : ', ${from!.inSeconds}–${to!.inSeconds} s of the video'}'
        ', try ${(_autoSyncTries[track.id]?.tries ?? 0) + 1}');
    try {
      var cues = _subtitleCues[track.url];
      if (cues == null) {
        cues = SubtitleSync.parseCues(await _subtitleText(track));
        _subtitleCues[track.url] = cues;
      }
      final double start;
      final Int16List? pcm;
      if (heard != null) {
        start = heard.start;
        pcm = heard.pcm;
      } else {
        start = from!.inMilliseconds / 1000;
        final audio = player.state.track.audio.id;
        pcm = await SubtitleSync.decodeSound(
          url,
          start: start,
          end: to!.inMilliseconds / 1000,
          audioTrack: audio == 'auto' || audio == 'no' ? null : audio,
          // The second player reads the same stream as fast as it can:
          // stop it as soon as the player closes or the video changes.
          isCancelled: () => !mounted || _streamUrl != url,
        );
      }
      // Another episode or copy meanwhile: not this one's sound.
      if (!mounted || _streamUrl != url) return;
      if (pcm == null ||
          pcm.length <
              SubtitleSync.minSure.inMilliseconds *
                  SubtitleSync.sampleRate ~/
                  1000) {
        print("[sync] couldn't get the sound "
            '(${took.elapsedMilliseconds} ms)');
        return;
      }
      if (heard == null) {
        // Kept for another subtitle picked meanwhile; one already tried
        // against less sound is tried again with this.
        _heard = (url: url, start: start, pcm: pcm);
        _heardTried
          ..clear()
          ..add(track.id);
      }
      final result = await _findSubtitleTiming(pcm, start, cues);
      final end = start + pcm.length / SubtitleSync.sampleRate;
      print('[sync] ${track.lang} ${start.round()}–${end.round()} s: $result '
          '(${took.elapsedMilliseconds} ms)');
      // Checking stopped, references retimed it, or another
      // copy's playing.
      if (!mounted ||
          _streamUrl != url ||
          _autoSyncDone.contains(track.id) ||
          _referenceTimed.contains(track.id)) {
        return;
      }
      if (result == null) {
        checkFrom = Duration(milliseconds: (end * 1000).ceil());
        return;
      }
      final delay = (result.delay * 100).round() / 100;
      final evidence = _autoSyncSeen.putIfAbsent(track.id, SubtitleTimingEvidence.new);
      if (!evidence.confirms(result, start, end)) {
        checkFrom = Duration(milliseconds: (end * 1000).ceil());
        return;
      }
      clear = true;
      final selected = _selectedSubtitle?.id == track.id;
      final now = selected
          ? (delay: _subtitleDelaySeconds, speed: _subtitleSpeed)
          : _subtitleTimings[track.id];
      if (_autoSynced.contains(track.id) &&
          now != null &&
          (now.delay - delay).abs() < _PlayerScreenState._autoSyncMinChange &&
          (now.speed - result.speed).abs() < 0.001) {
        print('[sync] still in time');
        return;
      }
      print('[sync] applied: ${result.delay.toStringAsFixed(2)} s, '
          'speed ${result.speed.toStringAsFixed(4)}');
      if (selected) {
        _updateState(() {
          _subtitleDelaySeconds = delay;
          _subtitleSpeed = result.speed;
        });
        await _applySubtitleTimingToMpv();
      } else {
        // Switched from meanwhile: for when it's back.
        _subtitleTimings[track.id] = (delay: delay, speed: result.speed);
      }
      if (!mounted || _streamUrl != url) return;
      _rememberTiming(track,
          timing: (delay: delay, speed: result.speed));
    } catch (e) {
      print('[sync] failed: $e');
    } finally {
      _speechTimingCheck = null;
      if (!mounted || _streamUrl != url || _autoSyncDone.contains(track.id)) {
        // Discard results from obsolete or completed checks.
      } else if (clear) {
        // In time: checked again a while on.
        _autoSynced.add(track.id);
        _autoSyncTries[track.id] =
            (tries: 0, next: _currentPosition + _autoSyncRecheckEvery);
      } else {
        final tries = (_autoSyncTries[track.id]?.tries ?? 0) + 1;
        if (tries >= _PlayerScreenState._autoSyncMaxTries) {
          print('[sync] not applied; giving up on these subtitles');
          _autoSyncDone.add(track.id);
        } else if (checkFrom != null) {
          // More to go by: at once, the stretch after.
          _autoSyncFrom[track.id] = checkFrom;
          _autoSyncTries[track.id] = (tries: tries, next: _currentPosition);
        } else {
          print('[sync] not applied; trying again in '
              '${_PlayerScreenState._autoSyncRetry.inSeconds} s of watching');
          _autoSyncTries[track.id] =
              (tries: tries, next: _currentPosition + _PlayerScreenState._autoSyncRetry);
        }
      }
      // The subtitle menu's note (see _subtitleSyncNote).
      if (mounted) _updateState(() {});
    }
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

  /// [track] retimed against reference subtitles — others in the list made
  /// for a copy like the one playing (its kind of source: Blu-ray, web,
  /// TV), in any language, as when lines are on screen is what's compared
  /// — piece by piece along the video (SubtitleRetime). Two references
  /// from different release groups have to agree (or one made for this
  /// very file). Instant beside listening (Auto Sync), which needs minutes
  /// of sound — and right where a subtitle drifts from the copy: Ghosts
  /// S1E8's web-rip English one is 2.6 s off its Blu-ray copy at the start
  /// and 5.6 s by the end, in steps at the ad breaks, which no one delay
  /// fits. Without references, Auto Sync's listening goes on.
  Future<void> _retimeFromReferences(SubtitleTrackData track) async {
    if (!mounted || _closing) return;
    // Sinhala made from English: the English is retimed, and the Sinhala
    // follows it (see below).
    if (track.translatedFrom != null) {
      return _retimeFromReferences(track.translatedFrom!);
    }
    if (track.isEmbedded ||
        _retimedPaths.containsKey(track.id) ||
        _autoSyncDone.contains(track.id) ||
        _retimeTried.contains(track.id)) {
      return;
    }
    final stream = _currentStream;
    final video = '${stream.title}\n${stream.name}';
    if (SubtitleService.sourceOf(video) == null) return;
    // Made for this release (its group's, or this file): in time already.
    if (SubtitleService.likeness(track, video) >= 4) return;
    final refs = [
      for (final s in _externalSubtitles)
        if (s.id != track.id &&
            s.url.isNotEmpty &&
            SubtitleService.likeness(s, video) >= 2)
          s,
    ]..sort((a, b) => SubtitleService.likeness(b, video)
        .compareTo(SubtitleService.likeness(a, video)));
    // (Not yet, maybe: tried again when the list grows.)
    if (refs.length < 2 && !refs.any((r) => r.matchesFile)) return;
    _retimeTried.add(track.id);
    final url = _streamUrl;
    final check = (stream: _streamId, track: track.id);
    _updateState(() => _referenceTimingChecks.add(check));
    final took = Stopwatch()..start();
    try {
      final picked = refs.take(4).toList();
      final text = await _subtitleText(track);
      final refTexts = await Future.wait(picked.map(_subtitleText));
      final map = await _retimeMapInBackground(
        text,
        refTexts,
        [
          for (final r in picked)
            (r.releaseGroup ?? r.releaseName ?? r.id).toLowerCase(),
        ],
        [for (final r in picked) r.matchesFile],
      );
      if (!mounted || _streamUrl != url) return;
      if (map == null) {
        print('[sync] references (${picked.map((r) => r.lang).join(', ')}) '
            "don't agree; listening instead");
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
      _referenceTimed.add(track.id);
      final key = _timingKey(track);
      SharedPreferences.getInstance().then((prefs) {
        if (prefs.getString(key)?.endsWith('|confirmed') == true) {
          return prefs.remove(key);
        }
        return false;
      });
      print('[sync] retimed by references '
          '(${picked.map((r) => r.lang).join(', ')}) in '
          '${took.elapsedMilliseconds} ms: $map');
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
        _subtitleTimings[track.id] = (delay: 0.0, speed: 1.0);
        if (mounted) _updateState(() {});
      }
    } catch (e) {
      print('[sync] retiming failed: $e');
    } finally {
      if (mounted) _updateState(() => _referenceTimingChecks.remove(check));
    }
  }

  /// _retimeMap, off the screen's thread. (Static: nothing of the screen
  /// goes with it.)
  static Future<TimingMap?> _retimeMapInBackground(
    String text,
    List<String> refTexts,
    List<String> groups,
    List<bool> exact,
  ) =>
      Isolate.run(() => _retimeMap(text, refTexts, groups, exact));

  /// [text]'s timing map against the references [refTexts]: one made for
  /// this very file ([exact]) alone, otherwise two from different release
  /// [groups] that agree, averaged. Null if none do.
  static TimingMap? _retimeMap(
    String text,
    List<String> refTexts,
    List<String> groups,
    List<bool> exact,
  ) {
    final cues = SubtitleSync.parseCues(text);
    final maps = [
      for (final t in refTexts)
        SubtitleRetime.mapAgainst(cues, SubtitleSync.parseCues(t)),
    ];
    for (var i = 0; i < maps.length; i++) {
      if (exact[i] && maps[i] != null) return maps[i];
    }
    for (var i = 0; i < maps.length; i++) {
      for (var j = i + 1; j < maps.length; j++) {
        final a = maps[i], b = maps[j];
        if (a == null || b == null || groups[i] == groups[j]) continue;
        if (a.agreesWith(b)) return a.averagedWith(b);
      }
    }
    return null;
  }

  /// The subtitle menu's word on Auto Sync for the subtitles shown: at it,
  /// done — or nothing (subtitles in the video
  /// file, or given up on).
  String? get _subtitleSyncNote {
    final track = _selectedSubtitle;
    if (track == null) return null;
    if (track.isEmbedded) return null;
    if (_referenceTimed.contains(track.translatedFrom?.id ?? track.id)) return 'Matched to this video';
    if (_autoSyncDone.contains(track.id) || (_autoSyncTries[track.id]?.tries ?? 0) > 0) {
      return 'Couldn’t confirm timing';
    }
    if (_autoSynced.contains(track.id)) return 'Timing adjusted';
    return 'Checking timing…';
  }

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
    final key = _timingKey(track);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        key, '${t.delay}|${t.speed}|confirmed');
  }

  /// [track]'s timing kept from an earlier visit (see _rememberTiming).
  Future<({double delay, double speed})?> _savedTiming(
    SubtitleTrackData track,
  ) async {
    final key = _timingKey(track);
    final prefs = await SharedPreferences.getInstance();
    final parts = prefs.getString(key)?.split('|');
    if (parts == null || parts.length < 3 ||
        parts[2] != 'confirmed') {
      return null;
    }
    final delay = double.tryParse(parts[0]);
    final speed = double.tryParse(parts[1]);
    if (delay == null || speed == null) return null;
    return (delay: delay, speed: speed);
  }

  /// SubtitleSync.find, off the screen's thread: a few hundred
  /// milliseconds' sums on a phone. (Static: nothing of the screen goes
  /// with it.)
  static Future<SubtitleSyncResult?> _findSubtitleTiming(
    Int16List pcm,
    double start,
    List<SubtitleCue> cues,
  ) =>
      Isolate.run(() => SubtitleSync.find(pcm, windowStart: start, cues: cues));

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
