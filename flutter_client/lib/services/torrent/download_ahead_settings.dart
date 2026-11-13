import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's "Download ahead on mobile data" setting: whether the head
/// start (TorrentEngineService.warmUp) may download a few MB of what's
/// likely to be played next while on mobile data — Play then starts much
/// sooner. Off by default; on Wi-Fi it always does.
class DownloadAheadSettings {
  static final DownloadAheadSettings _instance =
      DownloadAheadSettings._internal();
  static const String _storageKey = 'download_ahead_on_mobile_data';

  factory DownloadAheadSettings() => _instance;

  DownloadAheadSettings._internal();

  final ValueNotifier<bool> onMobileData = ValueNotifier(false);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    onMobileData.value = prefs.getBool(_storageKey) ?? false;
  }

  Future<void> setOnMobileData(bool value) async {
    onMobileData.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, value);
  }
}
