import 'package:flutter_client/services/torrent/warm_owners.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a torrent no head start holds is never released', () {
    final owners = WarmOwners();
    expect(owners.owns('a'), isFalse);
    expect(owners.release('a'), isFalse);
  });

  test('a single holder releases it at once', () {
    final owners = WarmOwners()..acquire(['a', 'b']);
    expect(owners.release('a'), isTrue);
    expect(owners.owns('a'), isFalse);
    expect(owners.owns('b'), isTrue);
  });

  test('a second page sharing a head start keeps it alive for the first', () {
    final owners = WarmOwners()..acquire(['a', 'b', 'c']);
    // A nested page asks for the same ones and finds them added.
    owners.share(['a', 'b', 'c']);
    expect(owners.release('a'), isFalse); // Nested page leaves.
    expect(owners.owns('a'), isTrue);
    expect(owners.release('a'), isTrue); // The first page leaves.
    expect(owners.owns('a'), isFalse);
  });

  test('sharing leaves hashes that no head start holds alone', () {
    final owners = WarmOwners()..acquire(['a']);
    owners.share(['a', 'played-earlier']);
    expect(owners.owns('played-earlier'), isFalse);
    // So cooling down both from the nested page touches only the held one.
    expect(owners.release('played-earlier'), isFalse);
    expect(owners.release('a'), isFalse);
    expect(owners.release('a'), isTrue);
  });

  test('clear drops every hold', () {
    final owners = WarmOwners()
      ..acquire(['a'])
      ..acquire(['a']);
    owners.clear('a');
    expect(owners.owns('a'), isFalse);
    expect(owners.release('a'), isFalse);
  });
}
