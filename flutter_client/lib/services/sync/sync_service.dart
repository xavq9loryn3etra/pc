import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../feature_flags_service.dart';
import 'drive_store.dart';
import 'google_link.dart';
import 'sync_bridge.dart';
import 'sync_data.dart';
import 'sync_ledger.dart';
import 'sync_snapshots.dart';

/// What a device signing in has that the account doesn't (see
/// [SyncService.turnOn]): how many titles in My List and Continue Watching.
typedef OnlyHere = ({int list, int history});

/// What Settings shows about sync.
@immutable
class SyncStatus {
  /// Signed in to Google for sync.
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

  /// Just signed in, and this device has titles the account doesn't:
  /// waiting to be told whether they join the account or go (nothing syncs
  /// till then).
  final OnlyHere? asking;

  const SyncStatus({
    this.on = false,
    this.busy = false,
    this.email,
    this.lastSynced,
    this.problem,
    this.removedCount = 0,
    this.asking,
  });

  SyncStatus copyWith({
    bool? on,
    bool? busy,
    String? email,
    DateTime? lastSynced,
    SyncProblem? Function()? problem,
    int? removedCount,
    OnlyHere? Function()? asking,
  }) =>
      SyncStatus(
        on: on ?? this.on,
        busy: busy ?? this.busy,
        email: email ?? this.email,
        lastSynced: lastSynced ?? this.lastSynced,
        problem: problem != null ? problem() : this.problem,
        removedCount: removedCount ?? this.removedCount,
        asking: asking != null ? asking() : this.asking,
      );
}

/// Keeps My List, Continue Watching, episode progress, language choices,
/// the Gemini key and the copy each title last played the same on every
/// device signed in to the same Google account. They belong to the
/// account: signing out takes them off the device, and they come back on
/// signing in again.
///
/// Each device writes its own page (SyncData) to the account's hidden
/// Popcorn folder in Drive (DriveStore), and never anyone else's; a sync
/// reads every page that changed since last time, combines them with this
/// device's lists, puts the result in place here, and saves it as this
/// device's page. No server: the app talks to Google directly.
///
/// When — only when there's a reason, never on a timer:
/// - what changed here goes out: My List and language choices at once,
///   watch progress at most every two minutes while playing, and anything
///   left as the app goes to the background;
/// - what the other devices changed comes in when it's about to be seen:
///   as the app opens or comes back, and on opening Home, My List or
///   Settings.
/// Failures wait longer each time (up to half an hour) and never get in
/// the way of the app.
///
/// Safeguards:
/// - signing in on a device with titles the account doesn't have asks
///   whether they join it, or go (Settings › Sync);
/// - signing out saves what's left to save first, or says it couldn't;
/// - a sync that would remove many titles at once still does — the other
///   device asked for it — but keeps a copy from right before and says so,
///   with "Bring back" in Settings (not when the data was deleted on
///   purpose: [SyncData.clearedAt]);
/// - a page from a newer app version is read but this device stops
///   writing until it's updated;
/// - the website's flags can pause sync everywhere, or for one version
///   (FeatureFlagsService).
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
  static const _askingKey = 'sync_asking';
  static const _clearedKey = 'sync_cleared_at';

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

  /// For tests: the Drive to use instead of Google's.
  @visibleForTesting
  DriveStore? debugStore;

  DriveStore? _store;
  Timer? _timer;
  DateTime? _timerAt;
  Future<void>? _running;
  bool _again = false;
  bool _holding = false; // Deleting or signing out: no syncs meanwhile.
  int _failures = 0;
  DateTime? _retryAfter;
  DateTime? _lastAttempt;
  int _syncedGeneration = -1;

  DriveStore _storeFor(GoogleLink link) =>
      debugStore ??
      (_store ??= DriveStore(
          ({bool refresh = false}) => link.accessToken(refresh: refresh)));

  GoogleLink _link() {
    final link = GoogleLink.forThisDevice();
    if (link == null) throw const SyncException(SyncProblem.other, 'not set up');
    return link;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final on = (prefs.getBool(_onKey) ?? false) && available;
    final last = prefs.getInt(_lastKey);
    status.value = SyncStatus(
      on: on,
      email: prefs.getString(_emailKey),
      lastSynced: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      removedCount: _removalCount(prefs),
      asking: on ? _readAsking(prefs) : null,
    );
    SyncLedger().onChange = _onLocalChange;
    // The first sync at once, while the splash plays: Home usually opens
    // with the lists up to date. It's mostly waiting on Google, so it
    // doesn't slow the start.
    if (on && status.value.asking == null) _schedule(Duration.zero);
  }

  static int _removalCount(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_removalKey);
      if (raw == null) return 0;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(json['at'] as int);
      // Undo is offered for a week, as long as the copy is kept.
      if (DateTime.now().difference(at) > const Duration(days: SyncSnapshots.undoDays)) {
        return 0;
      }
      return json['count'] as int;
    } catch (_) {
      return 0;
    }
  }

  static OnlyHere? _readAsking(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_askingKey);
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return (list: json['list'] as int, history: json['history'] as int);
    } catch (_) {
      return null;
    }
  }

  // --- Signing in and out ---

  /// Signs in. If the account already has lists and this device has titles
  /// they don't, it then waits ([SyncStatus.asking]) for [addDeviceLists]
  /// or [keepAccountListsOnly]; otherwise it syncs straight away. On a TV,
  /// [onCode] gets the code to show. Throws a SyncException if signing in
  /// didn't happen.
  Future<void> turnOn({
    void Function(DeviceCode code)? onCode,
    Future<void>? cancel,
  }) async {
    final link = _link();
    await link.signIn(onCode: onCode, cancel: cancel);
    _store = null;
    final store = _storeFor(link);
    final email = await store.accountEmail();
    final offset = store.clockOffsetMs;
    if (offset != null) await SyncLedger().setOffset(offset);

    // What the account has, and whether this device has anything it
    // doesn't — read before anything's recorded as signed in, so a
    // connection lost here leaves this device as it was.
    final account = await _readAccount(store);
    final here = await SyncBridge.gather();
    final extra = SyncBridge.onlyHere(here, account.data);
    final ask = account.pages > 0 && extra.list + extra.history > 0;

    final prefs = await SharedPreferences.getInstance();
    // Possibly another account: everything there is read afresh.
    for (final key in [_seenKey, _hashKey, _pageIdKey, _askingKey, _clearedKey]) {
      await prefs.remove(key);
    }
    // A deletion before this sign-in isn't news here.
    if (account.data.clearedAt != null) {
      await prefs.setInt(_clearedKey, account.data.clearedAt!);
    }
    if (ask) {
      await prefs.setString(
          _askingKey, jsonEncode({'list': extra.list, 'history': extra.history}));
    }
    if (email != null) await prefs.setString(_emailKey, email);
    await prefs.setInt(_signedInKey, SyncLedger().now());
    await prefs.setBool(_onKey, true);
    _failures = 0;
    _retryAfter = null;
    status.value = status.value.copyWith(
      on: true,
      email: email,
      problem: () => null,
      asking: () => ask ? extra : null,
    );
    if (!ask) await syncNow(userAsked: true);
  }

  /// The answer to [SyncStatus.asking]: this device's titles join the
  /// account (and so every device signed in to it).
  Future<void> addDeviceLists() async {
    await _stopAsking();
    await syncNow(userAsked: true);
  }

  /// The other answer: this device's own titles go, and it shows only what
  /// the account has.
  Future<void> keepAccountListsOnly() async {
    final store = _storeFor(_link());
    final account = await _readAccount(store);
    await SyncBridge.apply(account.data, replace: true);
    await _stopAsking();
    await syncNow(userAsked: true);
  }

  Future<void> _stopAsking() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_askingKey);
    status.value = status.value.copyWith(asking: () => null);
  }

  /// Signs out on this device and takes its lists off it — they stay in
  /// the account, and come back on signing in again. What hasn't reached
  /// Drive yet is sent first; if that can't be done, nothing happens and
  /// this returns false, unless [evenIfUnsaved].
  Future<bool> signOut({bool evenIfUnsaved = false}) async {
    final s = status.value;
    if (s.on && s.asking == null && SyncLedger().generation != _syncedGeneration) {
      await syncNow(userAsked: true);
      final problem = status.value.problem;
      final unsaved = SyncLedger().generation != _syncedGeneration ||
          (problem != null && problem != SyncProblem.needsUpdate);
      if (unsaved && !evenIfUnsaved) return false;
    }
    _holding = true;
    try {
      await _running;
      await SyncBridge.clearLocal();
      await SyncSnapshots.dropBeforeRemoval();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_removalKey);
      await _signOutHere();
    } finally {
      _holding = false;
    }
    return true;
  }

  /// Forgets the sign-in on this device only: Google's permission for
  /// Popcorn stays, or every other device would be signed out too.
  Future<void> _signOutHere() async {
    _timer?.cancel();
    _timer = null;
    try {
      await GoogleLink.forThisDevice()?.signOut();
    } catch (_) {}
    _store = null;
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _onKey, _emailKey, _pageIdKey, _lastKey, _signedInKey, _seenKey,
      _hashKey, _askingKey, _clearedKey,
    ]) {
      await prefs.remove(key);
    }
    status.value = const SyncStatus();
  }

  /// Deletes the account's synced data — My List, Continue Watching,
  /// episode progress, language choices, the Gemini key, the copies last
  /// played, subtitle timings — from it and from every device signed in
  /// to it, this one
  /// included. Nobody is signed out: the lists just start again, empty.
  ///
  /// Every page but this device's is deleted, and this one's holds a
  /// removal of everything, newer than any copy anywhere, so a device
  /// that syncs later drops its copies too.
  Future<void> deleteSyncedData() async {
    final store = _storeFor(_link());
    _holding = true;
    try {
      await _running;
      final prefs = await SharedPreferences.getInstance();
      final ledger = SyncLedger();
      final files = await store.listFiles();
      final account = await _readAccount(store, files: files);
      final local = await SyncBridge.gather();
      final t = ledger.now();
      final everything = SyncData.merge([local, account.data], now: t);
      await SyncBridge.apply(SyncData.removalOfAll(everything, t));
      await prefs.setInt(_clearedKey, t);

      final myName = DriveStore.pageName(await _deviceId(prefs));
      DriveFile? mine;
      for (final f in files) {
        if (f.name == myName) mine = f;
      }
      final page = await _pageToSave(prefs);
      final saved = await _savePage(store, page, myName, mine);
      for (final f in files) {
        if (f.name != myName) await store.delete(f.id);
      }
      await prefs.setString(_seenKey, jsonEncode({saved.id: saved.version}));
      await prefs.remove(_removalKey);
      await SyncSnapshots.dropBeforeRemoval();
      _syncedGeneration = ledger.generation;
      status.value = status.value.copyWith(removedCount: 0, problem: () => null);
    } finally {
      _holding = false;
    }
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
    // the other devices soon: out at once. Watch progress changes every
    // few seconds while playing: gathered up.
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

  /// TVs and computers (see main.dart): Home can stay open for hours,
  /// and the app's seldom put away, so nothing else would check: a quiet
  /// check every [_foregroundEvery] while it's on screen — one small
  /// request to Google, downloading only what changed.
  void startForegroundChecks() {
    _foregroundChecks ??= Timer.periodic(_foregroundEvery, (_) {
      if (!status.value.on) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      unawaited(syncNow());
    });
  }

  Timer? _foregroundChecks;
  static const _foregroundEvery = Duration(minutes: 5);

  /// Back on Home from the player or a title's page: Continue Watching is
  /// what's looked at then — what the other devices did is checked now.
  void onBackHome() => onTabSwitch();

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
  /// waiting after failures — [userAsked] doesn't wait. Not while asking
  /// whether this device's titles join the account, nor while deleting or
  /// signing out.
  Future<void> syncNow({bool userAsked = false}) async {
    if (!status.value.on || status.value.asking != null || _holding) return;
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

  /// Every device's page in the account (this one's too), combined; and
  /// how many there were.
  Future<({SyncData data, int pages})> _readAccount(DriveStore store,
      {List<DriveFile>? files}) async {
    final pages = <SyncData>[];
    for (final f in files ?? await store.listFiles()) {
      if (!_isPage(f)) continue;
      final page = await store.readPage(f.id);
      if (page != null) pages.add(page);
    }
    return (
      data: SyncData.merge(pages, now: SyncLedger().now()),
      pages: pages.length,
    );
  }

  static bool _isPage(DriveFile f) =>
      f.name.startsWith(DriveStore.pagePrefix) &&
      f.name.endsWith(DriveStore.pageSuffix);

  /// One sync. Returns a problem that didn't stop it (needsUpdate), or
  /// null.
  Future<SyncProblem?> _syncOnce() async {
    final link = _link();
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

    final myName = DriveStore.pageName(await _deviceId(prefs));
    DriveFile? mine;
    final pages = <DriveFile>[];
    for (final f in files) {
      if (f.name == myName) mine = f;
      if (_isPage(f)) pages.add(f);
    }

    // Only pages that changed since they were last combined in — this
    // device's own too, which after signing in again holds its lists.
    final seen = _readSeen(prefs);
    final fresh = <DriveFile, SyncData>{};
    var newerApp = false;
    for (final f in pages) {
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

      // Deleted on purpose on another device since this one last looked.
      final clearedAt = merged.clearedAt;
      final known = prefs.getInt(_clearedKey) ?? 0;
      final deleted = clearedAt != null && clearedAt > known;

      if (_sameItems(before, merged)) {
        if (deleted) await prefs.setInt(_clearedKey, clearedAt);
        _syncedGeneration = generation;
        break;
      }

      final removed = _removedCount(before, merged);
      final total = before.live('list').length + before.live('history').length;
      final big = !deleted && removed >= _bigRemoval && removed * 4 >= total;
      if (big) await SyncSnapshots.keepBeforeRemoval(local);

      // Something changed here meanwhile: read it again, so it's kept.
      if (ledger.generation != generation && attempt < 5) continue;
      await SyncBridge.apply(merged);
      _syncedGeneration = ledger.generation;
      if (deleted) {
        await prefs.setInt(_clearedKey, clearedAt);
        await prefs.remove(_removalKey);
        await SyncSnapshots.dropBeforeRemoval();
        status.value = status.value.copyWith(removedCount: 0);
        _notices.add('Your synced lists were deleted from another device.');
      } else if (big) {
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
    final page = await _pageToSave(prefs);
    final hash = sha1.convert(utf8.encode(SyncData.canonicalJson(page.toJson()))).toString();
    if (mine == null || prefs.getString(_hashKey) != hash) {
      final saved = await _savePage(store, page, myName, mine);
      await prefs.setString(_hashKey, hash);
      // Already combined in: not read back next time.
      fresh.removeWhere((f, _) => f.id == saved.id);
      seen[saved.id] = saved.version;
    }

    // Pages of devices not seen for months: everything on them is here
    // (and on this device's page) by now.
    final cutoff = DateTime.now().subtract(_pageLife);
    for (final f in pages) {
      if (f.name == myName) continue;
      final combined = seen[f.id] == f.version || fresh.containsKey(f);
      if (combined && f.modified.isBefore(cutoff)) {
        await store.delete(f.id);
        seen.remove(f.id);
        fresh.remove(f);
      }
    }
    // Popcorn 4.2.0's note from deleting synced data: done with.
    for (final f in files) {
      if (f.name == DriveStore.controlName) await store.delete(f.id);
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

  /// This device's lists as its page, with when the account's data was
  /// last deleted, so that goes on to every device.
  Future<SyncData> _pageToSave(SharedPreferences prefs) async {
    final page = SyncData.merge([await SyncBridge.gather()], now: SyncLedger().now());
    page.clearedAt = prefs.getInt(_clearedKey);
    return page;
  }

  Future<DriveFile> _savePage(
      DriveStore store, SyncData page, String name, DriveFile? mine) async {
    final bytes = DriveStore.encodePage(page);
    DriveFile saved;
    try {
      saved = await store.save(id: mine?.id, name: name, bytes: bytes);
    } on SyncException catch (e) {
      if (mine == null || e.detail != '404') rethrow;
      saved = await store.save(name: name, bytes: bytes);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pageIdKey, saved.id);
    return saved;
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
    final saved = prefs.getString(_pageIdKey);
    seen.removeWhere((id, _) => !ids.contains(id) && id != saved);
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

  /// For tests: back to signed out, with nothing pending.
  @visibleForTesting
  void debugReset() {
    _timer?.cancel();
    _timer = null;
    _running = null;
    _again = false;
    _holding = false;
    _failures = 0;
    _retryAfter = null;
    _lastAttempt = null;
    _syncedGeneration = -1;
    _store = null;
    status.value = const SyncStatus();
  }
}
