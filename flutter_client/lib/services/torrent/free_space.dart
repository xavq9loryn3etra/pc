import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'torrent_paths.dart';

/// Thrown when no copy of a title fits in the space the device has left.
class NotEnoughSpaceException implements Exception {
  const NotEnoughSpaceException();

  @override
  String toString() =>
      'Not enough free space on this device. Free up some storage and try again.';
}

/// How much room the device has left for downloads, and what to do about it.
class FreeSpace {
  static const _channel = MethodChannel('popcorn/device');

  /// Always left free: filling the disk to the last byte breaks the app
  /// and the phone.
  static const int reserveBytes = 500 * 1024 * 1024; // 500 MB

  /// Playback pauses below [reserveBytes] and carries on only once this much
  /// is free again, so a disk hovering at the limit doesn't flip each check.
  static const int recoverBytes = reserveBytes + 100 * 1024 * 1024;

  /// Free bytes on the disk holding the torrents folder, or null when the
  /// platform can't say (then nothing is held back).
  static Future<int?> bytes() async {
    try {
      final path = await _existingAncestor(await TorrentPaths.torrentsDir());
      if (Platform.isAndroid || Platform.isIOS) {
        return await _channel.invokeMethod<int>('freeBytes', {'path': path});
      }
      if (Platform.isWindows) return _windowsFreeBytes(path);
    } catch (e) {
      print('Error reading free disk space: $e');
    }
    return null;
  }

  // The torrents folder may not exist yet; its disk is its parent's.
  static Future<String> _existingAncestor(String path) async {
    var dir = Directory(path);
    while (!await dir.exists() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return dir.path;
  }

  static int? _windowsFreeBytes(String path) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getDiskFreeSpaceEx = kernel32.lookupFunction<
        Int32 Function(
            Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>)>('GetDiskFreeSpaceExW');
    final dir = path.toNativeUtf16();
    final available = calloc<Uint64>();
    final total = calloc<Uint64>();
    final totalFree = calloc<Uint64>();
    try {
      final ok = getDiskFreeSpaceEx(dir, available, total, totalFree);
      return ok == 0 ? null : available.value;
    } finally {
      calloc.free(dir);
      calloc.free(available);
      calloc.free(total);
      calloc.free(totalFree);
    }
  }

  /// Whether a download of [sizeBytes], of which [haveBytes] is already on
  /// disk, fits in [freeBytes] while still leaving [reserveBytes]. Unknown
  /// sizes or free space always fit: nothing to judge by.
  static bool fits({
    required int? sizeBytes,
    int haveBytes = 0,
    required int? freeBytes,
  }) {
    if (sizeBytes == null || freeBytes == null) return true;
    final needed = sizeBytes - haveBytes;
    return needed <= freeBytes - reserveBytes;
  }

  /// Whether [freeBytes] is too little to keep downloading, given whether
  /// it was [wasLow] at the last check (see [recoverBytes]).
  static bool isLow(int freeBytes, {required bool wasLow}) =>
      freeBytes < (wasLow ? recoverBytes : reserveBytes);
}
