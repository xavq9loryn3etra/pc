import 'dart:convert';

/// Everything one device shares with the others through Google Drive (see
/// SyncService): My List, watch history, episode progress, episode lengths
/// and the per-title language choices — each item with the time it last
/// changed, so any two copies can be combined the same way on every
/// device.
///
/// Each device keeps its own copy (its "page") in the user's Drive, and
/// only ever writes that one; it reads every page and combines them with
/// [merge]. Combining is per item: the most recent change wins, and a
/// removal is kept as a marker (a "tombstone") with its time, so a title
/// removed on one device doesn't come back from another's older copy.
///
/// Items are kept as plain JSON, as they're stored, so whatever a newer
/// app version adds to them is carried along untouched.
class SyncData {
  /// The version of this layout. A page written by a newer one is read but
  /// never overwritten by an older app (see SyncService).
  static const int currentFormat = 1;

  /// Sections whose items are combined by time: each item is
  /// `{'t': ms, 'v': value}` or, once removed, `{'t': ms, 'removed': true}`.
  /// - `list`: My List — key `type_id`, value the stored movie. Its time
  ///   is when it was added: the list is newest first.
  /// - `history`: Continue Watching — key `type_id`, value
  ///   `{movie, last_watched}` as SavedMoviesService keeps it.
  /// - `episodes`: progress through each episode — key `tv_id_s_e`, value a
  ///   fraction.
  /// - `settings`: language choices — key the stored setting's name, value
  ///   its text.
  static const List<String> sections = [
    'list',
    'history',
    'episodes',
    'settings',
  ];

  /// How long a removal is remembered. A device away longer than this may
  /// bring a removed title back; it's the price of the file not growing
  /// forever.
  static const Duration tombstoneLife = Duration(days: 180);

  final int format;

  /// section → key → item.
  final Map<String, Map<String, Map<String, dynamic>>> items;

  /// How long the played copy of each episode was, in seconds — key
  /// `tv_id_s_e`. A fact, not a choice, so no times: any copy will do.
  final Map<String, num> lengths;

  /// Anything else in the file (from a newer app version), carried along.
  final Map<String, dynamic> extra;

  SyncData({
    this.format = currentFormat,
    Map<String, Map<String, Map<String, dynamic>>>? items,
    Map<String, num>? lengths,
    Map<String, dynamic>? extra,
  })  : items = {
          for (final s in sections) s: {...?items?[s]},
        },
        lengths = {...?lengths},
        extra = {...?extra};

  Map<String, Map<String, dynamic>> operator [](String section) =>
      items[section]!;

  static const _known = {'format', 'lengths', ...sections};

  /// Reads a page. Anything unreadable in it is skipped, item by item:
  /// one bad entry never costs the rest.
  factory SyncData.fromJson(Map<String, dynamic> json) {
    final format = json['format'];
    final items = <String, Map<String, Map<String, dynamic>>>{};
    for (final section in sections) {
      final raw = json[section];
      final out = <String, Map<String, dynamic>>{};
      if (raw is Map) {
        for (final e in raw.entries) {
          final item = e.value;
          if (e.key is String && item is Map && item['t'] is num) {
            out[e.key as String] = Map<String, dynamic>.from(item);
          }
        }
      }
      items[section] = out;
    }
    final lengths = <String, num>{};
    final rawLengths = json['lengths'];
    if (rawLengths is Map) {
      for (final e in rawLengths.entries) {
        if (e.key is String && e.value is num) {
          lengths[e.key as String] = e.value as num;
        }
      }
    }
    return SyncData(
      format: format is int ? format : currentFormat,
      items: items,
      lengths: lengths,
      extra: {
        for (final e in json.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        ...extra,
        'format': format,
        for (final s in sections) s: items[s],
        'lengths': lengths,
      };

  static int timeOf(Map<String, dynamic> item) => (item['t'] as num).toInt();
  static bool isRemoved(Map<String, dynamic> item) => item['removed'] == true;

  /// The live (not removed) items of [section].
  Iterable<MapEntry<String, Map<String, dynamic>>> live(String section) =>
      items[section]!.entries.where((e) => !isRemoved(e.value));

  /// Of two versions of one item, the one to keep: the later; on a tie,
  /// the same one on every device (whichever's JSON sorts last).
  static Map<String, dynamic> _winner(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final ta = timeOf(a), tb = timeOf(b);
    if (ta != tb) return ta > tb ? a : b;
    return canonicalJson(a).compareTo(canonicalJson(b)) >= 0 ? a : b;
  }

  /// Combines [pages] into one: per item, the latest change. The result is
  /// the same whatever order the pages come in, and combining it again
  /// with any of them changes nothing.
  ///
  /// [now] (Google's clock) caps times from a device whose clock ran
  /// ahead, so one fast clock can't win every change for months, and ages
  /// out removals older than [tombstoneLife].
  static SyncData merge(List<SyncData> pages, {required int now}) {
    final out = SyncData(
      format: pages.fold<int>(currentFormat, (m, p) => p.format > m ? p.format : m),
    );
    // Rarely matters: extras only come from a newer app version.
    for (final p in pages) {
      out.extra.addAll(p.extra);
    }
    final ceiling = now + const Duration(minutes: 5).inMilliseconds;
    for (final section in sections) {
      final merged = out.items[section]!;
      for (final page in pages) {
        for (final e in page.items[section]!.entries) {
          var item = e.value;
          if (timeOf(item) > ceiling) item = {...item, 't': ceiling};
          final have = merged[e.key];
          merged[e.key] = have == null ? item : _winner(have, item);
        }
      }
    }
    for (final page in pages) {
      for (final e in page.lengths.entries) {
        final have = out.lengths[e.key];
        if (have == null || e.value > have) out.lengths[e.key] = e.value;
      }
    }
    out._dropEpisodesOfRemovedShows();
    out._ageOutRemovals(now);
    return out;
  }

  /// A show taken off Continue Watching takes its episodes' progress with
  /// it — what was saved before it was removed.
  void _dropEpisodesOfRemovedShows() {
    final history = items['history']!;
    final episodes = items['episodes']!;
    for (final e in history.entries) {
      if (!isRemoved(e.value) || !e.key.startsWith('tv_')) continue;
      final removedAt = timeOf(e.value);
      final prefix = '${e.key}_';
      episodes.removeWhere(
          (key, item) => key.startsWith(prefix) && timeOf(item) <= removedAt);
      if (!episodes.keys.any((k) => k.startsWith(prefix))) {
        lengths.removeWhere((key, _) => key.startsWith(prefix));
      }
    }
  }

  void _ageOutRemovals(int now) {
    final oldest = now - tombstoneLife.inMilliseconds;
    for (final section in items.values) {
      section.removeWhere(
          (_, item) => isRemoved(item) && timeOf(item) < oldest);
    }
  }

  /// Whether [other] holds exactly the same items.
  bool sameAs(SyncData other) =>
      canonicalJson(toJson()) == canonicalJson(other.toJson());

  /// [value] as JSON with every map's keys sorted, so two equal values
  /// always read the same, however they were built.
  static String canonicalJson(Object? value) => jsonEncode(_sorted(value));

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _sorted(value[k])};
    }
    if (value is List) return [for (final v in value) _sorted(v)];
    return value;
  }
}
