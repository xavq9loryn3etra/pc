import 'dart:io';
import 'package:flutter/material.dart';
import 'epub_player_screen_mobile.dart';
import 'epub_player_screen_windows.dart';

class EpubPlayerScreen extends StatelessWidget {
  final File file;

  const EpubPlayerScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return EpubPlayerScreenWindows(file: file);
    }
    // Default to mobile (Android/iOS/macOS typically uses webview_flutter)
    return EpubPlayerScreenMobile(file: file);
  }
}
