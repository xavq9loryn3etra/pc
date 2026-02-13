import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

class HiddenWebExtractorController {
  void Function()? onClear;

  void clear() {
    onClear?.call();
  }
}

class HiddenWebExtractor extends StatefulWidget {
  final String url;
  final Function(String) onFound;
  final VoidCallback onTimeout;
  final HiddenWebExtractorController? controller;

  const HiddenWebExtractor({
    super.key,
    required this.url,
    required this.onFound,
    required this.onTimeout,
    this.controller,
  });

  @override
  State<HiddenWebExtractor> createState() => _HiddenWebExtractorState();
}

class _HiddenWebExtractorState extends State<HiddenWebExtractor> {
  late final WebViewController _controller;
  bool _found = false;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();

    widget.controller?.onClear = () {
      if (mounted) {
        // Aggressively stop playback and remove video elements to free codecs
        _controller
            .runJavaScript('''
          (function() {
            var videos = document.getElementsByTagName('video');
            for(var i=0; i<videos.length; i++) {
              videos[i].pause();
              videos[i].src = "";
              videos[i].load();
              videos[i].remove();
            }
          })();
        ''')
            .then((_) {
              // Then navigate away
              _controller.loadRequest(Uri.parse('about:blank'));
              _controller.clearCache();
            });
      }
    };

    _timeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!_found && mounted) {
        widget.onTimeout();
      }
    });

    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      // Use iPhone User Agent to force HLS master playlist (best for quality options)
      ..setUserAgent(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            if (_found) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            _injectSniffer();
          },
          onWebResourceError: (WebResourceError error) {
            // debugPrint('Extractor Error: ${error.description}');
          },
        ),
      )
      ..addJavaScriptChannel(
        'ExtractorBridge',
        onMessageReceived: (JavaScriptMessage message) {
          if (!_found) {
            _found = true;
            setState(() {}); // Rebuild to hide WebView

            // debugPrint("Extractor: Found stream info: ${message.message}");
            widget.onFound(message.message); // Passing raw JSON string
          }
        },
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  void _injectSniffer() {
    // This script repeatedly checks for a video element with a valid src
    const String snifferScript = '''
      (function() {
        if (window.hasSniffer) return;
        window.hasSniffer = true;

        function isValidSource(src, element) {
            if (!src || !src.startsWith('http')) return false;
            // Ignore blob URLs (already handled by startsWith http check usually, but just in case)
            if (src.startsWith('blob:')) return false;
            
            // Check duration if available (skip ads < 10s)
            if (element && element.duration && element.duration > 0 && element.duration < 10) {
                return false;
            }
            
            return true;
        }

        function extractAndReturn(src, element) {
             var tracks = [];

             // Helper to format time for VTT
             function formatTime(seconds) {
                var d = new Date(seconds * 1000);
                var hh = d.getUTCHours().toString().padStart(2, '0');
                var mm = d.getUTCMinutes().toString().padStart(2, '0');
                var ss = d.getUTCSeconds().toString().padStart(2, '0');
                var ms = d.getUTCMilliseconds().toString().padStart(3, '0');
                return hh + ':' + mm + ':' + ss + '.' + ms;
             }

             if (element) {
               // 1. textTracks (includes both <track> and JS-added tracks)
               // We prefer textTracks because it contains the cues directly if loaded
               if (element.textTracks && element.textTracks.length > 0) {
                 for (var i = 0; i < element.textTracks.length; i++) {
                    var t = element.textTracks[i];
                    if (t.kind === 'subtitles' || t.kind === 'captions') {
                        // Check if it's disabled. If so, we can't get cues usually.
                        // But we can try to find a matching <track> tag for URL as fallback.
                        // For now, if it has cues, extract them.
                        if (t.cues && t.cues.length > 0) {
                             var vtt = "WEBVTT\\n\\n";
                             for (var j=0; j<t.cues.length; j++) {
                                 var cue = t.cues[j];
                                 vtt += formatTime(cue.startTime) + " --> " + formatTime(cue.endTime) + "\\n";
                                 vtt += (cue.text || '') + "\\n\\n";
                             }
                             tracks.push({
                                 'content': vtt,
                                 'label': (t.label || 'Unknown'), // + ' (TextTrack)',
                                 'language': t.language || 'en'
                             });
                        }
                    }
                 }
               }
               
               // 2. DOM <track> elements with src (Fallback/Primary if textTracks failed or empty)
               var trackNodes = element.querySelectorAll('track');
               for (var i = 0; i < trackNodes.length; i++) {
                 var t = trackNodes[i];
                 if (t.src && (t.kind === 'subtitles' || t.kind === 'captions')) {
                   // Avoid duplicates?
                   // Use label + lang as key?
                   // For now, just add. The UI can handle list.
                   tracks.push({
                     'src': t.src,
                     'label': (t.label || 'Unknown'), // + ' (URL)',
                     'language': t.srclang || 'en'
                   });
                 }
               }
             }

             var payload = {
                'url': src,
                'subtitles': tracks,
                'userAgent': navigator.userAgent,
                'headers': {
                  'Referer': window.location.href,
                  'User-Agent': navigator.userAgent
                }
             };
             // Mute and pause the video element to prevent audio/visual bleed
             var v = document.querySelector('video[src="' + src + '"]');
             if (v) {
                v.pause();
                v.muted = true;
             }
             
             window.ExtractorBridge.postMessage(JSON.stringify(payload));
        }

        function checkVideo() {
          var videos = document.getElementsByTagName('video');
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            
            if (isValidSource(v.src, v)) {
                if (window.found) return true;
                window.found = true;
                v.pause(); // Pause immediately
                setTimeout(function() { extractAndReturn(v.src, v); }, 2000);
                return true;
            }
            
            // Check child sources
            var sources = v.getElementsByTagName('source');
            for (var j = 0; j < sources.length; j++) {
               var s = sources[j];
               if (isValidSource(s.src, v)) { 
                 if (window.found) return true;
                 window.found = true;
                 v.pause(); // Pause parent
                 setTimeout(function() { extractAndReturn(s.src, v); }, 2000);
                 return true;
               }
            }
          }
          return false;
        }

        // Check every 500ms
        var interval = setInterval(function() {
          if (checkVideo()) {
            clearInterval(interval);
          }
        }, 500);
        
        // Also listen for new nodes
        var observer = new MutationObserver(function(mutations) {
          if (checkVideo()) {
            observer.disconnect();
            clearInterval(interval);
          }
        });
        observer.observe(document.body, { childList: true, subtree: true });
        
      })();
    ''';
    _controller.runJavaScript(snifferScript);
  }

  @override
  void dispose() {
    debugPrint("HiddenWebExtractor: Disposing...");
    _timeoutTimer?.cancel();
    _controller.loadRequest(Uri.parse('about:blank')); // Stop media
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If found, remove from tree immediately
    if (_found) {
      return const SizedBox.shrink();
    }

    // We keep it in the tree but invisible/small to ensure it renders and runs JS
    return SizedBox(
      width: 1,
      height: 1,
      child: WebViewWidget(controller: _controller),
    );
  }
}
