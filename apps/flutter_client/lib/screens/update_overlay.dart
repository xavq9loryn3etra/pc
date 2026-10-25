import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import '../widgets/status_screen.dart';

class UpdateOverlay extends StatelessWidget {
  final String message;
  final String url;

  const UpdateOverlay({super.key, required this.message, required this.url});

  @override
  Widget build(BuildContext context) {
    return StatusScreen(
      title: 'A New Version',
      highlight: 'Is Ready.',
      // The remote message and download link are for Android builds;
      // iPhones update through TestFlight.
      message: Platform.isIOS
          ? 'A new update is available. Please update the app from TestFlight.'
          : message,
      footer: Platform.isIOS
          ? null
          : StatusPrimaryButton(
              label: 'Download Update',
              onPressed: () => launchUrl(Uri.parse(url)),
            ),
    );
  }
}
