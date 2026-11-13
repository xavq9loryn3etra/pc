import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Picks a logo that shows on the app's dark backgrounds.
///
/// TMDB often has several logos for a title, some of them black — made for
/// light backgrounds, and invisible on ours — and with hardly any votes their
/// order is close to random, so a black one can come first (Godzilla Minus
/// Zero's first English logo is solid black; its other six are white).
///
/// [preferLight] moves the first English logo that isn't dark to the front of
/// a details response's logo list, where the parser takes it from. Each
/// logo's brightness is measured once, from TMDB's smallest copy (~5 KB),
/// and remembered across launches.
class LogoBrightness {
  static final LogoBrightness _instance = LogoBrightness._();
  factory LogoBrightness() => _instance;
  LogoBrightness._();

  static const _prefsKey = 'logo_brightness_v1';

  /// Below this (0–255, the average of its visible pixels) a logo counts
  /// as dark: a black logo is ~0; white ones ~245–255; coloured ones sit
  /// between (a mid-grey or a deep red, ~100+, still reads on black).
  static const int _darkBelow = 60;

  /// How many logos to try before settling for the first anyway.
  static const int _maxChecks = 4;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 4),
    responseType: ResponseType.bytes,
  ));

  Map<String, int>? _known;

  Future<Map<String, int>> _load() async {
    final known = _known;
    if (known != null) return known;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      _known = decoded is Map
          ? {
              for (final e in decoded.entries)
                if (e.value is int) e.key as String: e.value as int,
            }
          : {};
    } catch (_) {
      _known = {};
    }
    return _known!;
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_known));
    } catch (_) {}
  }

  /// In TMDB details [data] (with `images` appended): the first English
  /// logo that isn't dark, moved to the front. Leaves the list as it was
  /// when the first is fine already, none are English, or none can be
  /// measured (no connection) — never worse than before.
  Future<void> preferLight(Map<String, dynamic> data, String imageBase) async {
    final images = data['images'];
    final logos = images is Map ? images['logos'] : null;
    if (logos is! List || logos.isEmpty) return;
    final english = [
      for (final l in logos)
        if (l is Map && l['iso_639_1'] == 'en' && l['file_path'] is String) l,
    ];
    if (english.isEmpty) return;

    final known = await _load();
    var changed = false;
    Map? pick;
    for (final logo in english.take(_maxChecks)) {
      final path = logo['file_path'] as String;
      var brightness = known[path];
      if (brightness == null) {
        brightness = await _measure(imageBase, path);
        if (brightness == null) continue; // Couldn't tell: try the next.
        known[path] = brightness;
        changed = true;
      }
      if (brightness >= _darkBelow) {
        pick = logo;
        break;
      }
    }
    if (changed) _save();
    if (pick == null || identical(pick, english.first)) return;
    logos
      ..remove(pick)
      ..insert(0, pick);
  }

  /// The average brightness (0–255) of [path]'s visible pixels, from its
  /// smallest copy; null if it can't be fetched or decoded.
  Future<int?> _measure(String imageBase, String path) async {
    // TMDB serves every SVG logo as a PNG too (see the details parser).
    final png = path.toLowerCase().endsWith('.svg')
        ? '${path.substring(0, path.length - 4)}.png'
        : path;
    // imageBase ends in a size ("…/t/p/w500"); the smallest is w92.
    final small = imageBase.replaceFirst(RegExp(r'/[^/]+$'), '/w92');
    try {
      final response = await _dio.get<List<int>>('$small$png');
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      codec.dispose();
      if (data == null) return null;
      return _averageBrightness(data);
    } catch (e) {
      debugPrint('Logo brightness: $e');
      return null;
    }
  }

  /// Mean luminance of the pixels more than half opaque (the logo itself,
  /// not its transparent surround), every other pixel sampled.
  static int? _averageBrightness(ByteData rgba) {
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 3 < rgba.lengthInBytes; i += 8) {
      if (rgba.getUint8(i + 3) <= 128) continue;
      sum += 0.2126 * rgba.getUint8(i) +
          0.7152 * rgba.getUint8(i + 1) +
          0.0722 * rgba.getUint8(i + 2);
      count++;
    }
    if (count == 0) return null;
    return (sum / count).round();
  }
}
