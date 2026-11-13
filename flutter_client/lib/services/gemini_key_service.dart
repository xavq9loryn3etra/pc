import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The viewer's own Gemini API key, entered in Settings: free from Google
/// AI Studio, and theirs alone, so what it does — Sinhala subtitles (see
/// SubtitleTranslator), Popcorn Ask (AiService) — counts against their
/// own free allowance, not the one the app's built-in key shares with
/// everyone. Kept on the device only: left out of backups (see
/// BackupService.exportData).
class GeminiKeyService {
  static final GeminiKeyService _instance = GeminiKeyService._();
  factory GeminiKeyService() => _instance;
  GeminiKeyService._();

  /// Where the key is kept (also what BackupService leaves out).
  static const prefsKey = 'gemini_api_key';

  /// The key, or null when none's been entered.
  final ValueNotifier<String?> key = ValueNotifier(null);

  bool get hasKey => (key.value ?? '').isNotEmpty;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(prefsKey)?.trim();
    key.value = saved == null || saved.isEmpty ? null : saved;
  }

  Future<void> save(String value) async {
    final trimmed = value.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove(prefsKey);
      key.value = null;
    } else {
      await prefs.setString(prefsKey, trimmed);
      key.value = trimmed;
    }
  }

  Future<void> remove() => save('');

  /// Whether [candidate] works: a tiny request to Gemini with it. Null
  /// when it does, otherwise what's wrong, said plainly.
  static Future<String?> test(String candidate) async {
    final value = candidate.trim();
    if (value.isEmpty) return 'Paste your key first.';
    try {
      final response = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      )).get(
        'https://generativelanguage.googleapis.com/v1beta/models',
        options: Options(headers: {'x-goog-api-key': value}),
        queryParameters: {'pageSize': 1},
      );
      return response.statusCode == 200 ? null : "That key didn't work.";
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        return "That key didn't work. Check it was copied in full.";
      }
      if (status == 429) return null; // It works; just busy right now.
      return "Couldn't reach Google. Check your connection.";
    }
  }
}
