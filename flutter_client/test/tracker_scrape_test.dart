import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_client/services/torrent/tracker_scrape.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tracker on this machine answering BEP 15 connect and scrape, with
/// [counts] (by lowercase info hash: seeders, completed, leechers).
Future<RawDatagramSocket> fakeTracker(
    Map<String, (int, int, int)> counts) async {
  final socket =
      await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  const connection = 0x1122334455667788;
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    final req = ByteData.sublistView(d.data);
    final action = req.getInt32(8);
    final transaction = req.getInt32(12);
    if (action == 0) {
      expect(req.getInt64(0), 0x41727101980);
      final reply = ByteData(16)
        ..setInt32(0, 0)
        ..setInt32(4, transaction)
        ..setInt64(8, connection);
      socket.send(reply.buffer.asUint8List(), d.address, d.port);
    } else if (action == 2) {
      expect(req.getInt64(0), connection);
      final n = (d.data.length - 16) ~/ 20;
      final reply = ByteData(8 + 12 * n)
        ..setInt32(0, 2)
        ..setInt32(4, transaction);
      for (var i = 0; i < n; i++) {
        final hash = [
          for (var b = 0; b < 20; b++)
            d.data[16 + i * 20 + b].toRadixString(16).padLeft(2, '0'),
        ].join();
        final c = counts[hash] ?? (0, 0, 0);
        reply
          ..setInt32(8 + i * 12, c.$1)
          ..setInt32(12 + i * 12, c.$2)
          ..setInt32(16 + i * 12, c.$3);
      }
      socket.send(reply.buffer.asUint8List(), d.address, d.port);
    }
  });
  return socket;
}

void main() {
  tearDown(TrackerScrape.reset);
  final a = 'a' * 40, b = 'b' * 40, c = 'c' * 40;

  test('reads a tracker\'s live counts', () async {
    final tracker = await fakeTracker({a: (120, 5000, 30), b: (2, 40, 0)});
    addTearDown(tracker.close);
    final counts = await TrackerScrape.scrape(
        'udp://127.0.0.1:${tracker.port}/announce', [a, b, c]);
    expect(counts[a], (seeders: 120, leechers: 30));
    expect(counts[b], (seeders: 2, leechers: 0));
    expect(counts[c], (seeders: 0, leechers: 0));
  });

  test('more hashes than one packet holds', () async {
    final many = [
      for (var i = 0; i < 150; i++) i.toRadixString(16).padLeft(40, '0'),
    ];
    final tracker = await fakeTracker({many.last: (7, 0, 1)});
    addTearDown(tracker.close);
    final counts = await TrackerScrape.scrape(
        'udp://127.0.0.1:${tracker.port}/announce', many);
    expect(counts.length, 150);
    expect(counts[many.last], (seeders: 7, leechers: 1));
  });

  test('the highest of several trackers; unknown ones left out', () async {
    final one = await fakeTracker({'1' * 40: (10, 0, 2)});
    final two = await fakeTracker({'1' * 40: (25, 0, 1)});
    addTearDown(one.close);
    addTearDown(two.close);
    final counts = await TrackerScrape.counts(
      ['1' * 40, '2' * 40],
      [
        'udp://127.0.0.1:${one.port}/announce',
        'udp://127.0.0.1:${two.port}/announce',
        'https://not.udp/announce',
      ],
    );
    expect(counts['1' * 40], (seeders: 25, leechers: 2));
    expect(counts.containsKey('2' * 40), isFalse,
        reason: 'no one at all: unknown to these trackers');
  });

  test('a tracker that never answers gives nothing, quickly', () async {
    final silent =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);
    final watch = Stopwatch()..start();
    final counts = await TrackerScrape.counts(
      ['3' * 40],
      ['udp://127.0.0.1:${silent.port}/announce'],
      timeout: const Duration(milliseconds: 300),
    );
    expect(counts, isEmpty);
    expect(watch.elapsedMilliseconds, lessThan(1500));
  });
}
