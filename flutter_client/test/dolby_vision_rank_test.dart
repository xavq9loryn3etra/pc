import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_client/services/tv_device.dart';
import 'package:flutter_test/flutter_test.dart';

String hash(int n) => n.toRadixString(16).padLeft(40, '0');

TorrentStream stream(int n, String name, String size, {int seeders = 100}) =>
    TorrentStream.fromRelease(
      infoHash: hash(n),
      name: name,
      sizeBytes: (double.parse(size) * 1024 * 1024 * 1024).round(),
      seeders: seeders,
      source: 'test',
    );

bool dvOnly(String name) =>
    StreamResolver.isDolbyVisionOnly(stream(1, name, '1'));

List<String> order(List<TorrentStream> streams) =>
    StreamResolver.qualityOptions(streams)
        .single
        .streams
        .map((s) => s.infoHash)
        .toList();

void main() {
  tearDown(() => TvDevice.debugIsTv = false);

  group('isDolbyVisionOnly', () {
    test('Dolby Vision with no HDR', () {
      expect(dvOnly('Movie.2026.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265-GRP'), true);
      expect(dvOnly('Movie 2026 2160p WEB-DL DV HEVC'), true);
      expect(dvOnly('Movie.2026.2160p.DoVi.x265-GRP'), true);
      expect(dvOnly('Movie 2026 2160p Dolby Vision WEB-DL'), true);
      expect(dvOnly('Movie.2026.2160p.Dolby.Vision.WEB-DL'), true);
      expect(dvOnly('Movie.2026.2160p.DolbyVision.WEB-DL'), true);
      expect(dvOnly('Movie [2160p] [dv] [WEB-DL]'), true);
      // HDRip is an HD rip, not HDR.
      expect(dvOnly('Movie.2026.1080p.DV.HDRip'), true);
    });

    test('Dolby Vision with an HDR picture too', () {
      expect(dvOnly('Movie.2026.2160p.WEB-DL.DV.HDR.H.265-GRP'), false);
      expect(dvOnly('Movie 2026 2160p DV HDR10 WEB-DL'), false);
      expect(dvOnly('Movie.2026.2160p.HDR10+.DV.x265'), false);
      expect(dvOnly('Movie.2026.2160p.DV.HDR10Plus.x265'), false);
      expect(dvOnly('Movie 2026 2160p Dolby Vision HDR WEB-DL'), false);
      expect(dvOnly('Movie.2026.2160p.DoVi.HLG.x265'), false);
    });

    test('no Dolby Vision at all', () {
      expect(dvOnly('Movie.2026.2160p.WEB-DL.HDR.H.265'), false);
      expect(dvOnly('Movie 2026 1080p BluRay x264'), false);
      expect(dvOnly('Movie.1999.DVDRip.XviD'), false);
      expect(dvOnly('Movie 1999 DVD 480p'), false);
      expect(dvOnly('Movie.2026.1080p.HDV.x264'), false);
      expect(dvOnly('Movie.2026.DV5.1080p'), false);
      expect(dvOnly('Advent 2026 1080p WEB'), false);
    });

    test("a season pack's episode file counts", () {
      final pack = TorrentStream.fromJson({
        'infoHash': hash(7),
        'name': 'Torrentio\n4k',
        'title': 'Show S01 2160p WEB-DL\n'
            'Show.S01E01.2160p.WEB-DL.DV.H.265.mkv\n'
            '👤 50 💾 6.1 GB ⚙️ test',
      });
      expect(pack.isPack, true);
      expect(StreamResolver.isDolbyVisionOnly(pack), true);
    });
  });

  group('pictureRank', () {
    test('marks Dolby-Vision-only down on a TV only', () {
      final dv = stream(1, 'Movie 2026 2160p WEB-DL DV', '10');
      final hdr = stream(2, 'Movie 2026 2160p WEB-DL DV HDR', '10');
      expect(StreamResolver.pictureRank(dv, onTv: true), 1);
      expect(StreamResolver.pictureRank(dv, onTv: false), 0);
      expect(StreamResolver.pictureRank(hdr, onTv: true), 0);
    });
  });

  group('on a TV', () {
    setUp(() => TvDevice.debugIsTv = true);

    test('a larger copy without Dolby Vision goes before a Dolby-Vision-only '
        'one of the same quality', () {
      final dv = stream(1, 'Movie 2026 2160p WEB-DL DV H.265', '12');
      final hdr = stream(2, 'Movie 2026 2160p WEB-DL HDR10 H.265', '18');
      expect(order([dv, hdr]), [hdr.infoHash, dv.infoHash]);
    });

    test('"DV HDR" copies keep their place by size', () {
      final dvHdr = stream(1, 'Movie 2026 2160p WEB-DL DV HDR H.265', '12');
      final hdr = stream(2, 'Movie 2026 2160p WEB-DL HDR10 H.265', '18');
      expect(order([hdr, dvHdr]), [dvHdr.infoHash, hdr.infoHash]);
    });

    test('a barely-shared copy without Dolby Vision does not jump a healthy '
        'Dolby-Vision-only one', () {
      final dv = stream(1, 'Movie 2026 2160p WEB-DL DV', '12', seeders: 300);
      final hdr = stream(2, 'Movie 2026 2160p WEB-DL HDR', '18', seeders: 2);
      expect(order([hdr, dv]), [dv.infoHash, hdr.infoHash]);
    });

    test('a Dolby-Vision-only copy is still played when it is the only one',
        () {
      final dv = stream(1, 'Movie 2026 2160p WEB-DL DV', '12');
      final options = StreamResolver.qualityOptions([dv]);
      expect(options.single.best.infoHash, dv.infoHash);
      expect(StreamResolver.likelyPick([dv])!.infoHash, dv.infoHash);
    });

    test('fallbacks try the copy without Dolby Vision first', () {
      final dv = stream(1, 'Movie 2026 2160p WEB-DL DV', '12');
      final dv2 = stream(2, 'Movie 2026 2160p BluRay DoVi', '20');
      final hdr = stream(3, 'Movie 2026 2160p BluRay HDR10', '30');
      expect(
          StreamResolver.sameQuality(dv, [dv, dv2, hdr])
              .map((s) => s.infoHash),
          [dv.infoHash, hdr.infoHash, dv2.infoHash]);
    });

    test('a season pack without Dolby Vision goes before a Dolby-Vision-only '
        'single episode', () {
      final single = TorrentStream.fromJson({
        'infoHash': hash(1),
        'name': 'Torrentio\n4k',
        'title': 'Show.S01E01.2160p.WEB-DL.DV.H.265\n👤 80 💾 5.0 GB ⚙️ test',
      });
      final pack = TorrentStream.fromJson({
        'infoHash': hash(2),
        'name': 'Torrentio\n4k',
        'title': 'Show S01 2160p WEB-DL HDR10\n'
            'Show.S01E01.2160p.WEB-DL.HDR10.H.265.mkv\n'
            '👤 80 💾 6.0 GB ⚙️ test',
      });
      expect(order([single, pack]), [pack.infoHash, single.infoHash]);
    });

    test('AV1 is still marked down', () {
      final av1 = stream(1, 'Movie 2026 1080p WEB AV1', '0.8');
      final x264 = stream(2, 'Movie 2026 1080p WEB x264', '2.0');
      expect(order([av1, x264]), [x264.infoHash, av1.infoHash]);
    });
  });

  test('on a phone, a smaller Dolby-Vision-only copy still goes first', () {
    TvDevice.debugIsTv = false;
    final dv = stream(1, 'Movie 2026 2160p WEB-DL DV H.265', '12');
    final hdr = stream(2, 'Movie 2026 2160p WEB-DL HDR10 H.265', '18');
    expect(order([hdr, dv]), [dv.infoHash, hdr.infoHash]);
  });
}
