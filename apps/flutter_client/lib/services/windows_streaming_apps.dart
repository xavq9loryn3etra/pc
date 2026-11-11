import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One streaming service's app as installed from the Microsoft Store as a
/// web app run by Edge (Netflix's Windows app is one): its Edge app ID,
/// the Edge profile it lives in, and the site it opens.
class _WebApp {
  final String appId;
  final String profile;
  final String host;

  const _WebApp(this.appId, this.profile, this.host);
}

/// Opens a streaming title in the service's Windows app.
///
/// On a phone the services' apps claim their web links (netflix.com/...),
/// so the link opens in the app. On Windows nothing claims them: the link
/// went to the browser. Many of the services' Windows apps (Netflix's,
/// for one) are the website in an Edge app window, though, and Edge can
/// open a link inside that window — so this finds those apps and does
/// that. Never falls back to a browser.
class WindowsStreamingApps {
  static final WindowsStreamingApps _instance = WindowsStreamingApps._();
  factory WindowsStreamingApps() => _instance;
  WindowsStreamingApps._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  Future<({String? edge, List<_WebApp> apps})>? _scan;

  /// Starts looking up the installed apps (a few seconds), so it's done
  /// before a "watch on" button is tapped. Once per run.
  void warmUp() {
    if (supported) _scan ??= _findApps();
  }

  /// Opens [url] in the installed app for its site. False when there's no
  /// such app (or it couldn't be started) — then nothing opens.
  Future<bool> open(String url) async {
    if (!supported) return false;
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return false;
    warmUp();
    final found = await _scan!;
    final edge = found.edge;
    if (edge == null) return false;
    final site = _baseDomain(host);
    final app = found.apps.where((a) => _baseDomain(a.host) == site);
    if (app.isEmpty) return false;
    try {
      await Process.start(
        edge,
        [
          '--app-id=${app.first.appId}',
          '--profile-directory=${app.first.profile}',
          // Opens the app's window at this page rather than its home.
          '--app-launch-url-for-shortcuts-menu-item=$url',
        ],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e) {
      debugPrint('Could not start the app for $host: $e');
      return false;
    }
  }

  /// "www.netflix.com" and "netflix.com" alike → "netflix.com".
  static String _baseDomain(String host) {
    final parts = host.toLowerCase().split('.');
    return parts.length <= 2
        ? parts.join('.')
        : parts.sublist(parts.length - 2).join('.');
  }

  // Reads each installed Store app's manifest for an Edge web app's ID,
  // profile and start page, and Edge's location. Prints them as JSON.
  static const _script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$edge = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe').'(default)'
$apps = @(Get-AppxPackage | ForEach-Object {
  $f = Join-Path $_.InstallLocation 'AppxManifest.xml'
  if (Test-Path $f) {
    $t = [IO.File]::ReadAllText($f)
    if ($t -match '--app-id=(\w+)') {
      $id = $Matches[1]
      $prof = 'Default'; if ($t -match 'profile-directory\?([^;"]+)') { $prof = $Matches[1] }
      $start = ''
      if ($t -match 'start-url\?([^;"]+)') { $start = $Matches[1] }
      elseif ($t -match '--app-fallback-url=([^\s"]+)') { $start = $Matches[1] }
      [pscustomobject]@{ appId = $id; profile = $prof; startUrl = $start }
    }
  }
})
ConvertTo-Json -Compress -Depth 3 @{ edge = $edge; apps = $apps }
''';

  static Future<({String? edge, List<_WebApp> apps})> _findApps() async {
    const none = (edge: null, apps: <_WebApp>[]);
    try {
      // Passed encoded so its quotes and line breaks arrive intact.
      final encoded = base64.encode(
        _script.codeUnits.expand((c) => [c & 0xff, c >> 8]).toList(),
      );
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        encoded,
      ]).timeout(const Duration(seconds: 20));
      // Just the JSON line: PowerShell can add progress notes around it.
      final line = const LineSplitter()
          .convert(result.stdout as String)
          .map((l) => l.trim())
          .lastWhere((l) => l.startsWith('{'), orElse: () => '');
      if (line.isEmpty) return none;
      final json = jsonDecode(line);
      if (json is! Map) return none;
      var edge = json['edge'] as String?;
      if (edge != null && !File(edge).existsSync()) edge = null;
      final raw = json['apps'];
      final apps = <_WebApp>[
        for (final a in raw is List ? raw : [raw])
          if (a is Map)
            if (Uri.tryParse(a['startUrl'] as String? ?? '')?.host
                case final host? when host.isNotEmpty)
              _WebApp(a['appId'] as String, a['profile'] as String? ?? 'Default',
                  host),
      ];
      return (edge: edge, apps: apps);
    } catch (e) {
      debugPrint('Could not look up installed streaming apps: $e');
      return none;
    }
  }
}
