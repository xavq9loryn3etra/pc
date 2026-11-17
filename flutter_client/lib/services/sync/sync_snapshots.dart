import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'sync_data.dart';

/// The copy of this device's lists from right before a sync removed many
/// titles at once (see SyncService), so "Bring back N removed titles" can
/// undo it. Kept on the device only, in the app's own folder, and offered
/// for [undoDays].
class SyncSnapshots {
  static const int undoDays = 7;
  static const String _name = 'before-removal.json.gz';

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}sync_snapshots');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$_name');
  }

  /// Keeps [data] as the copy from before a big removal.
  static Future<void> keepBeforeRemoval(SyncData data) async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(
        gzip.encode(utf8.encode(jsonEncode(data.toJson()))), flush: true);
    await tmp.rename(file.path);
  }

  /// The copy, if there is one and it can be read.
  static Future<SyncData?> readBeforeRemoval() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final json = jsonDecode(utf8.decode(gzip.decode(await file.readAsBytes())));
      return json is Map<String, dynamic> ? SyncData.fromJson(json) : null;
    } catch (e) {
      debugPrint('Sync copy unreadable: $e');
      return null;
    }
  }

  static Future<void> dropBeforeRemoval() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
