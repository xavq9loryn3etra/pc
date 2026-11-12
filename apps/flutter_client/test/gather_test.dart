import 'dart:async';

import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_test/flutter_test.dart';

TorrentStream stream(int n, {int seeders = 1}) => TorrentStream.fromRelease(
      infoHash: n.toRadixString(16).padLeft(40, '0'),
      name: 'Movie $n 1080p',
      sizeBytes: 1 << 30,
      seeders: seeders,
      source: 'test',
    );

const ms = Duration(milliseconds: 1);

Future<List<TorrentStream>?> after(int millis, List<TorrentStream>? result) =>
    Future.delayed(ms * millis, () => result);

void main() {
  test('complete when every lookup answered', () async {
    final g = await TorrentIndexService.gather([
      after(1, [stream(1)]),
      after(5, [stream(1), stream(2)]),
      after(2, const []),
    ]);
    expect(g.complete, isTrue);
    expect(g.rest, isNull);
    expect(g.streams.length, 2);
  });

  test('a failed lookup (null) makes the result incomplete', () async {
    final g = await TorrentIndexService.gather([
      after(1, [stream(1)]),
      after(2, null),
    ]);
    expect(g.complete, isFalse);
    expect(g.rest, isNull);
    expect(g.streams.length, 1);
  });

  test('a lookup that throws counts as failed', () async {
    final g = await TorrentIndexService.gather([
      after(1, [stream(1)]),
      Future<List<TorrentStream>?>.delayed(ms * 2, () => throw StateError('x')),
    ]);
    expect(g.complete, isFalse);
  });

  test('after the patience, returns what is there; rest has everything',
      () async {
    final g = await TorrentIndexService.gather([
      after(1, [stream(1)]),
      after(60, [stream(2)]),
    ], patience: ms * 20);
    expect(g.complete, isFalse);
    expect(g.streams.length, 1);
    final all = await g.rest!;
    expect(all!.length, 2);
  });

  test('rest is null when a late lookup failed', () async {
    final g = await TorrentIndexService.gather([
      after(1, [stream(1)]),
      after(60, null),
    ], patience: ms * 20);
    expect(g.complete, isFalse);
    expect(await g.rest!, isNull);
  });

  test('waits past the patience while nothing has been found', () async {
    final g = await TorrentIndexService.gather([
      after(1, const []),
      after(40, [stream(1)]),
    ], patience: ms * 10);
    expect(g.complete, isTrue);
    expect(g.streams.length, 1);
  });

  test('the cap ends a search whatever the finders do', () async {
    final never = Completer<List<TorrentStream>?>();
    final g = await TorrentIndexService.gather([never.future],
        patience: ms * 10, cap: ms * 30);
    expect(g.complete, isFalse);
    expect(g.streams, isEmpty);
  });

  test('merges a torrent several lookups found, keeping the first', () async {
    final a = stream(1, seeders: 5), b = stream(1, seeders: 50);
    final g = await TorrentIndexService.gather([
      after(1, [a]),
      after(1, [b]),
    ]);
    expect(g.streams.single.seeders, 50);
  });
}
