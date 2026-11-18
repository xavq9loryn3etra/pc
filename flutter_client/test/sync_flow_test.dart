import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/gemini_key_service.dart';
import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:flutter_client/services/sync/drive_store.dart';
import 'package:flutter_client/services/sync/google_link.dart';
import 'package:flutter_client/services/sync/sync_data.dart';
import 'package:flutter_client/services/sync/sync_ledger.dart';
import 'package:flutter_client/services/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Google's sign-in, always fine.
class _FakeLink extends GoogleLink {
  @override
  Future<void> signIn({void Function(DeviceCode code)? onCode, Future<void>? cancel}) async {}

  @override
  Future<String> accessToken({bool refresh = false}) async => 'token';

  @override
  Future<void> signOut() async {}
}

/// The account's hidden folder, in memory.
class _FakeDrive implements DriveStore {
  final files = <String, ({String name, Uint8List bytes, int version, DateTime modified})>{};
  var _next = 0;

  @override
  int? clockOffsetMs = 0;

  @override
  Future<String> Function({bool refresh}) get token => ({bool refresh = false}) async => 'token';

  DriveFile _file(String id) {
    final f = files[id]!;
    return DriveFile(id, f.name, f.modified, '${f.version}');
  }

  @override
  Future<List<DriveFile>> listFiles() async => [for (final id in files.keys) _file(id)];

  @override
  Future<Uint8List> download(String id) async => files[id]!.bytes;

  @override
  Future<SyncData?> readPage(String id) async {
    final f = files[id];
    if (f == null) return null;
    return SyncData.fromJson(
        Map<String, dynamic>.from(_decode(f.bytes) as Map));
  }

  static Object? _decode(Uint8List bytes) =>
      jsonDecode(utf8.decode(gzip.decode(bytes)));

  @override
  Future<DriveFile> save({
    String? id,
    required String name,
    required Uint8List bytes,
    String contentType = 'application/gzip',
  }) async {
    final fileId = id ?? 'f${_next++}';
    final had = files[fileId];
    if (id != null && had == null) throw const SyncException(SyncProblem.other, '404');
    files[fileId] = (
      name: name,
      bytes: bytes,
      version: (had?.version ?? 0) + 1,
      modified: DateTime.now(),
    );
    return _file(fileId);
  }

  @override
  Future<void> delete(String id) async => files.remove(id);

  @override
  Future<String?> accountEmail() async => 'someone@example.com';

  /// Another device's page, as that device would save it.
  void putPage(String device, SyncData page) {
    files['other-$device'] = (
      name: DriveStore.pageName(device),
      bytes: DriveStore.encodePage(page),
      version: (files['other-$device']?.version ?? 0) + 1,
      modified: DateTime.now(),
    );
  }

  Iterable<String> get names => files.values.map((f) => f.name);
}

Movie movie(String id, {String type = 'movie'}) => Movie(
      id: id,
      title: 'Title $id',
      year: 2020,
      rating: '8',
      voteCount: 1,
      description: '',
      type: type,
      inCinemas: false,
    );

Map<String, dynamic> listJson(String id) =>
    {...movie(id).toStorageJson()}..remove('description')..remove('trailer_url');

SyncData pageWith({Map<String, Map<String, dynamic>> list = const {}, int? clearedAt}) =>
    SyncData(items: {'list': list}, clearedAt: clearedAt);

Map<String, dynamic> on(int t, Object v) => {'t': t, 'v': v};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeDrive drive;
  final sync = SyncService();
  final saved = SavedMoviesService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Popcorn',
      packageName: 'com.popcorn.flutter_client',
      version: '4.3.0',
      buildNumber: '66',
      buildSignature: '',
    );
    SyncLedger().reset();
    await SavedMoviesService().init();
    await GeminiKeyService().init();
    drive = _FakeDrive();
    GoogleLink.debugOverride = _FakeLink();
    sync.debugReset();
    sync.debugStore = drive;
    await sync.init();
  });

  tearDown(() {
    GoogleLink.debugOverride = null;
    sync.debugStore = null;
    sync.debugReset();
  });

  List<String> myList() => saved.favorites.map((m) => m.storageKey).toList();

  test('the first device signs in without a question, and saves its page', () async {
    await saved.toggleFavorite(movie('1'));
    await sync.turnOn();
    expect(sync.status.value.on, isTrue);
    expect(sync.status.value.asking, isNull);
    expect(drive.names.where((n) => n.startsWith(DriveStore.pagePrefix)), hasLength(1));
  });

  test('a device with its own titles is asked, and adding them keeps both', () async {
    final t = SyncLedger().now();
    drive.putPage('phone', pageWith(list: {'movie_9': on(t - 100, listJson('9'))}));
    await saved.toggleFavorite(movie('1'));

    await sync.turnOn();
    expect(sync.status.value.asking, (list: 1, history: 0));
    // Nothing syncs while it waits.
    await sync.syncNow(userAsked: true);
    expect(myList(), ['movie_1']);

    await sync.addDeviceLists();
    expect(sync.status.value.asking, isNull);
    expect(myList().toSet(), {'movie_1', 'movie_9'});
  });

  test("removing them shows only the account's lists", () async {
    final t = SyncLedger().now();
    drive.putPage('phone', pageWith(list: {'movie_9': on(t - 100, listJson('9'))}));
    await saved.toggleFavorite(movie('1'));
    await sync.turnOn();
    await sync.keepAccountListsOnly();
    expect(myList(), ['movie_9']);
    // And movie_1 never reaches the account.
    final pages = [
      for (final f in await drive.listFiles())
        if (f.name.startsWith(DriveStore.pagePrefix)) (await drive.readPage(f.id))!,
    ];
    expect(SyncData.merge(pages, now: SyncLedger().now()).live('list').map((e) => e.key),
        isNot(contains('movie_1')));
  });

  test('signing out clears the device; signing in again brings it all back', () async {
    await saved.toggleFavorite(movie('1'));
    await GeminiKeyService().save('AIzaKEY');
    await sync.turnOn();
    expect(await sync.signOut(), isTrue);
    expect(sync.status.value.on, isFalse);
    expect(myList(), isEmpty);
    expect(GeminiKeyService().key.value, isNull);

    // Its own page is still in the account: nothing is asked, it's back.
    await sync.turnOn();
    expect(sync.status.value.asking, isNull);
    expect(myList(), ['movie_1']);
    expect(GeminiKeyService().key.value, 'AIzaKEY');
  });

  test('deleting synced data empties every device, and nobody is signed out', () async {
    final t = SyncLedger().now();
    drive.putPage('phone', pageWith(list: {'movie_9': on(t - 100, listJson('9'))}));
    await saved.toggleFavorite(movie('1'));
    await sync.turnOn();
    await sync.addDeviceLists();
    expect(myList().toSet(), {'movie_1', 'movie_9'});

    await sync.deleteSyncedData();
    expect(sync.status.value.on, isTrue);
    expect(myList(), isEmpty);
    // Only this device's page is left: removals of everything.
    final left = await drive.listFiles();
    expect(left, hasLength(1));
    final page = (await drive.readPage(left.single.id))!;
    expect(page.live('list'), isEmpty);
    expect(page.clearedAt, isNotNull);

    // The phone, not synced since, puts its old copy back: it loses.
    drive.putPage('phone', pageWith(list: {'movie_9': on(t - 100, listJson('9'))}));
    await sync.syncNow(userAsked: true);
    expect(myList(), isEmpty);
    expect(sync.status.value.removedCount, 0);
  });

  test("another device's deletion is taken in without a 'bring back'", () async {
    final t = SyncLedger().now();
    for (var i = 1; i <= 8; i++) {
      await saved.toggleFavorite(movie('$i'));
    }
    await sync.turnOn();
    expect(myList(), hasLength(8));

    // Another device deleted everything, after these were added.
    final wipeAt = SyncLedger().now() + 1000;
    drive.putPage(
      'laptop',
      SyncData.removalOfAll(
          SyncData(items: {'list': {for (var i = 1; i <= 8; i++) 'movie_$i': on(t, listJson('$i'))}}),
          wipeAt),
    );
    final notices = <String>[];
    final sub = sync.notices.listen(notices.add);
    await sync.syncNow(userAsked: true);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(myList(), isEmpty);
    expect(sync.status.value.removedCount, 0);
    expect(notices.single, contains('deleted from another device'));
  });
}
