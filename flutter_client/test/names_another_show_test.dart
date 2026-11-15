import 'package:flutter_client/services/torrent/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool other(String name) => StreamResolver.namesAnotherShow(name,
      showTitle: 'One Piece', startYear: 1999);

  test("the live-action One Piece (2023) isn't the anime", () {
    expect(other('ONE PIECE 2023 S02E03 WHISKY BUSINESS 720p HEVC x265-MeGusta'),
        isTrue);
    expect(other('One.Piece.2023.S02.1080p.NF.WEB-DL.DD+5.1.Atmos.H.264-playWEB'),
        isTrue);
    expect(other('One.Piece.(2023).S02E03.720p'), isTrue);
  });

  test("the anime's own copies still fit", () {
    expect(other('[Erai-raws] One Piece - 011 [720p][Multiple Subtitle]'),
        isFalse);
    expect(other('One Piece (1999-2000) s01e01-15 [Mkv - 1080p H264]'),
        isFalse);
    expect(other('One Piece Season 2 Complete 009 - 030 720p HDTV x264'),
        isFalse);
    expect(other('One Piece Season 1 (1999) 480p BRRip X264'), isFalse);
    expect(other('One.Piece.E0001-E1155.KOREAN.1080p.2024.WEB-DL'), isFalse);
  });

  test("a show's own start year, or one off, fits", () {
    expect(
        StreamResolver.namesAnotherShow('Doctor.Who.2005.S01E01.1080p',
            showTitle: 'Doctor Who', startYear: 2005),
        isFalse);
    expect(
        StreamResolver.namesAnotherShow('Doctor.Who.2005.S01E01.1080p',
            showTitle: 'Doctor Who', startYear: 1963),
        isTrue);
  });
}
