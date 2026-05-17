import 'torrent_engine_service.dart';
import 'torrent_index_service.dart';

class StreamResolver {
  final _indexService = TorrentIndexService();
  final _engine = TorrentEngineService.instance;

  /// Get available qualities for a movie/show
  Future<List<TorrentStream>> getAvailableStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final streams = type == 'movie'
        ? await _indexService.getMovieStreams(imdbId)
        : await _indexService.getSeriesStreams(imdbId, season ?? 1, episode ?? 1);

    // Sort by a balanced score: seeders dominate, quality breaks ties.
    // This ensures we always connect to a live, fast swarm rather than
    // an almost-dead high-quality swarm that takes minutes to start.
    streams.sort((a, b) => _qualityScore(b) - _qualityScore(a));
    return streams;
  }

  /// Balanced score: seeders are unclamped and dominate; quality adds a
  /// fixed bonus (0–300 pts) only to break ties between similar swarm sizes.
  ///
  /// Examples:
  ///   4K   / 10  seeders  →  310 pts   (barely wins over 1080p/5)
  ///   1080p / 500 seeders → 700 pts   (beats 4K/300 easily)
  ///   4K   / 500 seeders  → 800 pts   (best of both worlds)
  int _qualityScore(TorrentStream stream) {
    final q = stream.quality?.toLowerCase() ?? '';
    int qualityBonus = 0;
    if (q.contains('4k') || q.contains('2160')) {
      qualityBonus = 300;
    } else if (q.contains('1080')) {
      qualityBonus = 200;
    } else if (q.contains('720')) {
      qualityBonus = 100;
    } else if (q.contains('480')) {
      qualityBonus = 50;
    }
    // Seeders are unclamped — a torrent with 2000 seeders will always win
    // over a higher-quality one with only a handful of peers.
    return qualityBonus + (stream.seeders ?? 0);
  }

  /// Resolve a specific torrent to a playable local URL
  Future<StreamResult> resolve(TorrentStream selected) async {
    return await _engine.streamMagnet(
      selected.infoHash,
      fileIndex: selected.fileIdx,
    );
  }

  /// Cleanup after playback
  void cleanup(int torrentId) => _engine.cleanup(torrentId);
}
