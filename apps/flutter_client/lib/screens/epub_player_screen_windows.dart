import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

class EpubPlayerScreenWindows extends StatefulWidget {
  final File file;

  const EpubPlayerScreenWindows({super.key, required this.file});

  @override
  State<EpubPlayerScreenWindows> createState() =>
      _EpubPlayerScreenWindowsState();
}

class _EpubPlayerScreenWindowsState extends State<EpubPlayerScreenWindows> {
  final _controller = WebviewController();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initWebview();
  }

  Future<void> _initWebview() async {
    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(Colors.transparent);

      // Load reader.html content
      String readerHtml = await rootBundle.loadString('assets/reader.html');

      // Load content into WebView using data URI for maximum compatibility
      final dataUri = Uri.dataFromString(
        readerHtml,
        mimeType: 'text/html',
        encoding: Encoding.getByName('utf-8'),
      ).toString();

      await _controller.loadUrl(dataUri);

      // Listen for ready state or inject directly after load
      // We'll give it a small delay to ensure DOM is ready, then inject book
      // Better way: use a message from JS to Dart, but simplifying here.

      // Also listen for messages from JS (e.g., 'onBookLoaded')
      _controller.webMessage.listen((msg) {
        if (msg == 'onBookLoaded') {
          if (mounted) setState(() => _isLoading = false);
        }
      });

      // Wait a bit for HTML to parse
      await Future.delayed(const Duration(milliseconds: 500));
      _loadBookContent();
    } catch (e) {
      debugPrint("Error initializing Windows WebView: $e");
    }
  }

  Future<void> _loadBookContent() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final base64Book = base64Encode(bytes);

      // Inject book data
      // For WebView2, we can use postMessage or executeScript
      // Our reader.html has `loadBook(base64)` function

      await _controller.executeScript('loadBook("$base64Book");');
    } catch (e) {
      debugPrint("Error loading book content on Windows: $e");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Reading"),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          Webview(_controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
