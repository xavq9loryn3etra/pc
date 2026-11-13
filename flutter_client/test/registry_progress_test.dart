import 'package:flutter_client/services/torrent/torrent_download_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String hash(int n) => n.toRadixString(16).padLeft(40, '0');

void main() {
  test('progress is due at once, then every 30 seconds', () {
    final t0 = DateTime(2026, 1, 1, 12);
    expect(TorrentDownloadRegistry.progressWriteDue(null, t0), isTrue);
    expect(
        TorrentDownloadRegistry.progressWriteDue(
            t0, t0.add(const Duration(seconds: 29))),
        isFalse);
    expect(
        TorrentDownloadRegistry.progressWriteDue(
            t0, t0.add(const Duration(seconds: 30))),
        isTrue);
  });

  group('updateProgress', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> save(String h) => TorrentDownloadRegistry.save(
        h, const TorrentDownloadInfo(movieId: '1', title: 'T'));

    Future<int?> downloaded(String h) async =>
        (await TorrentDownloadRegistry.loadAll())[h]?.downloadedBytes;

    test('writes the first report, holds back the next ones', () async {
      final h = hash(1);
      await save(h);
      await TorrentDownloadRegistry.updateProgress(h, downloadedBytes: 100);
      await TorrentDownloadRegistry.updateProgress(h, downloadedBytes: 200);
      expect(await downloaded(h), 100);
      // Forced: written now.
      await TorrentDownloadRegistry.updateProgress(h,
          downloadedBytes: 300, force: true);
      expect(await downloaded(h), 300);
      await TorrentDownloadRegistry.removeAll([h]);
    });

    test('removeAll drops entries in one go', () async {
      await save(hash(2));
      await save(hash(3));
      await TorrentDownloadRegistry.removeAll([hash(2), hash(3).toUpperCase()]);
      expect(await TorrentDownloadRegistry.loadAll(), isEmpty);
    });
  });
}
