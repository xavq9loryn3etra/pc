import 'package:flutter_client/services/deep_link_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  (String, String)? parse(String url) => DeepLinkService.parse(Uri.parse(url));

  test('accepts a numeric id with movie or tv', () {
    expect(parse('popcorn://details?id=603&type=movie'), ('603', 'movie'));
    expect(parse('popcorn://details?id=1399&type=tv'), ('1399', 'tv'));
  });

  test('drops anything else', () {
    expect(parse('popcorn://details?id=603'), isNull);
    expect(parse('popcorn://details?type=movie'), isNull);
    expect(parse('popcorn://details?id=abc&type=movie'), isNull);
    expect(parse('popcorn://details?id=1234567890&type=movie'), isNull);
    expect(parse('popcorn://details?id=603&type=person'), isNull);
    expect(parse('popcorn://other?id=603&type=movie'), isNull);
    expect(parse('https://details?id=603&type=movie'), isNull);
  });
}
