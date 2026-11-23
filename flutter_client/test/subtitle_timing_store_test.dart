import 'package:flutter_client/services/saved_movies_service.dart';
import 'package:flutter_client/services/subtitle_timing_store.dart';
import 'package:flutter_client/services/sync/sync_bridge.dart';
import 'package:flutter_client/services/sync/sync_data.dart';
import 'package:flutter_client/services/sync/sync_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const hash = 'abcdef0123456789abcdef0123456789abcdef01';
const section = SubtitleTimingStore.section;

/// The player's name for a timing.
String playerKey(String id) => 'subtitle_timing2_${hash}_$id';
String syncKey(String id) => '${hash}_$id';

SyncData pageWith(Map<String, Map<String, dynamic>> timings) =>
    SyncData(items: {section: timings});

Map<String, dynamic> on(int t, double d, double s) => {
      't': t,
      'v': {'d': d, 's': s},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SyncLedger().reset();
    SubtitleTimingStore().reset();
    await SavedMoviesService().init();
  });

  test('keeps a timing, under the old name or the new', () async {
    final store = SubtitleTimingStore();
    await store.remember(playerKey('7'), (delay: 11.5, speed: 1.0));
    expect(await store.timingOf(playerKey('7')), (delay: 11.5, speed: 1.0));
    expect(store.kept(syncKey('7')), (delay: 11.5, speed: 1.0));
    expect(await store.timingOf(playerKey('8')), isNull);
    expect(SyncLedger().changedAt(section, syncKey('7')), isNotNull);

    // And after a restart.
    store.reset();
    expect(await store.timingOf(playerKey('7')), (delay: 11.5, speed: 1.0));
  });

  test('timings kept the old way are taken in, and the old settings go',
      () async {
    SharedPreferences.setMockInitialValues({
      playerKey('1'): '-2.25|1.0427|confirmed',
      playerKey('2'): '3.0|1.0', // never confirmed
      'other_setting': 'x',
    });
    final store = SubtitleTimingStore();
    await store.init();
    expect(store.kept(playerKey('1')), (delay: -2.25, speed: 1.0427));
    expect(store.kept(playerKey('2')), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('subtitle_timing2_')),
        isEmpty);
    expect(prefs.getString('other_setting'), 'x');

    // Synced with a time that loses to any real change.
    final here = await SyncBridge.gather();
    expect(SyncData.timeOf(here[section][syncKey('1')]!), 1);
    final merged = SyncData.merge([
      here,
      pageWith({syncKey('1'): on(1000, 4.0, 1.0)}),
    ], now: SyncLedger().now());
    await SyncBridge.apply(merged);
    expect(store.kept(playerKey('1')), (delay: 4.0, speed: 1.0));
  });

  test('keeps at most the newest 500', () {
    final timings = <String, Map<String, dynamic>>{
      for (var i = 0; i < 503; i++)
        'k$i': {'d': 0.0, 's': 1.0, 't': 1000 + i},
    };
    final dropped = SubtitleTimingStore.trim(timings);
    expect(timings.length, SubtitleTimingStore.maxKept);
    expect(dropped, {'k0', 'k1', 'k2'});
  });

  test('past 500 the oldest goes, not as a removal', () async {
    final store = SubtitleTimingStore();
    for (var i = 0; i <= SubtitleTimingStore.maxKept; i++) {
      await store.remember(syncKey('$i'), (delay: i.toDouble(), speed: 1.0));
    }
    final here = await SyncBridge.gather();
    expect(here[section].length, SubtitleTimingStore.maxKept);
    expect(store.kept(syncKey('${SubtitleTimingStore.maxKept}')), isNotNull);
    // The first was the oldest (on a tie of times, the same on every
    // device: by key).
    final gone = [
      for (var i = 0; i <= SubtitleTimingStore.maxKept; i++)
        if (store.kept(syncKey('$i')) == null) i,
    ];
    expect(gone.length, 1);
    expect(SyncLedger().removedIn(section), isEmpty);
  });

  test("the latest change wins, and another device's removal arrives",
      () async {
    final store = SubtitleTimingStore();
    await store.remember(playerKey('1'), (delay: 1.0, speed: 1.0));
    await store.remember(playerKey('2'), (delay: 2.0, speed: 1.0));
    final t = SyncLedger().now();

    // An older change elsewhere loses; a newer one, and a new copy, arrive.
    await SyncBridge.apply(SyncData.merge([
      await SyncBridge.gather(),
      pageWith({
        syncKey('1'): on(t - 60000, 9.0, 1.0),
        syncKey('2'): on(t + 1000, 2.5, 0.96),
        syncKey('3'): on(t + 1000, 3.0, 1.0),
      }),
    ], now: t + 2000));
    expect(store.kept(playerKey('1')), (delay: 1.0, speed: 1.0));
    expect(store.kept(playerKey('2')), (delay: 2.5, speed: 0.96));
    expect(store.kept(playerKey('3')), (delay: 3.0, speed: 1.0));

    // Removed there, later: gone here too.
    await SyncBridge.apply(SyncData.merge([
      await SyncBridge.gather(),
      pageWith({syncKey('3'): {'t': t + 3000, 'removed': true}}),
    ], now: t + 4000));
    expect(store.kept(playerKey('3')), isNull);
    // ...and stays gone after a restart.
    store.reset();
    expect(await store.timingOf(playerKey('3')), isNull);
    expect(await store.timingOf(playerKey('2')), (delay: 2.5, speed: 0.96));
  });

  test('forgetting one here goes out as a removal', () async {
    final store = SubtitleTimingStore();
    await store.remember(playerKey('1'), (delay: 1.0, speed: 1.0));
    await store.forget(playerKey('1'));
    expect(store.kept(playerKey('1')), isNull);
    final here = await SyncBridge.gather();
    expect(SyncData.isRemoved(here[section][syncKey('1')]!), isTrue);

    // An older copy elsewhere doesn't bring it back.
    final t = SyncData.timeOf(here[section][syncKey('1')]!);
    await SyncBridge.apply(SyncData.merge([
      here,
      pageWith({syncKey('1'): on(t - 1, 1.0, 1.0)}),
    ], now: t + 10));
    expect(store.kept(playerKey('1')), isNull);

    // Forgetting one never kept sends nothing.
    await store.forget(playerKey('9'));
    expect((await SyncBridge.gather())[section].containsKey(syncKey('9')),
        isFalse);
  });

  test('the same timing again changes nothing', () async {
    final store = SubtitleTimingStore();
    await store.remember(playerKey('1'), (delay: 1.0, speed: 1.0));
    final generation = SyncLedger().generation;
    await store.remember(playerKey('1'), (delay: 1.0, speed: 1.0));
    expect(SyncLedger().generation, generation);
  });

  test('a page without the section (an older app) changes nothing', () async {
    final store = SubtitleTimingStore();
    await store.remember(playerKey('1'), (delay: 1.0, speed: 1.0));
    final older = SyncData.fromJson({
      'format': 1,
      'list': {},
      'history': {},
      'episodes': {},
      'settings': {},
      'waiting': {},
    });
    await SyncBridge.apply(SyncData.merge([await SyncBridge.gather(), older],
        now: SyncLedger().now()));
    expect(store.kept(playerKey('1')), (delay: 1.0, speed: 1.0));
  });

  test('a page carries them through its JSON', () {
    final page = pageWith({syncKey('1'): on(5, 1.5, 0.96)}).toJson();
    final read = SyncData.fromJson(page);
    expect(read[section][syncKey('1')], on(5, 1.5, 0.96));
    expect(read.extra, isEmpty);
  });

  test('signing out clears them; deleting synced data removes them', () async {
    final store = SubtitleTimingStore();
    await store.remember(playerKey('1'), (delay: 1.0, speed: 1.0));
    await SyncBridge.clearLocal();
    expect(store.kept(playerKey('1')), isNull);
    final prefs = await SharedPreferences.getInstance();
    store.reset();
    expect(await store.timingOf(playerKey('1')), isNull);
    expect(prefs.getKeys().any((k) => k.startsWith('subtitle_timing2_')),
        isFalse);

    await store.remember(playerKey('2'), (delay: 2.0, speed: 1.0));
    final here = await SyncBridge.gather();
    final t = SyncLedger().now();
    final removal = SyncData.removalOfAll(here, t);
    expect(SyncData.isRemoved(removal[section][syncKey('2')]!), isTrue);
    await SyncBridge.apply(removal);
    expect(store.kept(playerKey('2')), isNull);
  });
}
