import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../models/movie.dart';
import '../../services/saved_movies_service.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

class Projector extends StatefulWidget {
  final String streamUrl;
  final Map<String, String>? headers;
  final List<Map<String, String>>? subtitles;
  final Movie movie;
  final int? season;
  final int? episode;
  final VoidCallback onClose;
  final Function(String) onError;

  const Projector({
    super.key,
    required this.streamUrl,
    this.headers,
    this.subtitles,
    required this.movie,
    this.season,
    this.episode,
    required this.onClose,
    required this.onError,
  });

  @override
  State<Projector> createState() => _ProjectorState();
}

class _ProjectorState extends State<Projector> {
  late final Player _player;
  late final VideoController _controller;
  String _currentStreamUrl = "";
  Duration? _pendingSeek; // Track seek position for quality changes

  @override
  void initState() {
    super.initState();
    _currentStreamUrl = widget.streamUrl;

    // Increase buffer size to prevent skipping/stuttering (32MB)
    _player = Player();
    _controller = VideoController(_player);

    // Hide system UI for immersive experience
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _player.open(Media(widget.streamUrl, httpHeaders: widget.headers));

    // Listen for errors
    _player.stream.error.listen((event) {
      widget.onError(event.toString());
    });

    // Listen for duration to handle pending seeks (quality switch)
    _player.stream.duration.listen((duration) async {
      if (_pendingSeek != null && duration.inSeconds > 0) {
        // Wait a small bit to ensure player is ready and won't auto-reset to 0
        await Future.delayed(const Duration(milliseconds: 500));
        await _player.seek(_pendingSeek!);
        _pendingSeek = null;
        // Ensure we play if we were playing
        if (!_player.state.playing) {
          await _player.play();
        }
      }
    });

    // Listen for progress to save history
    _player.stream.position.listen((Duration position) {
      final duration = _player.state.duration;
      if (duration.inSeconds > 0) {
        final progress = position.inSeconds / duration.inSeconds;
        // Save every 5 seconds or major change
        if (position.inSeconds % 5 == 0) {
          SavedMoviesService().addToHistory(
            widget.movie,
            season: widget.season,
            episode: widget.episode,
            progress: progress,
          );
        }
      }
    });

    // Resume if previously watched (Stub - assuming external logic handles initial seek or we add it here)
  }

  @override
  void dispose() {
    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Stop player to release resources gracefully
    // Fire and forget, but helps signal native cleanup
    _player.stop();
    _player.dispose();

    super.dispose();
  }

  List<Map<String, String>> _getVirtualTracks(String url) {
    if (url.contains('MTA4MA==')) {
      return [
        {'label': '1080p', 'url': url},
        {'label': '720p', 'url': url.replaceAll('MTA4MA==', 'NzIw')},
        {'label': '360p', 'url': url.replaceAll('MTA4MA==', 'MzYw')},
      ];
    } else if (url.contains('NzIw')) {
      return [
        {'label': '1080p', 'url': url.replaceAll('NzIw', 'MTA4MA==')},
        {'label': '720p', 'url': url},
        {'label': '360p', 'url': url.replaceAll('NzIw', 'MzYw')},
      ];
    } else if (url.contains('MzYw')) {
      return [
        {'label': '1080p', 'url': url.replaceAll('MzYw', 'MTA4MA==')},
        {'label': '720p', 'url': url.replaceAll('MzYw', 'NzIw')},
        {'label': '360p', 'url': url},
      ];
    }
    return [];
  }

  void _showQualitySettings() {
    final tracks = _player.state.tracks.video;
    final current = _player.state.track.video;

    // Sort tracks by quality (Height) descending
    // Filter out tracks with junk IDs like "no" unless they have valid resolution data
    final sortedTracks = List<VideoTrack>.from(
      tracks.where((t) => t.id != 'no' || (t.h != null && t.h! > 0)),
    );
    sortedTracks.sort((a, b) {
      final hA = a.h ?? 0;
      final hB = b.h ?? 0;
      return hB.compareTo(hA);
    });

    // Check for Virtual Tracks (Manual URL manipulation for sources like VidKing)
    final virtualTracks = _getVirtualTracks(_currentStreamUrl);
    final hasVirtual = virtualTracks.isNotEmpty;

    // If we have virtual tracks, we prioritize them because native tracks are likely "Auto" or "no"
    // due to the master playlist being hidden or non-standard.
    final useVirtual = hasVirtual;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  "Select Quality",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (sortedTracks.isEmpty && !useVirtual)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    "No quality options availble.",
                    style: TextStyle(color: Colors.white70),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: useVirtual
                        ? virtualTracks.length
                        : sortedTracks.length,
                    itemBuilder: (context, index) {
                      if (useVirtual) {
                        final track = virtualTracks[index];
                        final label = track['label']!;
                        final url = track['url']!;
                        final isSelected =
                            url == _currentStreamUrl; // Simple string match

                        return ListTile(
                          leading: isSelected
                              ? const Icon(Icons.check, color: Colors.amber)
                              : const SizedBox(width: 24),
                          title: Text(
                            label,
                            style: TextStyle(
                              color: isSelected ? Colors.amber : Colors.white,
                            ),
                          ),
                          onTap: () async {
                            if (url != _currentStreamUrl) {
                              // 1. Capture current state
                              _pendingSeek = _player.state.position;
                              final wasPlaying = _player.state.playing;

                              setState(() => _currentStreamUrl = url);
                              Navigator.pop(ctx); // Close menu immediately

                              // 2. Open new media (paused)
                              await _player.open(
                                Media(url, httpHeaders: widget.headers),
                                play: wasPlaying,
                              );

                              // 3. Seek is handled by duration listener in initState
                            } else {
                              Navigator.pop(ctx);
                            }
                          },
                        );
                      }

                      final track = sortedTracks[index];
                      final isSelected = track == current;
                      String label = "Unknown";

                      if (track.w != null && track.h != null && track.h! > 0) {
                        // VidKing style: 1080p, 720p, etc.
                        label = "${track.h}p";
                        // Optional: Append bitrate if needed, but user asked for simple "p" style
                        // if (track.bitrate != null) {
                        //   label += " (${(track.bitrate! / 1000000).toStringAsFixed(1)} Mbps)";
                        // }
                      } else if (track.id == 'auto') {
                        label = "Auto";
                      } else if (track.title != null &&
                          track.title!.isNotEmpty) {
                        label = track.title!;
                      } else {
                        // Fallback using ID if nothing else
                        label = track.id;
                      }

                      // If label is weirdly short/garbage (like "no"), make it clearer or skip?
                      // But user might want to select it if it's the only option.
                      // Let's just capitalize it if it's an ID.

                      return ListTile(
                        leading: isSelected
                            ? const Icon(Icons.check, color: Colors.amber)
                            : const SizedBox(width: 24),
                        title: Text(
                          label,
                          style: TextStyle(
                            color: isSelected ? Colors.amber : Colors.white,
                          ),
                        ),
                        onTap: () {
                          _player.setVideoTrack(track);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showSubtitleSettings() {
    final tracks = _player.state.tracks.subtitle;
    final current = _player.state.track.subtitle;
    final externalSubtitles = widget.subtitles ?? [];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  "Subtitles",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (tracks.isEmpty && externalSubtitles.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Text(
                    "No subtitles detected.",
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tracks.isNotEmpty)
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: tracks.length,
                          itemBuilder: (context, index) {
                            final track = tracks[index];
                            final isSelected = track == current;
                            String label = "";

                            if (track.id == 'auto') {
                              label = "Auto";
                            } else if (track.id == 'no') {
                              label = "Off";
                            } else if (track.title != null &&
                                track.title!.isNotEmpty) {
                              label = track.title!;
                            } else if (track.language != null) {
                              label = track.language!;
                            } else {
                              label = track.id;
                            }

                            return ListTile(
                              leading: isSelected
                                  ? const Icon(Icons.check, color: Colors.amber)
                                  : const SizedBox(width: 24),
                              title: Text(
                                label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.amber
                                      : Colors.white,
                                ),
                              ),
                              onTap: () {
                                _player.setSubtitleTrack(track);
                                Navigator.pop(ctx);
                              },
                            );
                          },
                        ),
                      if (externalSubtitles.isNotEmpty) ...[
                        if (tracks.isNotEmpty)
                          const Divider(color: Colors.white24),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: 8.0,
                            horizontal: 16.0,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              "External",
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: externalSubtitles.length,
                          itemBuilder: (context, index) {
                            final sub = externalSubtitles[index];
                            final url = sub['src'];
                            final content = sub['content'];
                            final label = sub['label'] ?? 'Unknown';
                            final language = sub['language'];

                            // Check selection
                            final isSelected = current.title == label;

                            return ListTile(
                              leading: isSelected
                                  ? const Icon(Icons.check, color: Colors.amber)
                                  : const SizedBox(width: 24),
                              title: Text(
                                "$label ${language != null ? '($language)' : ''}",
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.amber
                                      : Colors.white,
                                ),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                if (content != null) {
                                  _player.setSubtitleTrack(
                                    SubtitleTrack.data(
                                      content,
                                      title: label,
                                      language: language,
                                    ),
                                  );
                                } else if (url != null) {
                                  _loadExternalSubtitle(url, label, language);
                                }
                              },
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.white24, height: 1),
              ListTile(
                leading: const Icon(Icons.folder_open, color: Colors.white),
                title: const Text(
                  "Load from device...",
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickSubtitle();
                },
              ),
              ListTile(
                leading: const Icon(Icons.search, color: Colors.white),
                title: const Text(
                  "Search OpenSubtitles...",
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _searchOpenSubtitles();
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _loadExternalSubtitle(
    String url,
    String label,
    String? language,
  ) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Loading subtitle...")));

    try {
      final dio = Dio();
      final response = await dio.get(
        url,
        options: Options(
          headers: widget.headers,
          responseType: ResponseType.plain,
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        await _player.setSubtitleTrack(
          SubtitleTrack.data(
            response.data.toString(),
            title: label,
            language: language,
          ),
        );
      } else {
        throw Exception("Failed to load subtitle");
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error loading subtitle: $e")));
      }
    }
  }

  Future<void> _searchOpenSubtitles() async {
    String url;
    if (widget.movie.imdbId != null && widget.movie.imdbId!.isNotEmpty) {
      url =
          "https://www.opensubtitles.org/en/search/sublanguageid-all/imdbid-${widget.movie.imdbId}";
    } else {
      final query = Uri.encodeComponent(widget.movie.title);
      url =
          "https://www.opensubtitles.org/en/search/sublanguageid-all/moviename-$query";
    }

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not launch browser")),
        );
      }
    }
  }

  Future<void> _pickSubtitle() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt', 'ass', 'ssa'],
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        // Use Uri.file to create a file URI
        final fileUri = Uri.file(filePath).toString();

        await _player.setSubtitleTrack(
          SubtitleTrack.uri(fileUri, title: "Local File", language: "en"),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Loaded: ${result.files.single.name}")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error picking file: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Video(
          controller: _controller,
          wakelock: true,
          controls: (state) {
            return MaterialVideoControlsTheme(
              normal: MaterialVideoControlsThemeData(
                topButtonBar: [
                  const SizedBox(width: 14),
                  SafeArea(
                    top: true,
                    left: true,
                    right: true,
                    bottom: false,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const Spacer(),
                  SafeArea(
                    top: true,
                    left: true,
                    right: true,
                    bottom: false,
                    child: IconButton(
                      icon: const Icon(
                        Icons.closed_caption,
                        color: Colors.white,
                      ),
                      onPressed: _showSubtitleSettings,
                    ),
                  ),
                  SafeArea(
                    top: true,
                    left: true,
                    right: true,
                    bottom: false,
                    child: IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white),
                      onPressed: _showQualitySettings,
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
              ),
              fullscreen: MaterialVideoControlsThemeData(
                topButtonBar: [
                  const SizedBox(width: 14),
                  SafeArea(
                    top: true,
                    left: true,
                    right: true,
                    bottom: false,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const Spacer(),
                  SafeArea(
                    top: true,
                    left: true,
                    right: true,
                    bottom: false,
                    child: IconButton(
                      icon: const Icon(
                        Icons.closed_caption,
                        color: Colors.white,
                      ),
                      onPressed: _showSubtitleSettings,
                    ),
                  ),
                  SafeArea(
                    top: true,
                    left: true,
                    right: true,
                    bottom: false,
                    child: IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white),
                      onPressed: _showQualitySettings,
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
              ),
              child: MaterialVideoControls(state),
            );
          },
        ),
      ),
    );
  }
}
