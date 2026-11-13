/// How much video a download keeps before the point the viewer stopped at.
const Duration trimKeepBefore = Duration(minutes: 5);

/// The byte offset in a video file from which a closed download keeps its
/// data: [trimKeepBefore] before the point the viewer stopped at ([position]
/// of [duration]), judged by proportion of the [fileSize]. Everything after
/// it is kept too (what was downloaded ahead).
///
/// Returns -1 — don't trim — when the duration or the file size isn't known
/// (zero or negative); 0 (keep it all) when less than [trimKeepBefore] was
/// watched.
int trimKeepFrom({
  required int fileSize,
  required Duration position,
  required Duration duration,
  Duration keepBefore = trimKeepBefore,
}) {
  if (fileSize <= 0 || duration <= Duration.zero) return -1;
  final seconds = position.inMilliseconds / 1000 - keepBefore.inSeconds;
  if (seconds <= 0) return 0;
  final total = duration.inMilliseconds / 1000;
  final from = (fileSize * (seconds / total)).floor();
  return from.clamp(0, fileSize);
}
