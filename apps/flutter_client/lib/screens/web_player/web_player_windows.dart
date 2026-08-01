import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'web_player_platform_interface.dart';
import '../../services/saved_movies_service.dart';
import '../../widgets/shimmer_loader.dart';

class WebPlayerWindows extends WebPlayerPlatform {
  const WebPlayerWindows({
    super.key,
    required super.initialUrl,
    required super.onClose,
    required super.movie,
    super.season,
    super.episode,
    super.episodes,
    super.seasons,
    required super.details,
  });

  @override
  State<WebPlayerWindows> createState() => _WebPlayerWindowsState();
}

class _WebPlayerWindowsState extends State<WebPlayerWindows> {
  final _controller = WebviewController();
  bool _initialized = false;
  int _lastUpdate = 0;

  bool _showControls = false;
  Timer? _hideTimer;
  StreamSubscription? _webMessageSub;

  @override
  void initState() {
    super.initState();
    _initWebview();
  }

  Future<void> _initWebview() async {
    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(Colors.transparent);
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.setUserAgent(
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");

      _webMessageSub = _controller.webMessage.listen((msg) {
        _handleMessage(msg);
      });

      /*
      // HTML Shell - Removed to fix playback on strict players
      final String htmlContent = '''...''';
      await _controller.loadStringContent(htmlContent);
      */

      await _controller.loadUrl(widget.initialUrl);

      if (mounted) setState(() => _initialized = true);

      // Inject tracking script after a short delay to allow page load
      // Windows WebView2 doesn't have a reliable "onPageFinished" for direct loadUrl in Single Page Apps
      // So we poll.
      _injectTrackingScript();
    } catch (e) {
      print("Error creating webview: $e");
    }
  }

  Future<void> _injectTrackingScript() async {
    // Get saved progress
    double startProgress = 0.0;
    final service = SavedMoviesService();
    if (widget.season != null && widget.episode != null) {
      startProgress = service.getEpisodeProgress(
            widget.movie.id,
            widget.season!,
            widget.episode!,
          ) ??
          0.0;
    } else {
      final m = service.getMovieFromHistory(widget.movie.id);
      if (m != null) startProgress = m.progress ?? 0.0;
    }

    print(
        "DEBUG: Opening player for movie=${widget.movie.id} title=${widget.movie.title}");
    print("DEBUG: startProgress=$startProgress");

    // Check if we can execute script
    // We will loop a few times to ensure injection works
    for (int i = 0; i < 5; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;

      try {
        await _controller.executeScript("""
            (function() {
              // Always update the start position for this video
              window.flutterPlayerStartProgress = $startProgress;
              
              // Only inject listeners once
              if (window.flutterTrackingActive) {
                console.log("Tracking already active, position updated to: " + (window.flutterPlayerStartProgress * 100) + "%");
                return;
              }
              window.flutterTrackingActive = true;
              
              // Helper to post messages
              function postMsg(data) {
                if (window.chrome && window.chrome.webview) {
                   window.chrome.webview.postMessage(JSON.stringify(data));
                }
              }

              // Hover for controls
              window.addEventListener('mousemove', () => postMsg({type: 'hover'}), true);
              window.addEventListener('click', () => postMsg({type: 'hover'}), true);

              // Find video element (simple search first, then Shadow DOM if needed)
              function findVideo() {
                let v = document.querySelector('video');
                if (v) return v;
                
                // Check one level of Shadow DOM
                const elements = document.querySelectorAll('*');
                for (let el of elements) {
                  if (el.shadowRoot) {
                    v = el.shadowRoot.querySelector('video');
                    if (v) return v;
                  }
                }
                return null;
              }

              function setupTracking() {
                const video = findVideo();
                if (!video) {
                  setTimeout(setupTracking, 1000);
                  return;
                }

                console.log("Video found! Setting up tracking...");
                let hasResumed = false;

                // Resume to saved position ONCE
                function resume() {
                  const startProg = window.flutterPlayerStartProgress || 0;
                  if (hasResumed || startProg < 0.01 || startProg > 0.95) return;
                  
                  if (video.duration && Number.isFinite(video.duration)) {
                    video.currentTime = startProg * video.duration;
                    hasResumed = true;
                    console.log("Resumed to: " + video.currentTime + "s");
                  }
                }

                // Try to resume after metadata loads
                if (video.readyState >= 1) {
                  setTimeout(resume, 500);
                } else {
                  video.addEventListener('loadedmetadata', () => setTimeout(resume, 500), {once: true});
                }

                // Track progress every 5 seconds
                let lastSave = 0;
                video.addEventListener('timeupdate', () => {
                  const now = Date.now();
                  if (now - lastSave > 5000 && video.duration > 60) {
                    lastSave = now;
                    postMsg({
                      type: 'timeupdate',
                      currentTime: video.currentTime,
                      duration: video.duration
                    });
                  }
                });

                // Save immediately on pause
                video.addEventListener('pause', () => {
                  if (video.duration > 60) {
                    postMsg({
                      type: 'pause',
                      currentTime: video.currentTime,
                      duration: video.duration
                    });
                  }
                });
              }

              setupTracking();
            })();
          """);
      } catch (e) {
        print("Script injection attempt $i error: $e");
      }
    }
  }

  void _handleMessage(dynamic msg) {
    try {
      dynamic data = msg;
      if (msg is String) {
        try {
          data = jsonDecode(msg);
        } catch (e) {
          return;
        }
      }

      if (data is Map) {
        final type = data['type'];
        print("DEBUG: Received message type: $type");

        if (type == 'hover') {
          _onHover();
        } else if (type == 'pause') {
          // Save immediately on pause
          final double currentTime = (data['currentTime'] as num).toDouble();
          final double total = (data['duration'] as num).toDouble();
          print(
              "DEBUG: Pause event - currentTime=$currentTime, duration=$total");
          if (total > 60) {
            final double progress = currentTime / total;
            print("DEBUG: Attempting pause save with progress=$progress");
            _saveProgress(progress);
          } else {
            print("DEBUG: Skipping pause save - duration too short");
          }
        } else if (type == 'timeupdate') {
          // Periodic saves during playback
          final double currentTime = (data['currentTime'] as num).toDouble();
          final double total = (data['duration'] as num).toDouble();

          if (total > 60) {
            final double progress = currentTime / total;
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - _lastUpdate > 4000) {
              print("DEBUG: Periodic save with progress=$progress");
              _saveProgress(progress);
              _lastUpdate = now;
            }
          }
        }
      }
    } catch (e) {
      print("DEBUG: Message handler error: $e");
    }
  }

  void _saveProgress(double progress) {
    print(
        "DEBUG: _saveProgress called with progress=$progress, mounted=$mounted");
    if (!mounted) {
      print("DEBUG: Save blocked - widget not mounted");
      return;
    }
    print(
        "DEBUG: Calling SavedMoviesService.addToHistory for movie=${widget.movie.id}");
    SavedMoviesService().addToHistory(
      widget.movie,
      season: widget.season,
      episode: widget.episode,
      progress: progress,
    );
  }

  void _onHover() {
    setState(() {
      _showControls = true;
    });
    _startHideTimer();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _webMessageSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _onHover(),
        child: Stack(
          children: [
            _initialized
                ? Webview(_controller)
                : const Center(child: ShimmerLoader()),
            Positioned(
              top: 10,
              left: 10,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: _showControls ? widget.onClose : null,
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
