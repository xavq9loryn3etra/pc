import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps torrent buffering/seeding alive while the app is backgrounded during
/// playback (video/audio itself is paused, but the download shouldn't be
/// throttled/killed by Android Doze/App Standby). Android-only — no-op
/// elsewhere, since flutter_foreground_task is an Android foreground-service
/// wrapper.
class BackgroundDownloadService {
  static final BackgroundDownloadService _instance =
      BackgroundDownloadService._();
  static BackgroundDownloadService get instance => _instance;
  BackgroundDownloadService._();

  bool _initialized = false;

  void init() {
    if (!Platform.isAndroid || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'torrent_download_service',
        channelName: 'Background Buffering',
        channelDescription:
            'Shown while a torrent keeps buffering after you leave the app during playback.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      // No TaskHandler/callback is used — the torrent engine already runs
      // its own native download logic in the main isolate. This service
      // exists purely to keep the OS from freezing/killing the process
      // while backgrounded, via the required persistent notification.
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    init();

    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      serviceId: 322,
      notificationTitle: 'Popcorn',
      notificationText: 'Buffering in the background…',
    );
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
