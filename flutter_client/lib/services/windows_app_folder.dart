import 'dart:async';
import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:webview_windows/webview_windows.dart';

/// On Windows, what the app saves — the videos it streams, above all — goes
/// in a `data` folder beside Popcorn.exe, so it fills the drive the app was
/// installed on rather than C:, and uninstalling removes it with the app
/// (see windows/installer/popcorn.iss, [UninstallDelete]).
///
/// It works by pointing path_provider's app-support and temp folders there,
/// so the torrents folder (TorrentPaths), the image cache and the rest
/// follow without each needing to know. The settings stay in AppData:
/// shared_preferences finds its folder on its own, and keeping them there
/// carries them over from versions before this.
///
/// Where the install folder can't be written to, everything stays in the
/// usual Windows folders.
class WindowsAppFolder {
  WindowsAppFolder._();

  static String? _dataDir;
  static PathProviderPlatform? _windowsDefaults;

  /// The `data` folder beside Popcorn.exe, or null when it isn't in use.
  static String? get dataDir => _dataDir;

  /// The folder holding the settings file — AppData's, wherever [dataDir]
  /// is (see the class notes).
  static Future<String?> settingsDir() =>
      (_windowsDefaults ?? PathProviderPlatform.instance)
          .getApplicationSupportPath();

  /// Run first thing at startup, before anything asks path_provider for a
  /// folder.
  static void init() {
    if (!Platform.isWindows) return;
    final dir = _writableDataDir();
    if (dir == null) return;
    _dataDir = dir;
    final defaults = PathProviderPlatform.instance;
    _windowsDefaults = defaults;
    PathProviderPlatform.instance = _InstallFolderPaths(defaults, dir);
    unawaited(_removeOldCopies(defaults));
  }

  static String? _writableDataDir() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final dir = Directory('$exeDir${Platform.pathSeparator}data');
      dir.createSync(recursive: true);
      final probe = File('${dir.path}${Platform.pathSeparator}.write_test');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return dir.path;
    } catch (e) {
      print('Install folder not writable, keeping data in AppData: $e');
      return null;
    }
  }

  static Future<void>? _webView;

  /// Points the embedded browser's own files (cookies, its cache) into
  /// [dataDir] too. Once, before the first WebviewController is made.
  static Future<void> prepareWebView() => _webView ??= () async {
        final dir = _dataDir;
        if (dir == null) return;
        try {
          await WebviewController.initializeEnvironment(
              userDataPath: '$dir${Platform.pathSeparator}webview');
        } catch (e) {
          print('Error setting the web view folder: $e');
        }
      }();

  /// What versions before this left on C: — old downloads, caches and the
  /// embedded browser's files — removed, now that they live in [dataDir].
  /// All of it is fetched again when needed. The settings stay.
  static Future<void> _removeOldCopies(PathProviderPlatform defaults) async {
    final sep = Platform.pathSeparator;
    Future<void> remove(FileSystemEntity e) async {
      try {
        if (await e.exists()) await e.delete(recursive: true);
      } catch (err) {
        print('Error removing ${e.path}: $err');
      }
    }

    try {
      final support = await defaults.getApplicationSupportPath();
      if (support != null && support != _dataDir) {
        await remove(Directory('$support${sep}torrents'));
        await remove(File('$support${sep}engine_state.dat'));
        await remove(File('$support${sep}libCachedImageData.json'));
      }

      final temp = await defaults.getTemporaryPath();
      if (temp != null) {
        await remove(Directory('$temp${sep}libCachedImageData'));
        final leftovers = RegExp(
            r'^(popcorn_sub_.*|poster_\d+\.jpg|current_book\.epub)$');
        await for (final f in Directory(temp).list(followLinks: false)) {
          final name = f.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
          if (f is File && leftovers.hasMatch(name)) await remove(f);
        }
      }

      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        final exeName = File(Platform.resolvedExecutable)
            .uri
            .pathSegments
            .last
            .replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
        final webviews = Directory('$localAppData${sep}flutter_webview_windows');
        await remove(Directory('${webviews.path}$sep$exeName'));
        try {
          if (await webviews.exists() && await webviews.list().isEmpty) {
            await webviews.delete();
          }
        } catch (_) {}
      }
    } catch (e) {
      print('Error removing old app files: $e');
    }
  }
}

/// path_provider on Windows, with the app-support and temp folders in the
/// install folder's `data` (see [WindowsAppFolder]).
class _InstallFolderPaths extends PathProviderPlatform {
  _InstallFolderPaths(this._defaults, this._dataDir);

  final PathProviderPlatform _defaults;
  final String _dataDir;

  String _make(String name) {
    final dir = Directory('$_dataDir${Platform.pathSeparator}$name');
    dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async => _dataDir;

  @override
  Future<String?> getTemporaryPath() async => _make('temp');

  @override
  Future<String?> getApplicationCachePath() async => _make('cache');

  @override
  Future<String?> getApplicationDocumentsPath() =>
      _defaults.getApplicationDocumentsPath();

  @override
  Future<String?> getDownloadsPath() => _defaults.getDownloadsPath();

  @override
  Future<String?> getLibraryPath() => _defaults.getLibraryPath();

  @override
  Future<String?> getExternalStoragePath() =>
      _defaults.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() =>
      _defaults.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _defaults.getExternalStoragePaths(type: type);
}
