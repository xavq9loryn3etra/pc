import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '../services/update_installer.dart';
import '../widgets/status_screen.dart';

/// Where the update is up to (see [UpdateOverlay]).
enum _Step {
  /// "Update Now" not pressed yet.
  ready,
  downloading,

  /// Android: Popcorn must be allowed to install apps first.
  needsPermission,

  /// Android: downloaded; Android's installer asks to confirm.
  install,

  /// Windows: the installer is taking over.
  installing,
  failed,
}

class UpdateOverlay extends StatefulWidget {
  final String message;
  final String url;

  const UpdateOverlay({super.key, required this.message, required this.url});

  @override
  State<UpdateOverlay> createState() => _UpdateOverlayState();
}

class _UpdateOverlayState extends State<UpdateOverlay>
    with WidgetsBindingObserver {
  _Step _step = _Step.ready;
  double _progress = 0;
  File? _downloaded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _hasValidUrl {
    final uri = Uri.tryParse(widget.url.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  /// The website, as before: where the update can't be installed from
  /// here, or the download failed.
  Future<void> _openWebsite() async {
    if (!_hasValidUrl) return;
    try {
      await launchUrl(Uri.parse(widget.url.trim()));
    } catch (_) {}
  }

  Future<void> _update() async {
    setState(() {
      _step = _Step.downloading;
      _progress = 0;
    });
    try {
      final file = await UpdateInstaller.download(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      _downloaded = file;
      if (!mounted) return;
      await _install();
    } catch (e) {
      debugPrint('Update download failed: $e');
      if (mounted) setState(() => _step = _Step.failed);
    }
  }

  Future<void> _install() async {
    final file = _downloaded;
    if (file == null) return _update();
    if (!await UpdateInstaller.canInstall()) {
      if (mounted) setState(() => _step = _Step.needsPermission);
      return;
    }
    if (!mounted) return;
    setState(() =>
        _step = Platform.isWindows ? _Step.installing : _Step.install);
    try {
      await UpdateInstaller.install(file);
    } catch (e) {
      debugPrint('Starting the update failed: $e');
      if (mounted) setState(() => _step = _Step.failed);
    }
  }

  /// Back from Settings: once allowed, straight on to installing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        _step != _Step.needsPermission) {
      return;
    }
    UpdateInstaller.canInstall().then((allowed) {
      if (allowed && mounted && _step == _Step.needsPermission) _install();
    });
  }

  @override
  Widget build(BuildContext context) {
    return StatusScreen(
      title: 'A New Version',
      highlight: 'Is Ready.',
      // The remote message is Android's and Windows' (flags.json); iPhones
      // update through TestFlight.
      message: Platform.isIOS
          ? 'A new update is available. Please update the app from TestFlight.'
          : widget.message,
      footer: _footer(),
    );
  }

  Widget? _footer() {
    if (Platform.isIOS) return null;
    // Nowhere else it can update from here: the website, as before. No
    // link given either: no button, rather than a dead one.
    if (!UpdateInstaller.supported) {
      return _hasValidUrl
          ? StatusPrimaryButton(
              label: 'Download Update', onPressed: _openWebsite)
          : null;
    }

    final (String label, VoidCallback? onPressed, String? note) =
        switch (_step) {
      _Step.ready => ('Update Now', _update, null),
      _Step.downloading => (
          'Downloading… ${(_progress * 100).round()}%',
          null,
          null,
        ),
      _Step.needsPermission => (
          'Allow Updates',
          UpdateInstaller.openInstallPermission,
          'Android asks this once: turn on "Allow from this source" for '
              'Popcorn, then come back here.',
        ),
      _Step.install => (
          'Install Update',
          _install,
          'Tap Update when Android asks. Your favourites and history stay.',
        ),
      _Step.installing => (
          'Installing…',
          null,
          'Popcorn will close and open again by itself.',
        ),
      _Step.failed => (
          'Try Again',
          _update,
          "Couldn't download the update. Check your connection.",
        ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusPrimaryButton(label: label, onPressed: onPressed),
        if (_step == _Step.downloading) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 4,
                color: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.15),
              ),
            ),
          ),
        ],
        if (note != null) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Text(
              note,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
        if (_step == _Step.failed && _hasValidUrl)
          TextButton(
            onPressed: _openWebsite,
            child: Text(
              'Or download it from the website',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.85),
                decoration: TextDecoration.underline,
                decorationColor: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ),
      ],
    );
  }
}
