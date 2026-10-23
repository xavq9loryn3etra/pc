import 'dart:convert';
import 'dart:io' show Platform;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remote flags, read from a static JSON file on GitHub Pages
/// (`docs/flags.json` at the repo root). Edit and push that file to change
/// them; apps pick the change up on next launch or when brought back to
/// the foreground.
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
class FeatureFlagsService {
  static final FeatureFlagsService _instance = FeatureFlagsService._internal();
  factory FeatureFlagsService() => _instance;
  FeatureFlagsService._internal();

  static const String flagsUrl =
      'https://xavq9loryn3etra.github.io/pc/flags.json';
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

  /// Restores the last fetched flags so the UI is right from the very
  /// first frame (including offline launches, where the fetch fails).
  Future<void> init() async {
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
    _values = values;
    hidePlayback.value = _bool('hide_playback');
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
