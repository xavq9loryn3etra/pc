/// Which info hashes a head start (TorrentEngineService.warmUp) holds, and
/// how many pages hold each — so a page cooling down only ends the head
/// start when it was the last to want it, and never touches a torrent no
/// head start started (one playing, or downloaded earlier).
class WarmOwners {
  final Map<String, int> _counts = {};

  /// Whether some head start holds [key].
  bool owns(String key) => _counts.containsKey(key);

  /// A head start begins holding [keys] (lowercase info hashes).
  void acquire(Iterable<String> keys) {
    for (final key in keys) {
      _counts[key] = (_counts[key] ?? 0) + 1;
    }
  }

  /// A head start asked for [keys] but found them already added: shares
  /// those that are held, and leaves the rest alone.
  void share(Iterable<String> keys) {
    for (final key in keys) {
      final count = _counts[key];
      if (count != null) _counts[key] = count + 1;
    }
  }

  /// One holder lets go of [key]. True when that was the last holder;
  /// false when others remain, or when [key] wasn't held at all (then it
  /// isn't a head start's to clean up).
  bool release(String key) {
    final count = _counts[key];
    if (count == null) return false;
    if (count > 1) {
      _counts[key] = count - 1;
      return false;
    }
    _counts.remove(key);
    return true;
  }

  /// Drops every hold on [key] — Play has taken the torrent over.
  void clear(String key) => _counts.remove(key);

  void clearAll() => _counts.clear();
}
