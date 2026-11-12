import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/services/torrent/trim_point.dart';

void main() {
  const gb = 1024 * 1024 * 1024;

  test('keeps five minutes before the stopping point, in proportion', () {
    // 100 minutes, 1 GB; stopped at minute 50: keep from minute 45.
    final from = trimKeepFrom(
      fileSize: gb,
      position: const Duration(minutes: 50),
      duration: const Duration(minutes: 100),
    );
    expect(from, (gb * 0.45).floor());
  });

  test('keeps everything when less than five minutes were watched', () {
    expect(
      trimKeepFrom(
        fileSize: gb,
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 100),
      ),
      0,
    );
    expect(
      trimKeepFrom(
        fileSize: gb,
        position: Duration.zero,
        duration: const Duration(minutes: 100),
      ),
      0,
    );
  });

  test('does not trim when the duration or file size is unknown', () {
    expect(
      trimKeepFrom(
          fileSize: gb,
          position: const Duration(minutes: 50),
          duration: Duration.zero),
      -1,
    );
    expect(
      trimKeepFrom(
          fileSize: 0,
          position: const Duration(minutes: 50),
          duration: const Duration(minutes: 100)),
      -1,
    );
  });

  test('never goes past the end of the file', () {
    expect(
      trimKeepFrom(
        fileSize: gb,
        position: const Duration(minutes: 200),
        duration: const Duration(minutes: 100),
      ),
      gb,
    );
  });
}
