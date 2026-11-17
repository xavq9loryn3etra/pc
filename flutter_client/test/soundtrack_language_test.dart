import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/services/audio_language_service.dart';

void main() {
  group('SpokenLanguage.codeOfTrack', () {
    test("Attack on Titan's dubbed pack: 'Stereo', tagged eng", () {
      expect(SpokenLanguage.codeOfTrack('eng', 'Stereo'), 'en');
    });

    test('by tag', () {
      expect(SpokenLanguage.codeOfTrack('jpn', null), 'ja');
      expect(SpokenLanguage.codeOfTrack('JPN', ''), 'ja');
      expect(SpokenLanguage.codeOfTrack('ja', null), 'ja');
      expect(SpokenLanguage.codeOfTrack('jp', null), 'ja');
    });

    test('the name goes before the tag', () {
      expect(SpokenLanguage.codeOfTrack('eng', 'Japanese 2.0'), 'ja');
      expect(SpokenLanguage.codeOfTrack('und', 'English Dub'), 'en');
    });

    test("one that doesn't say", () {
      expect(SpokenLanguage.codeOfTrack('und', 'Stereo'), isNull);
      expect(SpokenLanguage.codeOfTrack(null, null), isNull);
      expect(SpokenLanguage.codeOfTrack('', 'AAC 5.1'), isNull);
      expect(SpokenLanguage.codeOfTrack('mul', null), isNull);
    });

    test('a language word inside another word is not it', () {
      expect(SpokenLanguage.codeOfTrack('und', 'Thaitanium mix'), isNull);
    });
  });

  group('SpokenLanguage.mayBeSame', () {
    test('Norwegian, two codes', () {
      expect(SpokenLanguage.mayBeSame('no', 'nb'), isTrue);
    });
    test('Cantonese and Mandarin, both tagged chi', () {
      expect(SpokenLanguage.mayBeSame('zh', 'cn'), isTrue);
    });
    test('English is not Japanese', () {
      expect(SpokenLanguage.mayBeSame('en', 'ja'), isFalse);
    });
  });
}
