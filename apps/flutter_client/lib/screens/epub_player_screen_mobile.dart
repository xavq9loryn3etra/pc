import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../widgets/shimmer_loader.dart';

class EpubPlayerScreenMobile extends StatefulWidget {
  final File file;

  const EpubPlayerScreenMobile({super.key, required this.file});

  @override
  State<EpubPlayerScreenMobile> createState() => _EpubPlayerScreenMobileState();
}

class _EpubPlayerScreenMobileState extends State<EpubPlayerScreenMobile> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            _loadBookContent();
          },
        ),
      );

    try {
      String fileText = await rootBundle.loadString('assets/reader.html');
      _controller.loadHtmlString(fileText);
    } catch (e) {
      debugPrint("Error loading reader.html: $e");
    }
  }

  Future<void> _loadBookContent() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final base64Book = base64Encode(bytes);

      // Inject the book data into the WebView
      await _controller.runJavaScript('loadBook("$base64Book");');

      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint("Error loading book content: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
            "Reading"), // Title metadata hard to extract from raw bytes without parsing
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: ShimmerLoader(),
            ),
        ],
      ),
    );
  }
}
