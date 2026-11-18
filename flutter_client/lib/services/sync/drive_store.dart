import 'dart:convert';
import 'dart:io' show GZipCodec, HttpDate, gzip;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'sync_data.dart';

/// Why a sync couldn't finish — what Settings tells the viewer.
enum SyncProblem {
  /// Google needs the viewer to sign in again (access removed, password
  /// changed, or the sign-in expired).
  signInAgain,

  /// The viewer's Google storage is full: nothing more can be saved there.
  driveFull,

  /// No connection, or Google didn't answer: tried again later.
  unreachable,

  /// Another device runs a newer Popcorn: this one reads but doesn't
  /// write until it's updated.
  needsUpdate,

  /// Turned off for now from the website's flags (a problem being fixed).
  pausedRemotely,

  /// Something else went wrong: tried again later.
  other,
}

class SyncException implements Exception {
  final SyncProblem problem;
  final String detail;
  const SyncException(this.problem, [this.detail = '']);

  @override
  String toString() => 'SyncException($problem${detail.isEmpty ? '' : ': $detail'})';
}

/// A file in the app's hidden folder in the viewer's Drive.
class DriveFile {
  final String id;
  final String name;
  final DateTime modified;

  /// Goes up every time the file changes.
  final String version;

  const DriveFile(this.id, this.name, this.modified, this.version);

  factory DriveFile.fromJson(Map<String, dynamic> json) => DriveFile(
        json['id'] as String,
        json['name'] as String? ?? '',
        DateTime.tryParse(json['modifiedTime'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        '${json['version'] ?? ''}',
      );
}

/// The viewer's hidden Popcorn folder in Google Drive (the "app data"
/// folder: only Popcorn can see it, and it doesn't show in their Drive).
/// Each device's page is a file there; see SyncService.
class DriveStore {
  /// The access Popcorn asks Google for: its own hidden folder, nothing
  /// else in the viewer's Drive.
  static const String scope = 'https://www.googleapis.com/auth/drive.appdata';

  static const String pagePrefix = 'popcorn-device-';
  static const String pageSuffix = '.json.gz';

  /// Written by Popcorn 4.2.0 when synced data was deleted (it turned
  /// sync off on the other devices). No longer used: deleting synced data
  /// now leaves removals instead, and this goes with the rest.
  static const String controlName = 'popcorn-control.json';

  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';
  static const _fileFields = 'id,name,modifiedTime,version';

  /// A current access token; [refresh] asks for a new one (the last was
  /// refused).
  final Future<String> Function({bool refresh}) token;

  final Dio _dio;

  /// How far this device's clock is behind Google's, in ms, as of the
  /// last answer.
  int? clockOffsetMs;

  DriveStore(this.token, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
            ));

  static String pageName(String deviceId) => '$pagePrefix$deviceId$pageSuffix';

  /// Every file in the hidden folder.
  Future<List<DriveFile>> listFiles() async {
    final files = <DriveFile>[];
    String? pageToken;
    do {
      final res = await _send<Map<String, dynamic>>((auth) => _dio.get(
            '$_api/files',
            queryParameters: {
              'spaces': 'appDataFolder',
              'fields': 'nextPageToken,files($_fileFields)',
              'pageSize': 1000,
              if (pageToken != null) 'pageToken': pageToken,
            },
            options: Options(headers: auth),
          ));
      for (final f in (res['files'] as List? ?? const [])) {
        if (f is Map<String, dynamic>) files.add(DriveFile.fromJson(f));
      }
      pageToken = res['nextPageToken'] as String?;
    } while (pageToken != null);
    return files;
  }

  Future<Uint8List> download(String id) => _send<Uint8List>((auth) => _dio.get(
        '$_api/files/$id',
        queryParameters: {'alt': 'media'},
        options: Options(headers: auth, responseType: ResponseType.bytes),
      ));

  /// A device's page, read; null if it can't be.
  Future<SyncData?> readPage(String id) async {
    final bytes = await download(id);
    try {
      final json = jsonDecode(utf8.decode(gzip.decode(bytes)));
      return json is Map<String, dynamic> ? SyncData.fromJson(json) : null;
    } catch (_) {
      return null;
    }
  }

  /// Compressed as small as it goes: a page is written now and then, and
  /// read on every device.
  static Uint8List encodePage(SyncData data) => Uint8List.fromList(
      GZipCodec(level: 9).encode(utf8.encode(jsonEncode(data.toJson()))));

  /// Saves [bytes] as [name]: over [id] if given, else as a new file.
  Future<DriveFile> save({
    String? id,
    required String name,
    required Uint8List bytes,
    String contentType = 'application/gzip',
  }) async {
    if (id != null) {
      final json = await _send<Map<String, dynamic>>((auth) => _dio.patch(
            '$_upload/files/$id',
            queryParameters: {'uploadType': 'media', 'fields': _fileFields},
            data: Stream.fromIterable([bytes]),
            options: Options(headers: {
              ...auth,
              Headers.contentTypeHeader: contentType,
              Headers.contentLengthHeader: bytes.length,
            }),
          ));
      return DriveFile.fromJson(json);
    }
    const boundary = 'popcorn-sync-boundary';
    final meta = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
    });
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$meta\r\n'
          '--$boundary\r\n'
          'Content-Type: $contentType\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    final all = body.takeBytes();
    final json = await _send<Map<String, dynamic>>((auth) => _dio.post(
          '$_upload/files',
          queryParameters: {'uploadType': 'multipart', 'fields': _fileFields},
          data: Stream.fromIterable([all]),
          options: Options(headers: {
            ...auth,
            Headers.contentTypeHeader: 'multipart/related; boundary=$boundary',
            Headers.contentLengthHeader: all.length,
          }),
        ));
    return DriveFile.fromJson(json);
  }

  Future<void> delete(String id) async {
    try {
      await _send<dynamic>((auth) => _dio.delete(
            '$_api/files/$id',
            options: Options(headers: auth),
          ));
    } on SyncException catch (e) {
      // Already gone is fine.
      if (e.detail != '404') rethrow;
    }
  }

  /// The signed-in account's email, if Google says.
  Future<String?> accountEmail() async {
    try {
      final res = await _send<Map<String, dynamic>>((auth) => _dio.get(
            '$_api/about',
            queryParameters: {'fields': 'user(emailAddress)'},
            options: Options(headers: auth),
          ));
      final user = res['user'];
      return user is Map ? user['emailAddress'] as String? : null;
    } on SyncException catch (e) {
      if (e.problem == SyncProblem.signInAgain) rethrow;
      return null;
    }
  }

  /// Sends a request with a token, once more with a new one if it was
  /// refused, and turns Google's answer into data or a SyncException.
  Future<T> _send<T>(
      Future<Response<dynamic>> Function(Map<String, String> auth) request) async {
    for (var attempt = 0;; attempt++) {
      final t = await token(refresh: attempt > 0);
      try {
        final res = await request({'Authorization': 'Bearer $t'});
        _noteClock(res.headers);
        return res.data as T;
      } on DioException catch (e) {
        final res = e.response;
        if (res == null) {
          throw SyncException(SyncProblem.unreachable, '${e.type}');
        }
        _noteClock(res.headers);
        final status = res.statusCode ?? 0;
        if (status == 401 && attempt == 0) continue;
        throw _problemFor(status, res.data);
      }
    }
  }

  void _noteClock(Headers headers) {
    final date = headers.value('date');
    if (date == null) return;
    try {
      final server = HttpDate.parse(date).millisecondsSinceEpoch;
      clockOffsetMs = server - DateTime.now().millisecondsSinceEpoch;
    } catch (_) {}
  }

  static SyncException _problemFor(int status, Object? body) {
    String reason = '';
    try {
      Object? json;
      if (body is Map) {
        json = body;
      } else if (body is List<int>) {
        json = jsonDecode(utf8.decode(body));
      } else if (body is String) {
        json = jsonDecode(body);
      }
      final error = (json is Map) ? json['error'] : null;
      final errors = (error is Map) ? error['errors'] : null;
      if (errors is List && errors.isNotEmpty && errors.first is Map) {
        reason = '${(errors.first as Map)['reason'] ?? ''}';
      }
    } catch (_) {}
    if (status == 401) return const SyncException(SyncProblem.signInAgain, '401');
    if (status == 403 && reason == 'storageQuotaExceeded') {
      return const SyncException(SyncProblem.driveFull);
    }
    if (status == 403 &&
        (reason == 'insufficientPermissions' || reason == 'appNotAuthorizedToFile')) {
      return SyncException(SyncProblem.signInAgain, reason);
    }
    if (status == 404) return const SyncException(SyncProblem.other, '404');
    if (status == 429 || status == 403 || status >= 500) {
      return SyncException(SyncProblem.unreachable, '$status $reason');
    }
    return SyncException(SyncProblem.other, '$status $reason');
  }
}
