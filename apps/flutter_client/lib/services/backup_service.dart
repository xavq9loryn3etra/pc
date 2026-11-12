import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'saved_movies_service.dart';
import 'app_mode_service.dart';
import 'feature_flags_service.dart';
import 'search_history_service.dart';
import 'torrent/download_ahead_settings.dart';

/// What a stored setting holds, for checking a backup's values.
enum _Kind { string, integer, decimal, boolean, stringList }

class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  /// Put in every exported backup, so an import can tell a backup from
  /// some other JSON file.
  static const String backupMarker = '_popcorn_backup';

  /// The settings a backup may restore, and what each holds. Anything
  /// else in the file is left out.
  static const Map<String, _Kind> _knownKeys = {
    'favorites_v1': _Kind.string,
    'watch_history_v1': _Kind.string,
    'episode_history_v1': _Kind.string,
    'episode_lengths_v1': _Kind.string,
    // Written by the storage-key migration (see SavedMoviesService).
    'storage_key_migrated_v1': _Kind.boolean,
    'selected_app_mode': _Kind.integer,
    'feature_flags_json': _Kind.string,
    'search_history_v1': _Kind.stringList,
    'download_ahead_on_mobile_data': _Kind.boolean,
    'torrent_download_registry_v1': _Kind.string,
    'has_seen_welcome': _Kind.boolean,
    'has_seen_onboarding': _Kind.boolean,
    'player_video_fit': _Kind.string,
    'player_volume': _Kind.decimal,
    'player_subtitle_lang': _Kind.string,
    'ai_questions_v1': _Kind.string,
    'logo_brightness_v1': _Kind.string,
    'glass_decision_v1': _Kind.string,
    'glass_strikes_v1': _Kind.integer,
  };

  /// Families of settings kept one per title, episode or track.
  static const Map<String, _Kind> _knownPrefixes = {
    'audio_language_': _Kind.string,
    'last_played_torrent_': _Kind.string,
    'last_played_language_': _Kind.string,
    'wd_streaming_ids_': _Kind.string,
    'trending_cache_v3_': _Kind.string,
    'subtitle_timing2_': _Kind.string,
  };

  static _Kind? _kindOf(String key) {
    final exact = _knownKeys[key];
    if (exact != null) return exact;
    // The premigration copies a storage-key migration keeps (any kind of
    // value: they're copies of the three above).
    if (key.endsWith('_premigration_backup')) return _Kind.string;
    for (final entry in _knownPrefixes.entries) {
      if (key.startsWith(entry.key)) return entry.value;
    }
    return null;
  }

  /// [value] as a setting of [kind], or null if it isn't one.
  static Object? _asKind(_Kind kind, Object? value) {
    switch (kind) {
      case _Kind.string:
        return value is String ? value : null;
      case _Kind.integer:
        return value is int ? value : null;
      case _Kind.decimal:
        return value is num ? value.toDouble() : null;
      case _Kind.boolean:
        return value is bool ? value : null;
      case _Kind.stringList:
        return value is List && value.every((e) => e is String)
            ? value.cast<String>().toList()
            : null;
    }
  }

  /// Whether [json] is a string that decodes to a [T] (a list or a map).
  static bool _decodesTo<T>(Object? json) {
    if (json is! String) return false;
    try {
      return jsonDecode(json) is T;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _write(
      SharedPreferences prefs, String key, Object value) async {
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.cast<String>().toList());
    }
  }

  Future<bool> exportData() async {
    try {
      await SavedMoviesService().flush();
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final Map<String, dynamic> allData = {backupMarker: 1};

      for (String key in keys) {
        allData[key] = prefs.get(key);
      }

      final jsonString = jsonEncode(allData);
      final bytes = Uint8List.fromList(utf8.encode(jsonString));

      // Select location to save and write bytes
      String? outputPath = await FilePicker.saveFile(
        dialogTitle: 'Export Backup',
        fileName: 'popcorn_backup.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );

      return outputPath != null;
    } catch (e) {
      print("Export error: $e");
      return false;
    }
  }

  Future<bool> importData() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) return false;

      final file = File(result.files.single.path!);
      final jsonString = await file.readAsString();
      return await importJson(jsonString);
    } catch (e) {
      print("Import error: $e");
      return false;
    }
  }

  /// Replaces the stored settings with those in [jsonString], a backup
  /// made by [exportData] — checked first, so the wrong file changes
  /// nothing. Returns whether it was imported.
  Future<bool> importJson(String jsonString) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      print("Import error: not JSON ($e)");
      return false;
    }
    if (decoded is! Map<String, dynamic>) return false;
    final data = decoded;

    // A backup of this app: marked as one (or, made before backups were
    // marked, holding its favourites or history).
    if (data[backupMarker] != 1 &&
        !data.containsKey('favorites_v1') &&
        !data.containsKey('watch_history_v1')) {
      print("Import error: not a Popcorn backup");
      return false;
    }
    // Its favourites and history must be readable, or it isn't one to
    // replace them with.
    if (data.containsKey('favorites_v1') &&
        !_decodesTo<List>(data['favorites_v1'])) {
      return false;
    }
    if (data.containsKey('watch_history_v1') &&
        !_decodesTo<Map>(data['watch_history_v1'])) {
      return false;
    }

    // Only settings this app keeps, each holding what it should.
    final toWrite = <String, Object>{};
    data.forEach((key, value) {
      final kind = _kindOf(key);
      if (kind == null) return;
      final checked = _asKind(kind, value);
      if (checked != null) toWrite[key] = checked;
    });

    // History changes still waiting to be written are part of "now".
    await SavedMoviesService().flush();
    final prefs = await SharedPreferences.getInstance();
    // What's stored now, to put back if writing the backup fails partway.
    final snapshot = <String, Object>{
      for (final key in prefs.getKeys())
        if (prefs.get(key) != null) key: prefs.get(key)!,
    };

    try {
      // Clear existing to avoid mix
      await prefs.clear();
      for (final entry in toWrite.entries) {
        await _write(prefs, entry.key, entry.value);
      }
    } catch (e) {
      print("Import error: $e; restoring what was there");
      try {
        await prefs.clear();
        for (final entry in snapshot.entries) {
          await _write(prefs, entry.key, entry.value);
        }
      } catch (e) {
        print("Restore error: $e");
      }
      await _reloadServices();
      return false;
    }

    await _reloadServices();
    return true;
  }

  /// Re-init services to reflect new data in memory. (SavedMoviesService
  /// also brings a backup made by an older version up to date: see its
  /// storage-key migration.)
  Future<void> _reloadServices() async {
    await SavedMoviesService().init();
    await AppModeService().init();
    await DownloadAheadSettings().init();
    await SearchHistoryService().load(force: true);
    await FeatureFlagsService().init();
  }
}
