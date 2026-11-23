import 'package:flutter_client/services/subtitle_service.dart';
import 'package:flutter_client/services/torrent/built_in_subtitles.dart';
import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_client/services/torrent/torrent_index_service.dart';
import 'package:flutter_client/services/tv_device.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String hash(int n) => n.toRadixString(16).padLeft(40, '0');

TorrentStream stream(int n, String name, String size, {int seeders = 100}) =>
    TorrentStream.fromRelease(
      infoHash: hash(n),
      name: name,
      sizeBytes: (double.parse(size) * 1024 * 1024 * 1024).round(),
      seeders: seeders,
      source: 'test',
    );

Set<String> named(String name) =>
    BuiltInSubtitles.namedSubtitles(stream(1, name, '1'));

List<String> order(List<TorrentStream> streams) =>
    StreamResolver.qualityOptions(streams)
        .single
        .streams
        .map((s) => s.infoHash)
        .toList();

SubtitleTrackData track(String lang, {String? label}) => SubtitleTrackData(
    id: 'embedded:$lang', url: '1', lang: lang, label: label, isEmbedded: true);

/// The settings with the subtitle language [choice] (null: never chosen).
Future<void> subtitlesIn(String? choice) async {
  SharedPreferences.setMockInitialValues({
    if (choice != null) 'player_subtitle_lang': choice,
  });
  BuiltInSubtitles.debugReset();
  await BuiltInSubtitles.init();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TvDevice.debugIsTv = false;
    BuiltInSubtitles.debugReset();
  });

  group('namedSubtitles', () {
    test('ESub is English', () {
      expect(named('Movie 2026 1080p WEB-DL Hindi DD5.1 x264 ESub'), {'en'});
      expect(named('Movie.2026.1080p.WEB-DL.x264-ESubs'), {'en'});
      expect(named('Movie 2026 720p HDRip E-Subs'), {'en'});
    });

    test('multi-subs are several', () {
      expect(named('Movie 2026 1080p BluRay x264 MSubs'),
          {BuiltInSubtitles.multi});
      expect(
          named('Movie.2026.1080p.WEB.Multi-Subs'), {BuiltInSubtitles.multi});
      expect(named('Movie 2026 1080p MultiSub x265'), {BuiltInSubtitles.multi});
      expect(named('Movie 2026 1080p MULTi SUBS'), {BuiltInSubtitles.multi});
      expect(named('Movie 2026 1080p M-Sub'), {BuiltInSubtitles.multi});
    });

    test('a language before or after', () {
      expect(named('Movie 2026 1080p English Subs'), {'en'});
      expect(named('Movie.2026.1080p.Eng.Sub'), {'en'});
      expect(named('Movie 2026 1080p ENG-SUB'), {'en'});
      expect(named('Movie 2026 1080p EngSubs'), {'en'});
      expect(named('Movie 2026 1080p Spanish Subtitles'), {'es'});
      expect(named('Movie 2026 720p Sinhala Subtitles'), {'si'});
      expect(named('Movie 2026 1080p Eng+Ita Subs'), {'en', 'it'});
      expect(named('Movie 2026 1080p Sub Ita'), {'it'});
      expect(named('Movie 2026 1080p Subs-English'), {'en'});
    });

    test('only the language right before, with no list joining them', () {
      // Hindi audio, English subtitles.
      expect(named('Movie 2026 1080p Hindi English Subs'), {'en'});
    });

    test('on their own: English', () {
      expect(named('Movie 2026 1080p WEB-DL Subs'), {'en'});
      expect(named('Show S01E01 1080p Subbed'), {'en'});
      expect(named('Movie (2026) [1080p] [Subtitles]'), {'en'});
    });

    test('nothing to do with subtitles', () {
      expect(named('Movie 2026 1080p WEB-DL x264'), isEmpty);
      expect(named('[SubsPlease] Show - 01 (1080p)'), isEmpty);
      expect(named('[HorribleSubs] Show - 01 [720p]'), isEmpty);
      expect(named('Subway Stories 1997 720p'), isEmpty);
      expect(named('The Substance 2024 1080p WEB'), isEmpty);
      expect(named('Movie 2026 1080p No Subs'), isEmpty);
      expect(named('Movie 2026 1080p HC HardSub'), isEmpty);
      expect(named('Movie 2026 1080p Hard-Subbed'), isEmpty);
      // "No" and "It" aren't languages here.
      expect(named('Movie 2026 It Sub'), isEmpty);
    });

    test("a season pack's episode file counts", () {
      final pack = TorrentStream.fromJson({
        'infoHash': hash(7),
        'name': 'Torrentio\n1080p',
        'title': 'Show S01 1080p WEB-DL\n'
            'Show.S01E01.1080p.WEB-DL.ESub.mkv\n'
            '👤 50 💾 1.1 GB ⚙️ test',
      });
      expect(BuiltInSubtitles.namedSubtitles(pack), {'en'});
    });
  });

  group('wantedFrom', () {
    test('as the player has it', () {
      expect(BuiltInSubtitles.wantedFrom(null), 'en');
      expect(BuiltInSubtitles.wantedFrom(''), null);
      expect(BuiltInSubtitles.wantedFrom('eng'), 'en');
      expect(BuiltInSubtitles.wantedFrom('spa'), 'es');
      expect(BuiltInSubtitles.wantedFrom('sin'), 'si');
      expect(BuiltInSubtitles.wantedFrom('English'), 'en');
      expect(BuiltInSubtitles.wantedFrom('pob'), 'pt');
    });
  });

  group('rank', () {
    test('known before named before neither; nothing when off', () async {
      await subtitlesIn('eng');
      final known = stream(1, 'Movie 2026 1080p WEB-DL x264', '2');
      final esub = stream(2, 'Movie 2026 1080p WEB-DL ESub', '2');
      final multi = stream(3, 'Movie 2026 1080p WEB-DL MSubs', '2');
      final plain = stream(4, 'Movie 2026 1080p WEB-DL x265', '2');
      BuiltInSubtitles.noteTracks(known.infoHash, [track('eng')]);
      await Future<void>.delayed(Duration.zero);
      expect(BuiltInSubtitles.rank(known), 0);
      expect(BuiltInSubtitles.rank(esub), 1);
      expect(BuiltInSubtitles.rank(multi), 1);
      expect(BuiltInSubtitles.rank(plain), 2);

      // ESub is English only; multi-subs count for any language.
      expect(BuiltInSubtitles.rank(esub, 'es'), 2);
      expect(BuiltInSubtitles.rank(multi, 'es'), 1);
      expect(BuiltInSubtitles.rank(known, 'es'), 2);

      await subtitlesIn('');
      expect(BuiltInSubtitles.rank(esub), 0);
      expect(BuiltInSubtitles.rank(plain), 0);
    });

    test('forced and signs tracks are not remembered', () async {
      await subtitlesIn('eng');
      final s = stream(1, 'Movie 2026 1080p WEB-DL x264', '2');
      BuiltInSubtitles.noteTracks(s.infoHash, [
        track('eng', label: 'Forced'),
        track('eng', label: 'Signs & Songs'),
        track('und'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(BuiltInSubtitles.knownIn(s.infoHash), isEmpty);
      BuiltInSubtitles.noteTracks(
          s.infoHash, [track('spa'), track('eng', label: 'English SDH')]);
      await Future<void>.delayed(Duration.zero);
      expect(BuiltInSubtitles.knownIn(s.infoHash), {'en', 'es'});
    });

    test('remembered across a restart', () async {
      await subtitlesIn('spa');
      BuiltInSubtitles.noteTracks(hash(9), [track('spa')]);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('built_in_subtitles_v1');
      expect(saved, ['${hash(9)}=es']);
      SharedPreferences.setMockInitialValues({
        'player_subtitle_lang': 'spa',
        'built_in_subtitles_v1': saved!,
      });
      BuiltInSubtitles.debugReset();
      await BuiltInSubtitles.init();
      expect(BuiltInSubtitles.knownIn(hash(9)), {'es'});
    });

    test("the player's change is seen at once", () async {
      await subtitlesIn('eng');
      expect(BuiltInSubtitles.wantedLanguage, 'en');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('player_subtitle_lang', '');
      expect(BuiltInSubtitles.wantedLanguage, null);
      await prefs.setString('player_subtitle_lang', 'fre');
      expect(BuiltInSubtitles.wantedLanguage, 'fr');
    });
  });

  group('ordering copies', () {
    test(
        'a larger copy with English subtitles goes before a smaller one '
        'without', () async {
      await subtitlesIn('eng');
      final plain = stream(1, 'Movie 2026 1080p WEB-DL x264', '1.5');
      final esub = stream(2, 'Movie 2026 1080p WEB-DL x264 ESub', '2.5');
      expect(order([plain, esub]), [esub.infoHash, plain.infoHash]);
    });

    test('one seen to have them goes before one named as having them',
        () async {
      await subtitlesIn('eng');
      final esub = stream(1, 'Movie 2026 1080p WEB-DL ESub', '1.5');
      final seen = stream(2, 'Movie 2026 1080p BluRay x264', '3');
      BuiltInSubtitles.noteTracks(seen.infoHash, [track('eng')]);
      await Future<void>.delayed(Duration.zero);
      expect(order([esub, seen]), [seen.infoHash, esub.infoHash]);
    });

    test('subtitles off: smallest first as before', () async {
      await subtitlesIn('');
      final plain = stream(1, 'Movie 2026 1080p WEB-DL x264', '1.5');
      final esub = stream(2, 'Movie 2026 1080p WEB-DL x264 ESub', '2.5');
      expect(order([esub, plain]), [plain.infoHash, esub.infoHash]);
    });

    test('Spanish subtitles wanted: ESub does not count', () async {
      await subtitlesIn('spa');
      final plain = stream(1, 'Movie 2026 1080p WEB-DL x264', '1.5');
      final esub = stream(2, 'Movie 2026 1080p WEB-DL x264 ESub', '2.5');
      final multi = stream(3, 'Movie 2026 1080p WEB-DL x264 MSubs', '3');
      expect(order([plain, esub, multi]),
          [multi.infoHash, plain.infoHash, esub.infoHash]);
    });

    test('a barely-shared copy with subtitles does not jump a healthy one',
        () async {
      await subtitlesIn('eng');
      final plain =
          stream(1, 'Movie 2026 1080p WEB-DL x264', '1.5', seeders: 300);
      final esub = stream(2, 'Movie 2026 1080p WEB-DL ESub', '1.0', seeders: 2);
      expect(order([esub, plain]), [plain.infoHash, esub.infoHash]);
    });

    test('never across qualities', () async {
      await subtitlesIn('eng');
      final hd = stream(1, 'Movie 2026 720p WEB-DL ESub', '1');
      final fhd = stream(2, 'Movie 2026 1080p WEB-DL x264', '2');
      final options = StreamResolver.qualityOptions([hd, fhd]);
      expect(options.map((o) => o.tier), [3, 2]);
      expect(StreamResolver.sameQuality(fhd, [hd, fhd]).map((s) => s.infoHash),
          [fhd.infoHash]);
    });

    test('the last-played copy still goes first', () async {
      await subtitlesIn('eng');
      final plain = stream(1, 'Movie 2026 1080p WEB-DL x264', '1.5');
      final esub = stream(2, 'Movie 2026 1080p WEB-DL ESub', '1.0');
      expect(
          StreamResolver.qualityOptions([plain, esub],
                  preferHash: plain.infoHash)
              .single
              .best
              .infoHash,
          plain.infoHash);
    });

    test('on a TV, picture comes before subtitles', () async {
      TvDevice.debugIsTv = true;
      await subtitlesIn('eng');
      final dvSub = stream(1, 'Movie 2026 2160p WEB-DL DV ESub', '12');
      final hdr = stream(2, 'Movie 2026 2160p WEB-DL HDR10', '18');
      expect(order([dvSub, hdr]), [hdr.infoHash, dvSub.infoHash]);
    });

    test('subtitles come before the episode-or-pack choice', () async {
      await subtitlesIn('eng');
      final single = TorrentStream.fromJson({
        'infoHash': hash(1),
        'name': 'Torrentio\n1080p',
        'title': 'Show.S01E01.1080p.WEB-DL.x264\n👤 80 💾 1.0 GB ⚙️ test',
      });
      final pack = TorrentStream.fromJson({
        'infoHash': hash(2),
        'name': 'Torrentio\n1080p',
        'title': 'Show S01 1080p WEB-DL ESub\n'
            'Show.S01E01.1080p.WEB-DL.mkv\n'
            '👤 80 💾 1.2 GB ⚙️ test',
      });
      expect(order([single, pack]), [pack.infoHash, single.infoHash]);
    });
  });
}
