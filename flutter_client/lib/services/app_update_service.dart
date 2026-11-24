import 'package:flutter/foundation.dart';

import 'feature_flags_service.dart';
import 'update_installer.dart';

/// A newer version that's out (see AppUpdateService.waiting).
class AppUpdate {
  final String version;

  /// The notes of every release newer than this app, newest first (the
  /// ones skipped too), as far back as the flags keep them.
  final List<ReleaseNotes> notes;

  const AppUpdate(this.version, this.notes);
}

/// Small updates: a newer version is out (flags.json `latest_version`) but
/// this one isn't too old to keep using (`min_required_version`, which
/// brings up the full-screen update instead). Settings offers it, with a
/// dot on its tab until it's installed (owner, 24 Nov 2026).
///
/// The release workflow decides which is which from the version number: a
/// new last number (4.5.3 → 4.5.4) is a small update; a new middle or first
/// number (→ 4.6.0) is required.
///
/// Android and Windows only: an iPhone updates through TestFlight, which
/// tells its users itself.
class AppUpdateService {
  static final AppUpdateService _instance = AppUpdateService._();
  factory AppUpdateService() => _instance;
  AppUpdateService._() {
    FeatureFlagsService().changes.addListener(_update);
    _update();
  }

  /// The small update waiting, or null.
  final ValueNotifier<AppUpdate?> waiting = ValueNotifier(null);

  /// Whether the Settings tab shows its dot: an update is waiting. It
  /// stays until the update's installed, opened or not.
  final ValueNotifier<bool> showDot = ValueNotifier(false);

  /// The notes of every release newer than this app, newest first.
  static List<ReleaseNotes> notesSinceThisVersion() {
    final flags = FeatureFlagsService();
    return [
      for (final release in flags.releaseNotes)
        if (compareVersions(release.version, flags.appVersion) > 0 &&
            release.notes.isNotEmpty)
          release,
    ];
  }

  void _update() {
    final flags = FeatureFlagsService();
    final latest = flags.latestVersion;
    final current = flags.appVersion;
    final isWaiting = UpdateInstaller.supported &&
        latest.isNotEmpty &&
        compareVersions(latest, current) > 0 &&
        // Older than that: the full-screen update, not this.
        compareVersions(current, flags.minRequiredVersion) >= 0;
    if (!isWaiting) {
      waiting.value = null;
      showDot.value = false;
      return;
    }
    if (waiting.value?.version != latest) {
      waiting.value = AppUpdate(latest, notesSinceThisVersion());
    }
    showDot.value = true;
  }
}
