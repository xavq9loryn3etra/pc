import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../feature_flags_service.dart';
import 'drive_store.dart';
import 'google_link.dart';
import 'sync_bridge.dart';
import 'sync_data.dart';
import 'sync_ledger.dart';
import 'sync_snapshots.dart';

/// What Settings shows about sync.
@immutable
class SyncStatus {
  final bool on;

  /// A sync is running.
  final bool busy;

  /// The Google account synced with, once known.
  final String? email;

  final DateTime? lastSynced;

  /// Why the last sync didn't finish (or, for needsUpdate, didn't save).
  final SyncProblem? problem;

  /// Titles the last big removal took (0: none to undo).
  final int removedCount;

  const SyncStatus({
    this.on = false,
    this.busy = false,
    this.email,
    this.lastSynced,
    this.problem,
    this.removedCount = 0,
  });

  SyncStatus copyWith({
    bool? on,
    bool? busy,
    String? email,
    DateTime? lastSynced,
    SyncProblem? Function()? problem,
    int? removedCount,
  }) =>
      SyncStatus(
        on: on ?? this.on,
        busy: busy ?? this.busy,
        email: email ?? this.email,
        lastSynced: lastSynced ?? this.lastSynced,
        problem: problem != null ? problem() : this.problem,
        removedCount: removedCount ?? this.removedCount,
      );
}

/// Keeps My List, Continue Watching, episode progress and language choices
/// the same on every device signed in to the same Google account.
///
/// Each device writes its own page (SyncData) to the account's hidden
/// Popcorn folder in Drive (DriveStore), and never anyone else's; a sync
/// reads every page that changed since last time, combines them with this
/// device's lists, puts the result in place here, and saves it as this
/// device's page. No server: the app talks to Google directly.
///
/// When — only when there's a reason, never on a timer:
/// - what changed here goes out: My List and language choices at once, watch progress at most every two minutes while
///   playing, and anything left as the app goes to the background;
/// - what the other devices changed comes in when it's about to be seen:
///   as the app opens or comes back, and on opening Home, My List or
///   Settings.
/// Failures wait longer each time (up to half an hour) and never get in
/// the way of the app.
///
/// Safeguards:
/// - a sync that would remove many titles at once still does — the other
///   device asked for it — but keeps a copy from right before and says so,
///   with "Undo" in Settings;
/// - a page from a newer app version is read but this device stops
///   writing until it's updated;
/// - the website's flags can pause sync everywhere, or for one version
///   (FeatureFlagsService);
/// - "Delete synced data" leaves a note in the folder that turns sync off
///   on the other devices, rather than them putting their copies back.
class SyncService {
  static final SyncService _instance = SyncService._();
  factory SyncService() => _instance;
  SyncService._();

  static const _onKey = 'sync_on';
  static const _emailKey = 'sync_email';
  static const _deviceKey = 'sync_device_id';
  static const _pageIdKey = 'sync_page_id';
  static const _lastKey = 'sync_last_synced';
  static const _signedInKey = 'sync_signed_in_at';
  static const _seenKey = 'sync_seen_versions';
  static const _hashKey = 'sync_uploaded_hash';
  static const _removalKey = 'sync_removal';
  static const _lastErrorKey = 'sync_last_error';

  static const _afterChange = Duration(seconds: 30);
  /// My List and language changes go out at once; a tap made while one's
  /// going out goes in the sync right after it.
  static const _afterListChange = Duration.zero;
  static const _minSpacing = Duration(minutes: 2);
  static const _maxBackoff = Duration(minutes: 30);

  /// Removing at least this many titles, and a quarter of them, at once
  /// counts as a big removal.
  static const _bigRemoval = 5;

  static const _pageLife = Duration(days: 180);

  final ValueNotifier<SyncStatus> status = ValueNotifier(const SyncStatus());

  final _notices = StreamController<String>.broadcast();

  /// Things to tell the viewer as they happen (shown as a message).
  Stream<String> get notices => _notices.stream;

  /// Whether this build can sync on this device.
  bool get available => GoogleLink.forThisDevice() != null;

  /// Whether signing in here shows a code to enter on a phone (TV).
  bool get signsInWithCode => GoogleLink.forThisDevice()?.showsCode ?? false;

  DriveStore? _store;
  Timer? _timer;
  DateTime? _timerAt;
  Future<void>? _running;
  bool _again = false;
  int _failures = 0;
  DateTime? _retryAfter;
  DateTime? _lastAttempt;
  int _syncedGeneration = -1;

  DriveStore _storeFor(GoogleLink link) =>
      _store ??= DriveStore(({bool refresh = false}) => link.accessToken(refresh: refresh));

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final on = (prefs.getBool(_onKey) ?? false) && available;
    final last = prefs.getInt(_lastKey);
    status.value = SyncStatus(
      on: on,
      email: prefs.getString(_emailKey),
      lastSynced: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      removedCount: _removalCount(prefs),
    );
    SyncLedger().onChange = _onLocalChange;
    if (on) {
      _schedule(const Duration(seconds: 4));
    }
  }

  static int _removalCount(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_removalKey);
      if (raw == null) return 0;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(json['at'] as int);
      // Undo is offered for a week, as long as the copies are kept.
      if (DateTime.now().difference(at) > const Duration(days: SyncSnapshots.undoDays)) {
        return 0;
      }
      return json['count'] as int;
    } catch (_) {
      return 0;
    }
  }

  // --- Turning it on and off ---

  /// Signs in and starts syncing: what's here and what's in the account
  /// are combined, so nothing is lost on either side. On a TV, [onCode]
  /// gets the code to show. Throws a SyncException if signing in didn't
  /// happen.
  Future<void> turnOn({
    void Function(DeviceCode code)? onCode,
    Future<void>? cancel,
  }) async {
    final link = GoogleLink.forThisDevice();
    if (link == null) throw const SyncException(SyncProblem.other, 'not set up');
    await link.signIn(onCode: onCode, cancel: cancel);
    _store = null;
    final store = _storeFor(link);
    final email = await store.accountEmail();
    final offset = store.clockOffsetMs;
    if (offset != null) await SyncLedger().setOffset(offset);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onKey, true);
    if (email != null) await prefs.setString(_emailKey, email);
    await prefs.setInt(_signedInKey, SyncLedger().now());
    // Possibly another account: everything there is read afresh.
    await prefs.remove(_seenKey);
    await prefs.remove(_hashKey);
    await prefs.remove(_pageIdKey);
    _failures = 0;
    _retryAfter = null;
    status.value = status.value.copyWith(on: true, email: email, problem: () => null);
    await syncNow(userAsked: true);
  }

  /// Stops syncing on this device and signs out. The lists here stay as
  /// they are, and so does what's in the account.
  Future<void> turnOff() async {
    _timer?.cancel();
    _timer = null;
    try {
      await GoogleLink.forThisDevice()?.signOut();
    } catch (_) {}
    _store = null;
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_onKey, _emailKey, _pageIdKey, _lastKey, _signedInKey, _seenKey, _hashKey]) {
      await prefs.remove(key);
    }
    status.value = SyncStatus(removedCount: status.value.removedCount);
  }

  /// Deletes everything synced from the account, turns sync off here, and
  /// leaves a note that turns it off on the other devices too (their own
  /// lists stay). The lists on this device stay.
  Future<void> deleteSyncedData() async {
    final link = GoogleLink.forThisDevice();
    if (link == null) return;
    final store = _storeFor(link);
    final files = await store.listFiles();
    DriveFile? control;
    for (final f in files) {
      if (f.name == DriveStore.controlName) control = f;
    }
    await store.save(
      id: control?.id,
      name: DriveStore.controlName,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode({'stopped_at': SyncLedger().now()}))),
      contentType: 'application/json',
    );
    for (final f in files) {
      if (f.name != DriveStore.controlName) await store.delete(f.id);
    }
    await turnOff();
  }

  // --- When to sync ---

  void _schedule(Duration after) {
    if (!status.value.on) return;
    final at = DateTime.now().add(after);
    final retry = _retryAfter;
    final when = retry != null && retry.isAfter(at) ? retry : at;
    _timer?.cancel();
    _timerAt = when;
    _timer = Timer(when.difference(DateTime.now()), () {
      _timer = null;
      unawaited(syncNow());
    });
  }

  void _onLocalChange(String section) {
    if (!status.value.on) return;
    // My List and language choices change now and then, and are wanted on
    // the other devices soon: out in a few seconds. Watch progress changes
    // every few seconds while playing: gathered up.
    if (section == 'list' || section == 'settings') {
      final at = _timerAt;
      if (_timer == null || at == null ||
          at.isAfter(DateTime.now().add(_afterListChange))) {
        _schedule(_afterListChange);
      }
      return;
    }
    if (_timer != null) return;
    var after = _afterChange;
    final last = _lastAttempt;
    if (last != null) {
      final spaced = last.add(_minSpacing).difference(DateTime.now());
      if (spaced > after) after = spaced;
    }
    _schedule(after);
  }

  /// The app came back to the screen.
  void onResume() {
    if (!status.value.on) return;
    final last = _lastAttempt;
    if (last == null || DateTime.now().difference(last) > const Duration(minutes: 1)) {
      _schedule(const Duration(seconds: 2));
    }
  }

  /// Home, My List or Settings was opened: checks right away for what the
  /// other devices changed (one more right after, if one's running). A
  /// check is one small request to Google; it downloads only what changed.
  void onTabSwitch() {
    if (!status.value.on) return;
    unawaited(syncNow());
  }

  /// The app went to the background: what changed goes out now, while it
  /// still can.
  void onPause() {
    if (status.value.on && SyncLedger().generation != _syncedGeneration) {
      unawaited(syncNow());
    }
  }

  // --- Syncing ---

  /// Syncs now, unless one's running (then once more after it) or it's
  /// waiting after failures — [userAsked] doesn't wait.
  Future<void> syncNow({bool userAsked = false}) async {
    if (!status.value.on) return;
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final retry = _retryAfter;
    if (!userAsked && retry != null && DateTime.now().isBefore(retry)) return;
    _timer?.cancel();
    _timer = null;
    final run = _run(userAsked: userAsked);
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
      if (_again) {
        _again = false;
        _schedule(Duration.zero);
      }
    }
  }

  Future<void> _run({bool userAsked = false}) async {
    _lastAttempt = DateTime.now();
    status.value = status.value.copyWith(busy: true);
    try {
      final problem = await _syncOnce();
      _failures = 0;
      _retryAfter = null;
      if (!status.value.on) return;
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setInt(_lastKey, now.millisecondsSinceEpoch);
      status.value = status.value.copyWith(lastSynced: now, problem: () => problem);
    } on SyncException catch (e) {
      debugPrint('Sync stopped: $e');
      _failed(e.problem, '$e', userAsked: userAsked);
    } catch (e, s) {
      debugPrint('Sync failed: $e\n$s');
      _failed(SyncProblem.other, '$e', userAsked: userAsked);
    } finally {
      status.value = status.value.copyWith(busy: false);
    }
  }

  void _failed(SyncProblem problem, String detail, {bool userAsked = false}) {
    if (!status.value.on) return;
    // Kept, to find out what went wrong on a device with no log to read.
    unawaited(SharedPreferences.getInstance().then((prefs) => prefs.setString(
        _lastErrorKey, '${DateTime.now().toIso8601String()} $detail')));
    // Paused from the website: checked again the next time there's a
    // reason to sync.
    if (problem == SyncProblem.pausedRemotely) {
      status.value = status.value.copyWith(problem: () => problem);
      return;
    }
    _failures++;
    // A passing hiccup (the connection, or Google, for a moment): tried
    // once more a few seconds on, before saying anything.
    final passing =
        problem == SyncProblem.unreachable || problem == SyncProblem.other;
    if (passing && _failures == 1 && !userAsked) {
      _retryAfter = DateTime.now().add(const Duration(seconds: 5));
      _schedule(const Duration(seconds: 5));
      return;
    }
    status.value = status.value.copyWith(problem: () => problem);
    final minutes =
        min(pow(2, max(0, _failures - 2)).toInt(), _maxBackoff.inMinutes);
    _retryAfter = DateTime.now().add(Duration(minutes: minutes));
    _schedule(Duration(minutes: minutes));
  }

  /// One sync. Returns a problem that didn't stop it (needsUpdate), or
  /// null.
  Future<SyncProblem?> _syncOnce() async {
    final link = GoogleLink.forThisDevice();
    if (link == null) throw const SyncException(SyncProblem.other, 'not set up');
    final flags = FeatureFlagsService();
    final version = (await PackageInfo.fromPlatform()).version;
    if (!flags.syncEnabled || flags.syncBlocked(version)) {
      throw const SyncException(SyncProblem.pausedRemotely);
    }

    final ledger = SyncLedger();
    final prefs = await SharedPreferences.getInstance();
    final store = _storeFor(link);
    final files = await store.listFiles();
    final offset = store.clockOffsetMs;
    if (offset != null && (offset - ledger.offsetMs).abs() > 2000) {
      await ledger.setOffset(offset);
    }

    // Synced data deleted from another device since this one signed in.
    for (final f in files) {
      if (f.name != DriveStore.controlName) continue;
      try {
        final json = jsonDecode(utf8.decode(await store.download(f.id)));
        final stoppedAt = json is Map ? json['stopped_at'] : null;
        final signedInAt = prefs.getInt(_signedInKey) ?? 0;
        if (stoppedAt is num && stoppedAt > signedInAt) {
          await turnOff();
          _notices.add('Sync was turned off from another device. Your lists '
              'here are kept.');
          return null;
        }
      } catch (_) {}
    }

    final myName = DriveStore.pageName(await _deviceId(prefs));
    DriveFile? mine;
    final others = <DriveFile>[];
    for (final f in files) {
      if (f.name == myName) {
        mine = f;
      } else if (f.name.startsWith(DriveStore.pagePrefix) &&
          f.name.endsWith(DriveStore.pageSuffix)) {
        others.add(f);
      }
    }

    // Only pages that changed since they were last combined in.
    final seen = _readSeen(prefs);
    final fresh = <DriveFile, SyncData>{};
    var newerApp = false;
    for (final f in others) {
      if (seen[f.id] == f.version) continue;
      final page = await store.readPage(f.id);
      if (page == null) continue;
      fresh[f] = page;
      if (page.format > SyncData.currentFormat) newerApp = true;
    }

    // Combine, and put the result in place here.
    for (var attempt = 0;; attempt++) {
      final generation = ledger.generation;
      final local = await SyncBridge.gather();
      final now = ledger.now();
      final before = SyncData.merge([local], now: now);
      final merged = SyncData.merge([local, ...fresh.values], now: now);
      if (_sameItems(before, merged)) {
        _syncedGeneration = generation;
        break;
      }

      final removed = _removedCount(before, merged);
      final total = before.live('list').length + before.live('history').length;
      final big = removed >= _bigRemoval && removed * 4 >= total;
      if (big) await SyncSnapshots.keepBeforeRemoval(local);

      // Something changed here meanwhile: read it again, so it's kept.
      if (ledger.generation != generation && attempt < 5) continue;
      await SyncBridge.apply(merged);
      _syncedGeneration = ledger.generation;
      if (big) {
        await prefs.setString(_removalKey,
            jsonEncode({'count': removed, 'at': DateTime.now().millisecondsSinceEpoch}));
        status.value = status.value.copyWith(removedCount: removed);
        _notices.add('Another device removed $removed titles. To bring them '
            'back, go to Settings › Sync.');
      }
      break;
    }

    if (newerApp) {
      // Read, but not written over with this older layout.
      _saveSeen(prefs, seen, fresh, files);
      return SyncProblem.needsUpdate;
    }

    // This device's page: saved only when it changed.
    final page = SyncData.merge([await SyncBridge.gather()], now: ledger.now());
    final hash = sha1.convert(utf8.encode(SyncData.canonicalJson(page.toJson()))).toString();
    if (mine == null || prefs.getString(_hashKey) != hash) {
      final bytes = DriveStore.encodePage(page);
      DriveFile saved;
      try {
        saved = await store.save(id: mine?.id, name: myName, bytes: bytes);
      } on SyncException catch (e) {
        if (mine == null || e.detail != '404') rethrow;
        saved = await store.save(name: myName, bytes: bytes);
      }
      await prefs.setString(_pageIdKey, saved.id);
      await prefs.setString(_hashKey, hash);
    }

    // Pages of devices not seen for months: everything on them is here
    // (and on this device's page) by now.
    final cutoff = DateTime.now().subtract(_pageLife);
    for (final f in others) {
      final combined = seen[f.id] == f.version || fresh.containsKey(f);
      if (combined && f.modified.isBefore(cutoff)) {
        await store.delete(f.id);
        seen.remove(f.id);
        fresh.remove(f);
      }
    }
    _saveSeen(prefs, seen, fresh, files);

    if (status.value.email == null) {
      final email = await store.accountEmail();
      if (email != null) {
        await prefs.setString(_emailKey, email);
        status.value = status.value.copyWith(email: email);
      }
    }
    return null;
  }

  static bool _sameItems(SyncData a, SyncData b) =>
      SyncData.canonicalJson({'i': a.items, 'l': a.lengths}) ==
      SyncData.canonicalJson({'i': b.items, 'l': b.lengths});

  /// Titles in My List or Continue Watching in [before] but not [after].
  static int _removedCount(SyncData before, SyncData after) {
    var n = 0;
    for (final section in const ['list', 'history']) {
      final still = after.live(section).map((e) => e.key).toSet();
      n += before.live(section).where((e) => !still.contains(e.key)).length;
    }
    return n;
  }

  static Map<String, String> _readSeen(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_seenKey);
      if (raw == null) return {};
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static void _saveSeen(SharedPreferences prefs, Map<String, String> seen,
      Map<DriveFile, SyncData> fresh, List<DriveFile> files) {
    for (final e in fresh.entries) {
      // A newer app's page is read again each time, so this one keeps
      // knowing to hold off.
      if (e.value.format <= SyncData.currentFormat) seen[e.key.id] = e.key.version;
    }
    final ids = files.map((f) => f.id).toSet();
    seen.removeWhere((id, _) => !ids.contains(id));
    unawaited(prefs.setString(_seenKey, jsonEncode(seen)));
  }

  static Future<String> _deviceId(SharedPreferences prefs) async {
    final have = prefs.getString(_deviceKey);
    if (have != null) return have;
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    final id = String.fromCharCodes(
        Iterable.generate(16, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
    await prefs.setString(_deviceKey, id);
    return id;
  }

  // --- Going back ---

  /// Brings back what the last big removal took (and nothing else changes).
  Future<bool> undoRemoval() async {
    final data = await SyncSnapshots.readBeforeRemoval();
    if (data == null) return false;
    await _bringBack(data);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_removalKey);
    await SyncSnapshots.dropBeforeRemoval();
    status.value = status.value.copyWith(removedCount: 0);
    return true;
  }

  /// Everything in [snapshot] that isn't here now comes back, as added
  /// just now, so it's back on the other devices too.
  Future<void> _bringBack(SyncData snapshot) async {
    final ledger = SyncLedger();
    final local = await SyncBridge.gather();
    final t = ledger.now();
    final wanted = SyncData(lengths: snapshot.lengths);
    for (final section in SyncData.sections) {
      final then = {for (final e in snapshot.live(section)) e.key: e.value};
      final nowLive = {for (final e in local.live(section)) e.key};
      for (final e in then.entries) {
        if (nowLive.contains(e.key)) continue;
        wanted[section][e.key] = {...e.value, 't': t};
      }
    }
    await SyncBridge.apply(SyncData.merge([local, wanted], now: t + 1));
    // So it goes out, as any change here does.
    ledger.touchAll('list', const <String>[]);
    if (status.value.on) unawaited(syncNow(userAsked: true));
  }
}
