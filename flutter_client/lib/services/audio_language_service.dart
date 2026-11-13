import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie.dart';

/// A language as the app meets it: its name, the flags Torrentio marks a
/// copy's audio with, and the codes video files tag their soundtracks with
/// (what the player is told to look for).
class SpokenLanguage {
  final String name;
  final Set<String> flags;
  final List<String> trackCodes;

  const SpokenLanguage(this.name, this.flags, this.trackCodes);

  static const english =
      SpokenLanguage('English', {'🇬🇧', '🇺🇸'}, ['eng', 'en', 'english']);

  /// The language with TMDB's code [code] ("de", "ja"), or null when it's
  /// not one the app knows.
  static SpokenLanguage? of(String? code) => code == null ? null : _all[code];

  static const _all = <String, SpokenLanguage>{
    'en': english,
    'de': SpokenLanguage('German', {'🇩🇪'}, ['ger', 'deu', 'de']),
    'fr': SpokenLanguage('French', {'🇫🇷'}, ['fre', 'fra', 'fr']),
    'es': SpokenLanguage('Spanish', {'🇪🇸', '🇲🇽'}, ['spa', 'es']),
    'it': SpokenLanguage('Italian', {'🇮🇹'}, ['ita', 'it']),
    'pt': SpokenLanguage('Portuguese', {'🇵🇹', '🇧🇷'}, ['por', 'pt']),
    'ru': SpokenLanguage('Russian', {'🇷🇺'}, ['rus', 'ru']),
    'ja': SpokenLanguage('Japanese', {'🇯🇵'}, ['jpn', 'ja']),
    'ko': SpokenLanguage('Korean', {'🇰🇷'}, ['kor', 'ko']),
    'zh': SpokenLanguage('Chinese', {'🇨🇳', '🇹🇼', '🇭🇰'}, ['chi', 'zho', 'zh']),
    // TMDB's code for Cantonese.
    'cn': SpokenLanguage('Cantonese', {'🇭🇰', '🇨🇳'}, ['yue', 'chi', 'zho']),
    'hi': SpokenLanguage('Hindi', {'🇮🇳'}, ['hin', 'hi']),
    'ta': SpokenLanguage('Tamil', {'🇮🇳'}, ['tam', 'ta']),
    'te': SpokenLanguage('Telugu', {'🇮🇳'}, ['tel', 'te']),
    'ml': SpokenLanguage('Malayalam', {'🇮🇳'}, ['mal', 'ml']),
    'kn': SpokenLanguage('Kannada', {'🇮🇳'}, ['kan', 'kn']),
    'si': SpokenLanguage('Sinhala', {'🇱🇰'}, ['sin', 'si']),
    'bn': SpokenLanguage('Bengali', {'🇮🇳', '🇧🇩'}, ['ben', 'bn']),
    'mr': SpokenLanguage('Marathi', {'🇮🇳'}, ['mar', 'mr']),
    'nl': SpokenLanguage('Dutch', {'🇳🇱'}, ['dut', 'nld', 'nl']),
    'sv': SpokenLanguage('Swedish', {'🇸🇪'}, ['swe', 'sv']),
    'da': SpokenLanguage('Danish', {'🇩🇰'}, ['dan', 'da']),
    'no': SpokenLanguage('Norwegian', {'🇳🇴'}, ['nor', 'nob', 'no', 'nb']),
    'nb': SpokenLanguage('Norwegian', {'🇳🇴'}, ['nor', 'nob', 'no', 'nb']),
    'fi': SpokenLanguage('Finnish', {'🇫🇮'}, ['fin', 'fi']),
    'is': SpokenLanguage('Icelandic', {'🇮🇸'}, ['ice', 'isl', 'is']),
    'pl': SpokenLanguage('Polish', {'🇵🇱'}, ['pol', 'pl']),
    'cs': SpokenLanguage('Czech', {'🇨🇿'}, ['cze', 'ces', 'cs']),
    'hu': SpokenLanguage('Hungarian', {'🇭🇺'}, ['hun', 'hu']),
    'ro': SpokenLanguage('Romanian', {'🇷🇴'}, ['rum', 'ron', 'ro']),
    'el': SpokenLanguage('Greek', {'🇬🇷'}, ['gre', 'ell', 'el']),
    'uk': SpokenLanguage('Ukrainian', {'🇺🇦'}, ['ukr', 'uk']),
    'tr': SpokenLanguage('Turkish', {'🇹🇷'}, ['tur', 'tr']),
    'ar': SpokenLanguage('Arabic', {'🇸🇦', '🇪🇬', '🇦🇪'}, ['ara', 'ar']),
    'he': SpokenLanguage('Hebrew', {'🇮🇱'}, ['heb', 'he']),
    'fa': SpokenLanguage('Persian', {'🇮🇷'}, ['per', 'fas', 'fa']),
    'th': SpokenLanguage('Thai', {'🇹🇭'}, ['tha', 'th']),
    'vi': SpokenLanguage('Vietnamese', {'🇻🇳'}, ['vie', 'vi']),
    'id': SpokenLanguage('Indonesian', {'🇮🇩'}, ['ind', 'id']),
    'ms': SpokenLanguage('Malay', {'🇲🇾'}, ['may', 'msa', 'ms']),
    'tl': SpokenLanguage('Filipino', {'🇵🇭'}, ['fil', 'tgl', 'tl']),
  };
}

/// Which audio a title not made in English plays in.
enum AudioLanguage { english, original }

/// The audio language chosen for each title not made in English — in its
/// quality popup or the player's settings — kept for the whole series (or
/// movie), so every episode after, the next one included, is found and
/// played in it. Titles made in English always play in English.
class AudioLanguageService {
  static final AudioLanguageService _instance = AudioLanguageService._();
  factory AudioLanguageService() => _instance;
  AudioLanguageService._();

  /// What's played when nothing's been chosen: the original soundtrack,
  /// which is also what most copies of such titles carry.
  static const AudioLanguage defaultChoice = AudioLanguage.original;

  final Map<String, AudioLanguage> _choices = {};
  Future<void>? _loading;

  /// Bumped whenever a choice changes.
  final ValueNotifier<int> changes = ValueNotifier(0);

  static String _key(Movie m) => 'audio_language_${m.type}_${m.id}';

  /// Whether [m] gets a choice: it's known to be made in another language.
  static bool appliesTo(Movie m) {
    final code = m.originalLanguage;
    return code != null && code.isNotEmpty && code != 'en';
  }

  /// [m]'s original language — its name falls back to "Original" for one
  /// the app doesn't know.
  static SpokenLanguage originalOf(Movie m) =>
      SpokenLanguage.of(m.originalLanguage) ??
      SpokenLanguage('Original', const {}, [
        if (m.originalLanguage != null) m.originalLanguage!,
      ]);

  /// Reads the saved choices, once.
  Future<void> ensureLoaded() => _loading ??= () async {
        final prefs = await SharedPreferences.getInstance();
        for (final key in prefs.getKeys()) {
          if (!key.startsWith('audio_language_')) continue;
          final value = prefs.getString(key);
          _choices[key] = value == 'english'
              ? AudioLanguage.english
              : AudioLanguage.original;
        }
      }();

  /// [m]'s choice (see [ensureLoaded] — until then, the default).
  AudioLanguage of(Movie m) => _choices[_key(m)] ?? defaultChoice;

  /// The language [m] plays in: English for a title made in English.
  SpokenLanguage languageFor(Movie m) =>
      !appliesTo(m) || of(m) == AudioLanguage.english
          ? SpokenLanguage.english
          : originalOf(m);

  Future<void> set(Movie m, AudioLanguage choice) async {
    if (of(m) == choice) return;
    _choices[_key(m)] = choice;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(m), choice.name);
  }

  /// The name of the language [m] plays in with [choice] (by default, the
  /// one saved for it) — "English" for a title made in English.
  String nameFor(Movie m, [AudioLanguage? choice]) =>
      !appliesTo(m) || (choice ?? of(m)) == AudioLanguage.english
          ? SpokenLanguage.english.name
          : originalOf(m).name;

  /// The order the player should look for soundtracks in for [m]: its
  /// language first, then the other one.
  List<String> trackOrderFor(Movie m) {
    final first = languageFor(m);
    final other = first == SpokenLanguage.english
        ? (appliesTo(m) ? originalOf(m) : null)
        : SpokenLanguage.english;
    return [...first.trackCodes, ...?other?.trackCodes];
  }
}
