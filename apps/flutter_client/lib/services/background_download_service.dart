import 'dart:async';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'torrent/torrent_engine_service.dart';

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

  // Whether the service should be running: set at once by start()/stop(),
  // so a stop() that comes while a start() is still waiting on the plugin
  // wins, rather than the start finishing after it.
  bool _wanted = false;
  // start()/stop() run one after another, never interleaved.
  Future<void> _queue = Future.value();

  /// How long a torrent keeps downloading once the app is in the
  /// background: long enough to buffer ahead of a short break, not all
  /// night for a player left open (Android also allows this kind of
  /// service only 6 hours a day).
  static const Duration backgroundLimit = Duration(minutes: 10);
  Timer? _limitTimer;
  // Whether the limit was reached: what's streaming was paused, and is
  // resumed when the app comes back.
  bool _limitReached = false;

  /// Doesn't ask for the notification permission: the player already did
  /// when it started (see PlayerScreen._initMediaSession) — asking here, as
  /// the app goes to the background, put the prompt over the home screen.
  Future<void> start() {
    if (!Platform.isAndroid) return Future.value();
    _limitTimer?.cancel();
    _limitTimer = Timer(backgroundLimit, _onLimit);
    _wanted = true;
    return _queue = _queue.then((_) => _sync());
  }

  /// Safe to call when nothing is running (e.g. at app start). Lets what's
  /// streaming download again if [backgroundLimit] paused it.
  Future<void> stop() {
    if (!Platform.isAndroid) return Future.value();
    _limitTimer?.cancel();
    _limitTimer = null;
    if (_limitReached) {
      _limitReached = false;
      try {
        TorrentEngineService.instance.resumeFromBackground();
      } catch (e) {
        print('Error resuming torrents after the background limit: $e');
      }
    }
    return _stopService();
  }

  /// [backgroundLimit] reached with the app still away: the download
  /// pauses (its stream stays open, so playback carries on when the app
  /// is back) and the service goes, with its wake and Wi-Fi locks.
  void _onLimit() {
    _limitTimer = null;
    _limitReached = true;
    try {
      TorrentEngineService.instance.pauseForBackground();
    } catch (e) {
      print('Error pausing torrents for the background limit: $e');
    }
    _stopService();
  }

  Future<void> _stopService() {
    _wanted = false;
    return _queue = _queue.then((_) => _sync());
  }

  /// Brings the service in line with [_wanted], which is read again after
  /// every wait: it may have changed meanwhile.
  Future<void> _sync() async {
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (_wanted && !running) {
        init();
        await FlutterForegroundTask.startService(
          serviceId: 322,
          notificationTitle: 'Popcorn',
          notificationText: 'Buffering in the background…',
        );
      } else if (!_wanted && running) {
        await FlutterForegroundTask.stopService();
      }
      // A stop() or start() that came during the wait queued its own
      // _sync, which sees the service as it is now.
    } catch (e) {
      print('Error updating the background download service: $e');
    }
  }
}
