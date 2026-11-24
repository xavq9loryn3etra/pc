import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'tv_device.dart';

/// Crash reports, sent to Sentry (the owner's "popcorn" project) from
/// release builds: app crashes (Dart, and native ones in the player and
/// torrent engine), freezes, and errors nothing else caught. Always on:
/// Settings shows it as a switch that can't be turned off.
///
/// What's sent: the error and where in the code, the app version, the
/// device model and system, and the app's last log lines (breadcrumbs),
/// with links, keys, tokens, e-mail addresses and the Windows user name
/// taken out first ([_scrub]). No screenshots, no screen recordings, no
/// speed measurements, no IP address (`sendDefaultPii` off, and the
/// project doesn't store them either).
class CrashReports {
  CrashReports._();

  /// Where reports go. Not a secret: it can only send reports in, never
  /// read them (Sentry's own advice), and every copy of the app carries
  /// it anyway. A build can point elsewhere with
  /// `--dart-define=SENTRY_DSN=...`, or switch reports off with an empty one.
  static const _dsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue: 'https://e574e1b480dd481e7f8bfa40b7dc2e92'
        '@o4512485231886336.ingest.de.sentry.io/4512485256527952',
  );

  /// Release builds only: a debug run on the owner's PC isn't a crash in
  /// someone's hands, and would only fill the free plan's allowance.
  static bool get enabled => kReleaseMode && _dsn.isNotEmpty;

  /// At most this many reports from one run of the app, and each error
  /// once: one broken thing on a loop mustn't use up the month's
  /// allowance (5,000 on the free plan) on its own.
  static const _maxPerRun = 25;
  static int _sentThisRun = 0;
  static final _seenThisRun = <String>{};

  /// Starts reporting. Call once, early in main(), after the app's own
  /// binding exists (Sentry would otherwise create the stock one) and its
  /// own error handlers are set (Sentry passes errors on to them).
  static Future<void> start() async {
    if (!enabled) return;
    try {
      await SentryFlutter.init((options) {
        options.dsn = _dsn;
        options.sendDefaultPii = false;
        // Crashes and freezes only: no speed measurements, no
        // screenshots or screen recordings.
        options.tracesSampleRate = null;
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;
        options.beforeBreadcrumb = _beforeBreadcrumb;
        options.beforeSend = _beforeSend;
      });
    } catch (_) {
      // Reporting must never be the reason the app doesn't start.
    }
  }

  /// An error the app caught and carried on from, worth knowing about
  /// (a startup step that failed, say).
  static void report(Object error, StackTrace? stack, {String? where}) {
    if (!enabled) return;
    unawaited(Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: where == null ? null : (scope) => scope.setTag('where', where),
    ).catchError((_) => const SentryId.empty()));
  }

  static Breadcrumb? _beforeBreadcrumb(Breadcrumb? crumb, Hint hint) {
    if (crumb == null) return null;
    final message = crumb.message;
    if (message != null) crumb.message = _scrub(message);
    final data = crumb.data;
    if (data != null) {
      crumb.data = {
        for (final e in data.entries)
          e.key: e.value is String ? _scrub(e.value as String) : e.value,
      };
    }
    return crumb;
  }

  static SentryEvent? _beforeSend(SentryEvent event, Hint hint) {
    final exceptions = event.exceptions ?? const <SentryException>[];
    // A dropped connection or a missing poster isn't a bug: the app shows
    // its own message, and each one would cost a report.
    if (exceptions.isNotEmpty && exceptions.every(_isNetworkNoise)) {
      return null;
    }

    final first = exceptions.isEmpty ? null : exceptions.first;
    final key = '${first?.type}:${(first?.value ?? event.message?.formatted ?? '').characters120}';
    if (!_seenThisRun.add(key)) return null;
    if (_sentThisRun >= _maxPerRun) return null;
    _sentThisRun++;

    for (final e in exceptions) {
      final value = e.value;
      if (value != null) e.value = _scrub(value);
    }
    final message = event.message;
    if (message != null) message.formatted = _scrub(message.formatted);
    // The computer's own name (Windows): not needed, and it's often the
    // owner's name.
    event.serverName = null;
    event.tags = {
      ...?event.tags,
      'device.kind': TvDevice.isTv ? 'tv' : 'other',
    };
    return event;
  }

  static const _networkTypes = {
    'SocketException',
    'HandshakeException',
    'TlsException',
    'HttpException',
    'HttpExceptionWithStatus',
    'NetworkImageLoadException',
    'ClientException',
    'WebSocketException',
  };

  static bool _isNetworkNoise(SentryException e) {
    final type = e.type ?? '';
    if (_networkTypes.contains(type)) return true;
    if (type == 'DioException') {
      final value = e.value ?? '';
      return RegExp(r'connection|timeout|timed out|network', caseSensitive: false)
          .hasMatch(value);
    }
    return false;
  }

  static final _scrubbers = <(RegExp, String Function(Match))>[
    // Magnet links and torrent hashes.
    (RegExp(r'magnet:\?[^\s"<>]*', caseSensitive: false), (_) => 'magnet:[removed]'),
    (RegExp(r'\b[0-9a-fA-F]{40}\b'), (_) => '[hash]'),
    // Google API keys (Gemini, TMDB-style) and Google sign-in tokens.
    (RegExp(r'AIza[0-9A-Za-z_\-]{30,}'), (_) => '[key]'),
    (RegExp(r'ya29\.[0-9A-Za-z_\-.]+'), (_) => '[token]'),
    (RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false), (_) => 'Bearer [token]'),
    // Keys and tokens in web addresses (TMDB's api_key, and the like).
    (
      RegExp(r'((?:api_key|apikey|key|access_token|refresh_token|id_token|token|code|sig|signature|password|secret)=)[^&\s"<>]+',
          caseSensitive: false),
      (m) => '${m[1]}[removed]'
    ),
    // E-mail addresses.
    (RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'), (_) => '[email]'),
    // The Windows user name in a path.
    (RegExp(r'([\\/]Users[\\/])[^\\/\s"]+', caseSensitive: false), (m) => '${m[1]}[user]'),
  ];

  static String _scrub(String text) {
    var out = text;
    for (final (pattern, replace) in _scrubbers) {
      out = out.replaceAllMapped(pattern, replace);
    }
    return out;
  }
}

extension on String {
  /// The first 120 characters: enough to tell two errors apart.
  String get characters120 => length <= 120 ? this : substring(0, 120);
}
