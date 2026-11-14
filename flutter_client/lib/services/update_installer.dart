import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'tv_device.dart';

/// Updates the app from the update screen, without the round trip through
/// the website: downloads the latest release and starts installing it.
///
/// - Windows: the installer runs silently, closes Popcorn and opens the new
///   version (see windows/installer/popcorn.iss, `/relaunch=yes`).
/// - Android: hands the APK to Android's own installer, which asks "Update
///   this app?" — no app outside the Play Store may skip that. The first
///   time, Android also wants Popcorn allowed to install apps
///   ([canInstall], [openInstallPermission]).
/// - iPhone: not here; it updates through TestFlight.
class UpdateInstaller {
  UpdateInstaller._();

  /// The latest release's files, at the same address every release (see
  /// .github/workflows/publish-release.yml). The app only asks for an
  /// update once that release is out (docs/flags.json is changed after it).
  static const _latest =
      'https://github.com/popcorn-organization/popcorn/releases/latest/download';

  static const _channel = MethodChannel('popcorn/device');

  static bool get supported => Platform.isAndroid || Platform.isWindows;

  static String get _fileName {
    if (!Platform.isAndroid) return 'Popcorn-Windows-Setup.exe';
    // TVs get the download that also runs on 32-bit sticks; so does anything
    // already running the 32-bit app (it couldn't run the phone download).
    if (TvDevice.isTv || Abi.current() == Abi.androidArm) {
      return 'Popcorn-Android-TV.apk';
    }
    return 'Popcorn-Android.apk';
  }

  static Future<Directory> _folder() async {
    final temp = await getTemporaryDirectory();
    return Directory('${temp.path}${Platform.pathSeparator}updates');
  }

  /// Removes an update downloaded before — installed by now, or given up
  /// on. Run at startup.
  static Future<void> cleanUp() async {
    if (!supported) return;
    try {
      final folder = await _folder();
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (_) {
      // The Windows installer can still be running just after an update;
      // it's cleared next time.
    }
  }

  /// Downloads the latest release's file for this device, reporting
  /// [onProgress] from 0 to 1.
  static Future<File> download({
    required void Function(double progress) onProgress,
    CancelToken? cancelToken,
  }) async {
    final folder = await _folder();
    await folder.create(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}$_fileName');
    // Under another name until it's whole, so a broken download is never
    // taken for the update.
    final partial = File('${file.path}.part');
    await Dio().download(
      '$_latest/$_fileName',
      partial.path,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
      options: Options(receiveTimeout: const Duration(minutes: 2)),
    );
    // Anything this small is an error page, not the app.
    if (await partial.length() < 1024 * 1024) {
      throw const FileSystemException('The download was incomplete');
    }
    if (await file.exists()) await file.delete();
    return partial.rename(file.path);
  }

  /// Android: whether Popcorn may install apps (Android 8+ asks the user
  /// once, in Settings).
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('canInstallPackages') ?? true;
  }

  /// Android: opens the Settings page that allows Popcorn to install apps.
  static Future<void> openInstallPermission() =>
      _channel.invokeMethod<void>('openInstallPermission');

  /// Starts installing [file]. On Windows, Popcorn closes here: the
  /// installer replaces it and opens the new version.
  static Future<void> install(File file) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('installApk', {'path': file.path});
      return;
    }
    await Process.start(
      file.path,
      [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/relaunch=yes',
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
