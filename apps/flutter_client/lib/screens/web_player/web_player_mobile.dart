import 'package:flutter/material.dart';
import 'dart:convert'; // For jsonDecode
import 'web_player_platform_interface.dart';
import 'hidden_web_extractor.dart';
import 'projector.dart';

class WebPlayerMobile extends WebPlayerPlatform {
  const WebPlayerMobile({
    super.key,
    required super.initialUrl,
    required super.onClose,
    required super.movie,
    super.season,
    super.episode,
  });

  @override
  State<WebPlayerMobile> createState() => _WebPlayerMobileState();
}

class _WebPlayerMobileState extends State<WebPlayerMobile> {
  // Extraction State
  bool _isLoading = true;
  String? _error;

  final HiddenWebExtractorController _extractorController =
      HiddenWebExtractorController();

  @override
  void initState() {
    super.initState();
  }

  Future<void> _onStreamFound(String jsonPayload) async {
    try {
      final data = jsonDecode(jsonPayload);
      if (mounted) {
        // 1. Clear the WebView immediately
        _extractorController.clear();

        // Give time for WebView to stop playback and release codecs
        // This prevents "OMX.Exynos.avc.dec" resource contention crashes on Android
        await Future.delayed(const Duration(milliseconds: 2000));

        if (!mounted) return;

        // 2. Navigate to Projector (Destroying this route and the WebView)
        final streamUrl = data['url'];
        final headers = data['headers'] != null
            ? Map<String, String>.from(data['headers'])
            : null;
        final subtitles = data['subtitles'] != null
            ? (data['subtitles'] as List)
                  .map((e) => Map<String, String>.from(e))
                  .toList()
            : null;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => Projector(
              streamUrl: streamUrl,
              headers: headers,
              subtitles: subtitles,
              movie: widget.movie,
              season: widget.season,
              episode: widget.episode,
              onClose: () => Navigator.of(context).pop(),
              onError: (err) {
                // On Playback Error, reload the WebPlayerMobile to retry extraction
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => WebPlayerMobile(
                      initialUrl: widget.initialUrl,
                      onClose: widget.onClose,
                      movie: widget.movie,
                      season: widget.season,
                      episode: widget.episode,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _extractorController.clear();
        // Fallback for legacy raw strings
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => Projector(
              streamUrl: jsonPayload,
              movie: widget.movie,
              season: widget.season,
              episode: widget.episode,
              onClose: () => Navigator.of(context).pop(),
              onError: (err) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => WebPlayerMobile(
                      initialUrl: widget.initialUrl,
                      onClose: widget.onClose,
                      movie: widget.movie,
                      season: widget.season,
                      episode: widget.episode,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    }
  }

  void _onExtractionTimeout() {
    if (mounted) {
      setState(() {
        _error = "Could not extract video stream. Please try another server.";
        _isLoading = false;
      });
    }
  }

  void _resetState() {
    if (mounted) {
      setState(() {
        _error = null;
        _isLoading = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // If not error, show loading/extractor. If error, show error.

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.amber, size: 48),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _resetState,
                    child: const Text("Retry"),
                  ),
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: widget.onClose,
                    child: const Text("Back"),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Loading + Extractor
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Hidden Extractor (Opacity 0 to be safe, contained in SizedBox)
          Opacity(
            opacity: 0.0,
            child: Align(
              alignment: Alignment.center,
              child: SizedBox(
                width: 1,
                height: 1,
                child: HiddenWebExtractor(
                  key: ValueKey(_isLoading ? DateTime.now() : 'static_key'),
                  controller: _extractorController,
                  url: widget.initialUrl,
                  onFound: _onStreamFound,
                  onTimeout: _onExtractionTimeout,
                ),
              ),
            ),
          ),

          // UI Overlay
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Colors.amber),
                      const SizedBox(height: 20),
                      const Text(
                        "Analyzing Stream...",
                        style: TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          "Please wait while we bypass protections.",
                          style: TextStyle(color: Colors.white30, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 40),
                      TextButton(
                        onPressed: widget.onClose,
                        child: const Text("Cancel"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
