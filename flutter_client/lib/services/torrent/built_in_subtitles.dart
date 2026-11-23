import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../audio_language_service.dart';
import '../subtitle_service.dart';
import '../sync/sync_bridge.dart';
import 'torrent_index_service.dart';

/// Which copies carry subtitles of their own (built into the video file),
/// for StreamResolver to prefer one in the viewer's subtitle language:
/// built-in subtitles are always in time with the video, where downloaded
/// ones often need syncing.
///
/// Known two ways: the copies seen, once played, to have a text subtitle
/// track in a language ([noteTracks], saved, the latest 500), and what a
/// release's name says ([namedSubtitles]: "ESub", "Multi-Subs", "English
/// Subs").
class BuiltInSubtitles {
  // The settings, kept once read: reading the subtitle language from them
  // is then instant, and always up to date — the player's choice and a
  // synced one are written to this same copy (SharedPreferences keeps one).
  static SharedPreferences? _prefs;
  static Future<void>? _loading;

  // Info hash (lowercase) → the TMDB codes of its built-in text subtitles,
  // comma-separated.
  static Map<String, String> _known = {};
  static const _knownKey = 'built_in_subtitles_v1';
  static const _cap = 500;

  /// Reads what's saved (once).
  static Future<void> init() =>
      _loading ??= SharedPreferences.getInstance().then((prefs) {
        _prefs = prefs;
        _known = {
          for (final e in prefs.getStringList(_knownKey) ?? const <String>[])
            if (e.lastIndexOf('=') case final i when i > 0)
              e.substring(0, i): e.substring(i + 1),
        };
      }).catchError((Object _) {});

  /// Forgets what was read, for tests (each sets its own settings).
  @visibleForTesting
  static void debugReset() {
    _prefs = null;
    _loading = null;
    _known = {};
  }

  /// The language the viewer usually has subtitles in, by TMDB code ("en")
  /// — null when they're off, or the settings aren't read yet. As the
  /// player has it: English when never chosen.
  static String? get wantedLanguage {
    final prefs = _prefs;
    if (prefs == null) return null;
    try {
      return wantedFrom(prefs.getString(SyncBridge.subtitleLangKey));
    } catch (_) {
      return null;
    }
  }

  /// The language a saved subtitle choice ([choice]: "eng", "spa", or ""
  /// for off) stands for — see [wantedLanguage].
  @visibleForTesting
  static String? wantedFrom(String? choice) {
    final value = (choice ?? 'eng').trim();
    if (value.isEmpty) return null;
    return _codeOf(value, value);
  }

  /// A subtitle track's language by TMDB code, from its tag ("eng") or
  /// name ("English SDH"); a tag the app doesn't know as it is ("hrv").
  static String? _codeOf(String? tag, String? name) {
    final code = SpokenLanguage.codeOfTrack(tag, name);
    if (code != null) return code;
    final t = tag?.toLowerCase().trim() ?? '';
    if (!RegExp(r'^[a-z]{2,3}$').hasMatch(t)) return null;
    if (t == 'und' || t == 'mul' || t == 'zxx') return null;
    // OpenSubtitles' Brazilian Portuguese.
    if (t == 'pob' || t == 'pb') return 'pt';
    return t;
  }

  // Tracks that don't carry the dialogue: forced (foreign lines only),
  // signs, songs.
  static final _partial =
      RegExp(r'forced|signs?(?![a-z])|songs?(?![a-z])', caseSensitive: false);

  /// Notes the text subtitle tracks built into the copy [infoHash], as the
  /// player found them playing it ([tracks]: picture ones already left
  /// out). Only ever adds: a copy's tracks are listed bit by bit as it
  /// opens, nothing at first.
  static void noteTracks(String infoHash, Iterable<SubtitleTrackData> tracks) {
    final codes = <String>{
      for (final t in tracks)
        if (t.isEmbedded && !_partial.hasMatch('${t.lang} ${t.label ?? ''}'))
          if (_codeOf(t.lang, t.label) case final code?) code,
    };
    if (codes.isEmpty) return;
    unawaited(_note(infoHash.toLowerCase(), codes));
  }

  static Future<void> _note(String hash, Set<String> codes) async {
    await init();
    final had = knownIn(hash);
    if (had.containsAll(codes)) return;
    _known.remove(hash);
    _known[hash] = ({...had, ...codes}.toList()..sort()).join(',');
    final entries = _known.entries.toList();
    final kept = entries.length > _cap
        ? entries.sublist(entries.length - _cap)
        : entries;
    _known = Map.fromEntries(kept);
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      await prefs.setStringList(
          _knownKey, [for (final e in kept) '${e.key}=${e.value}']);
    } catch (_) {}
  }

  /// The languages (TMDB codes) [infoHash] was seen to have built-in text
  /// subtitles in — empty when it wasn't (or hasn't been played).
  static Set<String> knownIn(String infoHash) =>
      (_known[infoHash.toLowerCase()] ?? '')
          .split(',')
          .where((c) => c.isNotEmpty)
          .toSet();

  /// What [namedSubtitles] gives for "subtitles in several languages".
  static const multi = '*';

  // A subtitles word: "Sub", "Subs", "Subbed", "Subtitles", "Subtitled" —
  // not inside a longer word ("Subway", "SubsPlease", "The Substance").
  static final _subWord =
      RegExp(r'sub(s|bed|titles?|titled)?(?![a-z])', caseSensitive: false);
  static final _letters = RegExp(r'[a-z]', caseSensitive: false);

  /// What [word] (next to a subtitles word) says: a language's TMDB code,
  /// [multi], '' for none ("No Subs", "HardSubs": burnt into the picture,
  /// not a track the player can use), or null when it isn't about the
  /// subtitles at all.
  static String? _wordSays(String word) {
    final w = word.toLowerCase();
    switch (w) {
      case 'e':
        return 'en';
      case 'm':
      case 'mul':
      case 'multi':
        return multi;
      case 'no':
      case 'without':
      case 'hard':
      case 'hardcoded':
      case 'burned':
      case 'burnt':
      case 'hc':
        return '';
      case 'esp':
        return 'es';
    }
    // A language's full name, or its three-letter code: never a two-letter
    // one ("No", "It", "Is" are words).
    if (w.length < 3) return null;
    return SpokenLanguage.codeOfTrack(w, w);
  }

  /// The subtitle languages [stream]'s name says it carries, by TMDB code,
  /// with [multi] for several unnamed ones:
  ///  - "ESub", "E-Subs": English (Indian releases' mark)
  ///  - "MSub", "MSubs", "Multi-Sub", "MultiSubs": several ([multi])
  ///  - a language right before ("English Subs", "Eng.Sub", "EngSubs",
  ///    "Eng+Ita Subs") or, with none there, right after ("Sub Ita",
  ///    "Subs English"): those (full names and three-letter codes)
  ///  - "Subs", "Subbed", "Subtitles", "Subtitled" on their own: English
  ///  - not "No Subs", nor "HardSub": burnt into the picture
  /// The release name counts, and for a pack the episode file's name too;
  /// words of the title's own name don't.
  static Set<String> namedSubtitles(TorrentStream stream) {
    final lines = stream.title.split('\n');
    final stats = lines.indexWhere((l) => l.contains('👤') || l.contains('💾'));
    var text = [
      stream.name,
      if (stats > 1) ...lines.sublist(1, stats),
    ].join(' ').replaceAll(RegExp(r'[._\[\]()]'), ' ');
    final titleName = stream.wantedAudio?.titleName.trim() ?? '';
    if (titleName.isNotEmpty) {
      text = text.replaceAll(
          RegExp(RegExp.escape(titleName).replaceAll(' ', r'\s+'),
              caseSensitive: false),
          ' ');
    }

    final found = <String>{};
    for (final m in _subWord.allMatches(text)) {
      final before = text.substring(0, m.start);
      // Letters joined on: "ESub", "MSubs", "EngSub", "HorribleSubs".
      var i = before.length;
      while (i > 0 && _letters.hasMatch(before[i - 1])) {
        i--;
      }
      final glued = before.substring(i);
      if (glued.isNotEmpty) {
        final says = _wordSays(glued);
        // Another word's end ("HorribleSubs"): not a mark at all.
        if (says != null && says.isNotEmpty) found.add(says);
        continue;
      }
      // The words before, as a list of languages ("Eng+Ita", "Eng/Ita")
      // or one ("Eng Subs", "ENG-SUB").
      final words = RegExp(r'([a-z]+)((?:\s*[+/&,]\s*|\s*-\s*|\s+)?)$',
              caseSensitive: false)
          .firstMatch(before);
      if (words != null) {
        final says = _wordSays(words[1]!);
        if (says != null) {
          if (says.isNotEmpty) {
            found.add(says);
            // More of a list before it, joined by + / & , -.
            var rest = before.substring(0, words.start);
            while (true) {
              final more =
                  RegExp(r'([a-z]+)\s*[+/&,-]\s*$', caseSensitive: false)
                      .firstMatch(rest);
              final code = more == null ? null : _wordSays(more[1]!);
              if (code == null || code.isEmpty) break;
              found.add(code);
              rest = rest.substring(0, more!.start);
            }
          }
          continue;
        }
      }
      // A language after it: "Sub Ita", "Subs-English".
      final after = RegExp(r'^[ -]+([a-z]+)(?![a-z])', caseSensitive: false)
          .firstMatch(text.substring(m.end));
      final word = m[0]!.toLowerCase();
      if (after != null && (word == 'sub' || word == 'subs')) {
        final says = _wordSays(after[1]!);
        if (says != null) {
          if (says.isNotEmpty) found.add(says);
          continue;
        }
      }
      // On its own: English, as release names are written.
      if (word != 'sub') found.add('en');
    }
    return found;
  }

  /// How sure it is that [stream] has built-in subtitles in [wanted] (by
  /// default [wantedLanguage]) — lower is surer:
  ///  0 — seen to have them ([knownIn]); or no subtitles wanted (all equal)
  ///  1 — its name says so ([namedSubtitles]: that language, or several)
  ///  2 — neither
  static int rank(TorrentStream stream, [String? wanted]) {
    wanted ??= wantedLanguage;
    if (wanted == null) return 0;
    bool fits(String code) => SpokenLanguage.mayBeSame(code, wanted!);
    if (knownIn(stream.infoHash).any(fits)) return 0;
    final named = namedSubtitles(stream);
    if (named.contains(multi) || named.any(fits)) return 1;
    return 2;
  }
}
