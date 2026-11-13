import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import '../widgets/status_screen.dart';

class UpdateOverlay extends StatelessWidget {
  final String message;
  final String url;

  const UpdateOverlay({super.key, required this.message, required this.url});

  bool get _hasValidUrl {
    final uri = Uri.tryParse(url.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  /// The remote link, opened only if it's a well-formed https one.
  Future<void> _openDownload() async {
    if (!_hasValidUrl) return;
    try {
      await launchUrl(Uri.parse(url.trim()));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return StatusScreen(
      title: 'A New Version',
      highlight: 'Is Ready.',
      // The remote message and download link are Android's, or Windows'
      // own (its section in flags.json); iPhones update through
      // TestFlight. No link given: no button, rather than a dead one.
      message: Platform.isIOS
          ? 'A new update is available. Please update the app from TestFlight.'
          : message,
      footer: Platform.isIOS || !_hasValidUrl
          ? null
          : StatusPrimaryButton(
              label: 'Download Update',
              onPressed: _openDownload,
            ),
    );
  }
}
