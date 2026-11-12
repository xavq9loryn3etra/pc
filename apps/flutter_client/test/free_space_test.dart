import 'package:flutter_client/services/torrent/free_space.dart';
import 'package:flutter_test/flutter_test.dart';

const mb = 1024 * 1024;
const gb = 1024 * mb;

void main() {
  group('FreeSpace.fits', () {
    test('keeps 500 MB free', () {
      expect(FreeSpace.fits(sizeBytes: 4 * gb, freeBytes: 5 * gb), isTrue);
      expect(FreeSpace.fits(sizeBytes: 4 * gb, freeBytes: 4 * gb), isFalse);
      // Exactly at the limit still fits.
      expect(
          FreeSpace.fits(sizeBytes: 4 * gb, freeBytes: 4 * gb + 500 * mb),
          isTrue);
      expect(
          FreeSpace.fits(sizeBytes: 4 * gb, freeBytes: 4 * gb + 499 * mb),
          isFalse);
    });

    test('counts what is already downloaded', () {
      expect(
          FreeSpace.fits(sizeBytes: 20 * gb, haveBytes: 19 * gb, freeBytes: 2 * gb),
          isTrue);
      expect(FreeSpace.fits(sizeBytes: 20 * gb, freeBytes: 2 * gb), isFalse);
    });

    test('judges nothing it cannot measure', () {
      expect(FreeSpace.fits(sizeBytes: null, freeBytes: 1 * gb), isTrue);
      expect(FreeSpace.fits(sizeBytes: 50 * gb, freeBytes: null), isTrue);
    });
  });

  group('FreeSpace.isLow', () {
    test('goes low under 500 MB', () {
      expect(FreeSpace.isLow(499 * mb, wasLow: false), isTrue);
      expect(FreeSpace.isLow(500 * mb, wasLow: false), isFalse);
    });

    test('recovers only 100 MB above the limit', () {
      expect(FreeSpace.isLow(550 * mb, wasLow: true), isTrue);
      expect(FreeSpace.isLow(600 * mb, wasLow: true), isFalse);
    });
  });

  test('the not-enough-space message is readable', () {
    expect(const NotEnoughSpaceException().toString(),
        contains('Not enough free space'));
  });
}
