import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../tv_device.dart';
import 'drive_store.dart';

/// The app's sign-in IDs from Google Cloud, given at build time
/// (--dart-define-from-file=secrets.json; in releases, from the GitHub
/// secrets). The Android phone app needs no ID here — Google knows it by
/// its package name and signing key — just GOOGLE_ANDROID_SYNC=true once
/// that's registered. Where a device's entry is missing, Settings shows no
/// sync at all.
class GoogleSyncConfig {
  static const androidSync = bool.fromEnvironment('GOOGLE_ANDROID_SYNC');
  static const desktopClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
  static const desktopClientSecret =
      String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');
  static const tvClientId = String.fromEnvironment('GOOGLE_TV_CLIENT_ID');
  static const tvClientSecret = String.fromEnvironment('GOOGLE_TV_CLIENT_SECRET');
  static const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
}

/// What a TV shows while it waits: a code to enter at Google's address
/// on a phone or computer.
class DeviceCode {
  final String userCode;
  final String url;
  final DateTime expires;
  const DeviceCode(this.userCode, this.url, this.expires);
}

/// Signing in to Google for sync, the way that suits this device:
/// - phones and iPhone: Google's own sign-in window ([_PluginLink]);
/// - Windows: the browser, which hands back to the app ([_BrowserLink]);
/// - TV: a code entered on a phone at google.com/device ([_CodeLink]).
///
/// Only the hidden-folder access (DriveStore.scope) is asked for.
abstract class GoogleLink {
  static GoogleLink? _forThisDevice;

  /// The one for this device, or null where sync isn't set up (no
  /// sign-in IDs in this build).
  static GoogleLink? forThisDevice() {
    if (_forThisDevice != null) return _forThisDevice;
    GoogleLink? link;
    if (Platform.isAndroid && TvDevice.isTv) {
      if (GoogleSyncConfig.tvClientId.isNotEmpty) link = _CodeLink();
    } else if (Platform.isAndroid) {
      if (GoogleSyncConfig.androidSync) link = _PluginLink();
    } else if (Platform.isIOS) {
      if (GoogleSyncConfig.iosClientId.isNotEmpty) link = _PluginLink();
    } else if (Platform.isWindows) {
      if (GoogleSyncConfig.desktopClientId.isNotEmpty) link = _BrowserLink();
    }
    return _forThisDevice = link;
  }

  /// Whether signing in shows a code to enter elsewhere ([signIn]'s
  /// onCode).
  bool get showsCode => false;

  /// Signs in, asking the viewer. Throws a SyncException
  /// (signInAgain) if it didn't happen — cancelled included. [cancel]
  /// stops waiting.
  Future<void> signIn({
    void Function(DeviceCode code)? onCode,
    Future<void>? cancel,
  });

  /// A token for Drive, without asking the viewer; throws a
  /// SyncException (signInAgain) if they need to sign in again.
  /// [refresh]: the last one was refused.
  Future<String> accessToken({bool refresh = false});

  /// Signs out on this device only. Google's permission for Popcorn is
  /// left alone: dropping it would sign out every other device on the
  /// account too, before they could see sync was turned off. (The viewer
  /// can drop it at myaccount.google.com/permissions.)
  Future<void> signOut();
}

/// Google's own sign-in (google_sign_in): phones, tablets, iPhone.
class _PluginLink extends GoogleLink {
  Future<void>? _ready;
  String? _token;

  Future<void> _init() => _ready ??= () async {
        await GoogleSignIn.instance.initialize(
          clientId: Platform.isIOS ? GoogleSyncConfig.iosClientId : null,
        );
        // iPhone: picks up the earlier sign-in, without showing anything.
        if (Platform.isIOS) {
          try {
            await GoogleSignIn.instance.attemptLightweightAuthentication();
          } catch (_) {}
        }
      }();

  @override
  Future<void> signIn({
    void Function(DeviceCode code)? onCode,
    Future<void>? cancel,
  }) async {
    await _init();
    try {
      final authz = await GoogleSignIn.instance.authorizationClient
          .authorizeScopes(const [DriveStore.scope]);
      _token = authz.accessToken;
    } on GoogleSignInException catch (e) {
      throw SyncException(SyncProblem.signInAgain, '${e.code}: ${e.description}');
    }
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    await _init();
    final client = GoogleSignIn.instance.authorizationClient;
    if (refresh && _token != null) {
      try {
        await client.clearAuthorizationToken(accessToken: _token!);
      } catch (_) {}
      _token = null;
    }
    try {
      final authz = await client.authorizationForScopes(const [DriveStore.scope]);
      if (authz == null) {
        throw const SyncException(SyncProblem.signInAgain, 'not authorized');
      }
      return _token = authz.accessToken;
    } on GoogleSignInException catch (e) {
      throw SyncException(SyncProblem.unreachable, '${e.code}');
    }
  }

  @override
  Future<void> signOut() async {
    _token = null;
    try {
      await _init();
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}

/// Sign-ins that keep a long-lived "refresh token" and trade it for
/// short-lived access tokens: Windows and TV.
abstract class _RefreshTokenLink extends GoogleLink {
  static const _refreshKey = 'sync_google_refresh_token';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';

  String get clientId;
  String get clientSecret;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    // Google's errors come back as JSON with a 4xx: read, not thrown.
    validateStatus: (_) => true,
  ));

  String? _access;
  DateTime _accessExpires = DateTime.fromMillisecondsSinceEpoch(0);

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> form) async {
    try {
      final res = await _dio.post<dynamic>(
        _tokenUrl,
        data: form,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final body = res.data is String ? jsonDecode(res.data as String) : res.data;
      return body is Map<String, dynamic> ? body : {'error': 'bad_response'};
    } on DioException catch (e) {
      throw SyncException(SyncProblem.unreachable, '${e.type}');
    }
  }

  /// Keeps what Google gave on sign-in.
  Future<void> _keep(Map<String, dynamic> tokens) async {
    final refresh = tokens['refresh_token'];
    final access = tokens['access_token'];
    if (refresh is! String || access is! String) {
      throw SyncException(SyncProblem.signInAgain, '${tokens['error'] ?? 'no token'}');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_refreshKey, refresh);
    _setAccess(tokens);
  }

  void _setAccess(Map<String, dynamic> tokens) {
    _access = tokens['access_token'] as String;
    final seconds = tokens['expires_in'];
    _accessExpires = DateTime.now().add(Duration(
        seconds: (seconds is num ? seconds.toInt() : 3600) - 120));
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    if (!refresh && _access != null && DateTime.now().isBefore(_accessExpires)) {
      return _access!;
    }
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString(_refreshKey);
    if (refreshToken == null) {
      throw const SyncException(SyncProblem.signInAgain, 'no refresh token');
    }
    final res = await _tokenRequest({
      'client_id': clientId,
      'client_secret': clientSecret,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    });
    if (res['access_token'] is String) {
      _setAccess(res);
      return _access!;
    }
    // Access removed, password changed, or unused for six months.
    if (res['error'] == 'invalid_grant' || res['error'] == 'unauthorized_client') {
      throw SyncException(SyncProblem.signInAgain, '${res['error']}');
    }
    throw SyncException(SyncProblem.unreachable, '${res['error']}');
  }

  @override
  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_refreshKey);
    _access = null;
  }
}

/// Windows: Google's sign-in page in the browser, which sends the viewer
/// back to a one-time address on this computer (127.0.0.1) that only
/// Popcorn is listening on — "loopback" sign-in, with PKCE so the code
/// is useless to anyone who sees it.
class _BrowserLink extends _RefreshTokenLink {
  @override
  String get clientId => GoogleSyncConfig.desktopClientId;
  @override
  String get clientSecret => GoogleSyncConfig.desktopClientSecret;

  @override
  Future<void> signIn({
    void Function(DeviceCode code)? onCode,
    Future<void>? cancel,
  }) async {
    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(24);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final done = Completer<String>();
    cancel?.then((_) {
      if (!done.isCompleted) {
        done.completeError(const SyncException(SyncProblem.signInAgain, 'cancelled'));
      }
    });

    server.listen((request) async {
      final params = request.uri.queryParameters;
      if (params['state'] != state) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final code = params['code'];
      final ok = code != null;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_browserPage(ok));
      await request.response.close();
      if (done.isCompleted) return;
      if (ok) {
        done.complete(code);
      } else {
        done.completeError(SyncException(
            SyncProblem.signInAgain, params['error'] ?? 'no code'));
      }
    });

    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': DriveStore.scope,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      // A refresh token every time, so a second sign-in still gets one.
      'access_type': 'offline',
      'prompt': 'consent',
    });

    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const SyncException(SyncProblem.other, "couldn't open the browser");
      }
      final code = await done.future.timeout(const Duration(minutes: 10),
          onTimeout: () =>
              throw const SyncException(SyncProblem.signInAgain, 'timed out'));
      final tokens = await _tokenRequest({
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'code_verifier': verifier,
        'grant_type': 'authorization_code',
        'redirect_uri': redirect,
      });
      await _keep(tokens);
    } finally {
      await server.close(force: true);
      // Back from the browser to Popcorn.
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }

  static String _browserPage(bool ok) => '''<!doctype html>
<html><head><meta charset="utf-8"><title>Popcorn</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#0b0b0c;color:#f2efe8;font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
  main{max-width:420px;padding:24px;text-align:center}
  h1{font-size:22px;margin:0 0 8px}
  p{margin:0;color:#a9a59c}
</style></head><body><main>
${ok ? '<h1>You\'re signed in</h1><p>You can close this tab and go back to Popcorn.</p>' : '<h1>Sign-in didn\'t finish</h1><p>Close this tab and try again from Popcorn\'s Settings.</p>'}
</main></body></html>''';
}

/// TV: Google's sign-in for devices without a keyboard. The TV shows a
/// short code; the viewer enters it at google.com/device on their phone,
/// signs in there, and the TV, asking Google every few seconds, is let in.
class _CodeLink extends _RefreshTokenLink {
  @override
  String get clientId => GoogleSyncConfig.tvClientId;
  @override
  String get clientSecret => GoogleSyncConfig.tvClientSecret;

  @override
  bool get showsCode => true;

  @override
  Future<void> signIn({
    void Function(DeviceCode code)? onCode,
    Future<void>? cancel,
  }) async {
    var cancelled = false;
    cancel?.then((_) => cancelled = true);

    final Map<String, dynamic> start;
    try {
      final res = await _dio.post<dynamic>(
        'https://oauth2.googleapis.com/device/code',
        data: {'client_id': clientId, 'scope': DriveStore.scope},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final body = res.data is String ? jsonDecode(res.data as String) : res.data;
      start = body is Map<String, dynamic> ? body : const {};
    } on DioException catch (e) {
      throw SyncException(SyncProblem.unreachable, '${e.type}');
    }
    final deviceCode = start['device_code'];
    final userCode = start['user_code'];
    if (deviceCode is! String || userCode is! String) {
      throw SyncException(SyncProblem.other, '${start['error'] ?? 'no code'}');
    }
    final expiresIn = start['expires_in'] is num ? (start['expires_in'] as num).toInt() : 1800;
    var interval = start['interval'] is num ? (start['interval'] as num).toInt() : 5;
    final expires = DateTime.now().add(Duration(seconds: expiresIn));
    onCode?.call(DeviceCode(
      userCode,
      '${start['verification_url'] ?? 'https://www.google.com/device'}',
      expires,
    ));

    while (!cancelled && DateTime.now().isBefore(expires)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (cancelled) break;
      final Map<String, dynamic> res;
      try {
        res = await _tokenRequest({
          'client_id': clientId,
          'client_secret': clientSecret,
          'device_code': deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        });
      } on SyncException {
        continue; // A dropped connection: ask again.
      }
      if (res['access_token'] is String) {
        await _keep(res);
        return;
      }
      switch (res['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += 5;
          continue;
        case 'access_denied':
          throw const SyncException(SyncProblem.signInAgain, 'access_denied');
        default:
          throw SyncException(SyncProblem.signInAgain, '${res['error']}');
      }
    }
    throw SyncException(
        SyncProblem.signInAgain, cancelled ? 'cancelled' : 'code expired');
  }
}

String _randomString(int length) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final r = Random.secure();
  return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
}
