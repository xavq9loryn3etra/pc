import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// How many are sharing a torrent right now, as its trackers count them.
typedef LiveCount = ({int seeders, int leechers});

/// Live sharer counts for torrents, asked of their trackers just before
/// a copy's chosen: the finders' counts are snapshots that can be weeks
/// old (The Odyssey's YTS 1080p was listed with 100 sharers and had
/// 10,285; a Russian one listed with 1,311 had 20). Trackers' UDP
/// "scrape" (BEP 15) gives every copy's count in a small packet, no data
/// downloaded. A copy no tracker knows keeps its finder's count.
///
/// From Sri Lanka a tracker's round trip is 170–350 ms, and each needs
/// two (connect, then scrape): so the connecting's done ahead ([prepare],
/// while the finders search) and kept for a minute, and a lookup's
/// packets go out together.
class TrackerScrape {
  TrackerScrape._();

  /// Kept for ten minutes: a copy's sharers don't change much in that time.
  static final Map<String, ({LiveCount count, DateTime at})> _cache = {};
  static const _keepFor = Duration(minutes: 10);

  /// Info hashes per scrape packet: BEP 15 allows about 74 in one.
  static const _perPacket = 70;

  /// The most trackers asked at once.
  static const _maxTrackers = 10;

  /// Connections to trackers, by URL (see [_session]).
  static final Map<String, ({Future<_Session> session, DateTime at})>
      _sessions = {};

  /// How long a connection's reused: BEP 15 gives its id a minute.
  static const _sessionFor = Duration(seconds: 50);

  /// Starts connecting to [trackers] now, for a lookup a few seconds
  /// later (see [counts]); nothing's waited on.
  static void prepare(Iterable<String> trackers) {
    for (final t in _udp(trackers)) {
      unawaited(_session(t, const Duration(seconds: 3)).then((_) {},
          onError: (_) {}));
    }
  }

  /// [infoHashes]' live counts (lowercase hex keys), from [trackers]
  /// (udp:// announce URLs; others are skipped) — each copy's highest
  /// count among them, as each tracker sees only part of its sharers.
  /// Back once every tracker's answered, or [grace] after the first did,
  /// or at [timeout]: whatever's in by then. Copies not answered, or
  /// answered with no one at all by every tracker (likely unknown to
  /// them), are left out.
  static Future<Map<String, LiveCount>> counts(
    Iterable<String> infoHashes,
    Iterable<String> trackers, {
    Duration timeout = const Duration(milliseconds: 1500),
    Duration grace = const Duration(milliseconds: 300),
  }) async {
    final now = DateTime.now();
    final result = <String, LiveCount>{};
    final wanted = <String>[];
    for (final h in {for (final h in infoHashes) h.toLowerCase()}) {
      if (!_isHash(h)) continue;
      final cached = _cache[h];
      if (cached != null && now.difference(cached.at) < _keepFor) {
        result[h] = cached.count;
      } else {
        wanted.add(h);
      }
    }
    final udp = _udp(trackers);
    if (wanted.isEmpty || udp.isEmpty) return result;

    final best = <String, LiveCount>{};
    void merge(Map<String, LiveCount> answer) {
      answer.forEach((h, c) {
        final had = best[h];
        best[h] = had == null
            ? c
            : (
                seeders: math.max(had.seeders, c.seeders),
                leechers: math.max(had.leechers, c.leechers),
              );
      });
    }

    final done = Completer<void>();
    var pending = udp.length;
    Timer? graceTimer;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    for (final t in udp) {
      scrape(t, wanted, timeout: timeout).then((answer) {
        merge(answer);
        graceTimer ??= Timer(grace, finish);
      }).catchError((_) {}).whenComplete(() {
        if (--pending == 0) finish();
      });
    }
    final deadline = Timer(timeout, finish);
    await done.future;
    deadline.cancel();
    graceTimer?.cancel();

    best.forEach((h, c) {
      if (c.seeders + c.leechers == 0) return; // Unknown to them, most likely.
      result[h] = c;
      _cache[h] = (count: c, at: now);
    });
    return result;
  }

  static List<String> _udp(Iterable<String> trackers) => [
        for (final t in {...trackers})
          if (t.startsWith('udp://')) t,
      ].take(_maxTrackers).toList();

  static bool _isHash(String h) => RegExp(r'^[0-9a-f]{40}$').hasMatch(h);

  /// A connection to [url]'s tracker: the one made in the last
  /// [_sessionFor], else a new one.
  static Future<_Session> _session(String url, Duration timeout) {
    final now = DateTime.now();
    final open = _sessions[url];
    if (open != null && now.difference(open.at) < _sessionFor) {
      return open.session;
    }
    final session = _Session.open(url, timeout);
    _sessions[url] = (session: session, at: now);
    session.then((s) {
      // Closed once its id's no longer good.
      Timer(_sessionFor, () {
        s.close();
        if (identical(_sessions[url]?.session, session)) _sessions.remove(url);
      });
    }, onError: (_) {
      if (identical(_sessions[url]?.session, session)) _sessions.remove(url);
    });
    return session;
  }

  /// One tracker's counts for [hashes] (BEP 15 scrape, its packets sent
  /// together).
  @visibleForTesting
  static Future<Map<String, LiveCount>> scrape(
    String trackerUrl,
    List<String> hashes, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final session = await _session(trackerUrl, timeout);
    final batches = [
      for (var from = 0; from < hashes.length; from += _perPacket)
        hashes.sublist(from, math.min(from + _perPacket, hashes.length)),
    ];
    final answers = await Future.wait([
      for (final batch in batches) session.scrape(batch, timeout),
    ]);
    return {for (final a in answers) ...a};
  }

  /// Closes every connection (for tests).
  @visibleForTesting
  static Future<void> reset() async {
    final open = [for (final s in _sessions.values) s.session];
    _sessions.clear();
    _cache.clear();
    for (final s in open) {
      try {
        (await s).close();
      } catch (_) {}
    }
  }
}

/// A tracker connection: its socket and BEP 15 connection id.
class _Session {
  final RawDatagramSocket socket;
  final InternetAddress address;
  final int port;
  final StreamController<Uint8List> replies;
  late final int connection;
  static final _random = math.Random();

  _Session._(this.socket, this.address, this.port, this.replies);

  static Future<_Session> open(String url, Duration timeout) async {
    final uri = Uri.parse(url);
    final addresses = await InternetAddress.lookup(uri.host).timeout(timeout);
    final address = addresses.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => addresses.first);
    final socket = await RawDatagramSocket.bind(
        address.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0);
    final replies = StreamController<Uint8List>.broadcast();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null && !replies.isClosed) replies.add(datagram.data);
    });
    final session = _Session._(socket, address, uri.port, replies);
    try {
      // Connect: the protocol's magic number, action 0.
      final id = _random.nextInt(1 << 31);
      final connect = ByteData(16)
        ..setInt64(0, 0x41727101980)
        ..setInt32(8, 0)
        ..setInt32(12, id);
      final reply = await session._ask(connect, id, 0, timeout);
      if (reply.lengthInBytes < 16) throw const FormatException('Short reply');
      session.connection = reply.getInt64(8);
      return session;
    } catch (_) {
      session.close();
      rethrow;
    }
  }

  Future<ByteData> _ask(
      ByteData packet, int transaction, int action, Duration timeout) {
    final reply = replies.stream.firstWhere((d) {
      if (d.length < 8) return false;
      final v = ByteData.sublistView(d);
      return v.getInt32(4) == transaction && v.getInt32(0) == action;
    });
    socket.send(packet.buffer.asUint8List(), address, port);
    return reply.timeout(timeout).then(ByteData.sublistView);
  }

  /// Seeders and leechers for [batch] (at most ~74 hashes).
  Future<Map<String, LiveCount>> scrape(
      List<String> batch, Duration timeout) async {
    final id = _random.nextInt(1 << 31);
    final packet = ByteData(16 + 20 * batch.length)
      ..setInt64(0, connection)
      ..setInt32(8, 2)
      ..setInt32(12, id);
    for (var i = 0; i < batch.length; i++) {
      final hex = batch[i];
      for (var b = 0; b < 20; b++) {
        packet.setUint8(16 + i * 20 + b,
            int.parse(hex.substring(b * 2, b * 2 + 2), radix: 16));
      }
    }
    final answer = await _ask(packet, id, 2, timeout);
    // Per hash: seeders, completed, leechers.
    return {
      for (var i = 0; i < batch.length; i++)
        if (answer.lengthInBytes >= 8 + i * 12 + 12)
          batch[i]: (
            seeders: answer.getInt32(8 + i * 12),
            leechers: answer.getInt32(16 + i * 12),
          ),
    };
  }

  void close() {
    socket.close();
    if (!replies.isClosed) replies.close();
  }
}
