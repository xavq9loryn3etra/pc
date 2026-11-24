import 'dart:convert';
import 'dart:io' show Platform;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One release's notes (see FeatureFlagsService.releaseNotes).
class ReleaseNotes {
  final String version;
  final List<String> notes;

  const ReleaseNotes(this.version, this.notes);
}

/// Compares two versions like "4.5.3" (a "+build" part is ignored):
/// negative if [a] is older than [b], 0 if the same, positive if newer.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
        for (final p in v.split('+').first.trim().split('.'))
          int.tryParse(p) ?? 0,
      ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    if (p != q) return p.compareTo(q);
  }
  return 0;
}

/// Remote flags, read from a static JSON file on the public website
/// (`docs/flags.json` in popcorn-organization/popcorn, on GitHub Pages).
/// This repo's `docs/flags.json` is an identical copy that older app
/// versions still read; the release workflow copies it to the public repo,
/// so a change by hand goes into both. Apps pick a change up on next launch
/// or when brought back to the foreground.
///
/// Top-level keys apply to every platform; an `android` / `ios` /
/// `windows` / `macos` object overrides them for that platform only, e.g.
/// `{"hide_playback": false, "ios": {"hide_playback": true}}`.
///
/// `hide_playback` — when true, every playback affordance is hidden: Play /
/// Resume buttons, the Continue Watching row, watch-progress bars and
/// S/E badges, tappable episode rows, and Settings > Storage. Purely
/// cosmetic: services, history tracking and the torrent engine are left
/// untouched, so flipping it back off restores everything as it was.
///
/// `sync_enabled` — false pauses syncing with Google Drive everywhere
/// (Settings says it's paused for now); nothing is lost, it carries on when
/// set back to true. `sync_blocked_versions` — a list of app versions
/// (e.g. `["4.2.0"]`) that mustn't sync, for a release with a sync bug.
///
/// `latest_version` — the newest release. Older than it but not older than
/// `min_required_version`: a small update is waiting, offered in Settings
/// (AppUpdateService). `release_notes` — the last few releases' notes,
/// newest first: `[{"version": "4.5.4", "notes": ["…", "…"]}]`, written in
/// RELEASE_NOTES.md and copied here by the release workflow.
class FeatureFlagsService {
  static final FeatureFlagsService _instance = FeatureFlagsService._internal();
  factory FeatureFlagsService() => _instance;
  FeatureFlagsService._internal();

  static const String flagsUrl =
      'https://popcorn-organization.github.io/popcorn/flags.json';
  static const String _cacheKey = 'feature_flags_json';
  // Foreground re-checks closer together than this are skipped.
  static const Duration _minRefreshInterval = Duration(minutes: 1);

  static const Map<String, dynamic> _defaults = {
    'min_required_version': '1.0.0',
    'update_required_message':
        'A new update is available. Please update the app.',
    'update_url':
        'https://drive.google.com/drive/folders/1ftzQcKIUkB2sKwInoSdMG7-SH4rPf96i?usp=sharing',
    'maintenance_mode_enabled': false,
    'maintenance_message':
        'We are currently performing a scheduled maintenance. Please check back later.',
    'hide_playback': false,
  };

  final ValueNotifier<bool> hidePlayback = ValueNotifier(false);

  /// Bumped each time flags are applied (cached or fetched), for what reads
  /// the update fields (AppUpdateService).
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// This app's version (pubspec's, without the build number), once
  /// [init] has run.
  String appVersion = '0.0.0';

  /// A test build's pretend update (`--dart-define=UPDATE_TEST=small` or
  /// `big`): the flags say a newer version is out, with long notes, so the
  /// Settings button, the dot and the update pages can be tried. Empty
  /// (off) in every real build.
  static const String _updateTest = String.fromEnvironment('UPDATE_TEST');

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));
  Map<String, dynamic> _values = Map.of(_defaults);
  DateTime? _lastRefresh;

  bool get maintenanceEnabled => _bool('maintenance_mode_enabled');
  String get maintenanceMessage => _string('maintenance_message');
  String get minRequiredVersion => _string('min_required_version');
  String get updateRequiredMessage => _string('update_required_message');
  String get updateUrl => _string('update_url');

  /// The newest release ('' if the flags don't say).
  String get latestVersion {
    final value = _values['latest_version'];
    return value is String ? value : '';
  }

  /// The last few releases' notes, newest first (see the class notes).
  List<ReleaseNotes> get releaseNotes {
    final value = _values['release_notes'];
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map &&
            entry['version'] is String &&
            entry['notes'] is List)
          ReleaseNotes(
            entry['version'] as String,
            [
              for (final note in entry['notes'] as List)
                if (note is String && note.trim().isNotEmpty) note.trim(),
            ],
          ),
    ];
  }

  /// Whether syncing with Google Drive may run (see the class notes).
  bool get syncEnabled {
    final value = _values['sync_enabled'];
    return value is bool ? value : true;
  }

  /// Whether app version [version] has been stopped from syncing.
  bool syncBlocked(String version) {
    final value = _values['sync_blocked_versions'];
    return value is List && value.contains(version);
  }

  /// Restores the last fetched flags so the UI is right from the very
  /// first frame (including offline launches, where the fetch fails).
  Future<void> init() async {
    try {
      appVersion = (await PackageInfo.fromPlatform()).version.split('+').first;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) _apply(jsonDecode(cached));
    } catch (_) {}
  }

  /// Fetches the latest flags. On failure the cached (or default) values
  /// stay in effect. Returns whether the fetch succeeded.
  Future<bool> refresh() async {
    _lastRefresh = DateTime.now();
    try {
      final response = await _dio.get<String>(
        flagsUrl,
        // GitHub Pages' CDN caches files for ~10 minutes; a unique query
        // string makes it serve the latest pushed version.
        queryParameters: {'t': DateTime.now().millisecondsSinceEpoch},
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data;
      if (body == null) return false;
      _apply(jsonDecode(body));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, body);
      return true;
    } catch (e) {
      debugPrint('Failed to fetch feature flags: $e');
      return false;
    }
  }

  /// [refresh], throttled — for re-checking when the app is resumed.
  Future<void> refreshIfStale() async {
    final last = _lastRefresh;
    if (last != null && DateTime.now().difference(last) < _minRefreshInterval) {
      return;
    }
    await refresh();
  }

  void _apply(dynamic json) {
    if (json is! Map<String, dynamic>) return;
    final values = Map<String, dynamic>.of(_defaults)..addAll(json);
    final overrides = json[_platformKey];
    if (overrides is Map<String, dynamic>) values.addAll(overrides);
    if (_updateTest.isNotEmpty) _pretendUpdate(values);
    _values = values;
    hidePlayback.value = _bool('hide_playback');
    changes.value++;
  }

  /// See [_updateTest]. "small": the next last number is out; "big": the
  /// next middle number is, and required.
  void _pretendUpdate(Map<String, dynamic> values) {
    final parts = [
      for (final p in appVersion.split('.')) int.tryParse(p) ?? 0,
      0, 0, 0,
    ];
    final small = '${parts[0]}.${parts[1]}.${parts[2] + 1}';
    final big = '${parts[0]}.${parts[1] + 1}.0';
    final latest = _updateTest == 'big' ? big : small;
    values['latest_version'] = latest;
    if (_updateTest == 'big') values['min_required_version'] = big;
    values['release_notes'] = [
      {
        'version': latest,
        'notes': [
          'Subtitles stay in time when you skip ahead or go back.',
          'Continue Watching moves on to the next episode as soon as one '
              'finishes, and a series you finished comes back when a new '
              'episode is out.',
          'Long-press a Continue Watching card for More Info, or to remove '
              'it. Undo puts it back.',
          'Sinhala subtitles are in time at once when the English ones '
              'already are.',
          'Smoother edges on the tab buttons and page titles.',
          'The Home slideshow no longer jumps to a far slide when a tab '
              'opens mid-slide.',
          'Crash reports help fix problems sooner. They never include your '
              'Google account or keys.',
          'Search and Ask open with the keyboard ready.',
        ],
      },
      if (_updateTest == 'big')
        {
          'version': small,
          'notes': [
            'Faster start on slow connections.',
            'Fixed the play button sometimes needing a second press.',
          ],
        },
    ];
  }

  static String get _platformKey {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'other';
  }

  bool _bool(String key) {
    final value = _values[key];
    return value is bool ? value : _defaults[key] as bool;
  }

  String _string(String key) {
    final value = _values[key];
    return value is String ? value : _defaults[key] as String;
  }
}
