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
    final step = _stepParts();
    return StatusScreen(
      title: 'A New Version',
      highlight: 'Is Ready.',
      // The remote message is Android's and Windows' (flags.json); iPhones
      // update through TestFlight. While updating, what to do next (or what
      // went wrong) takes the message's place, so the screen keeps the
      // welcome screen's layout: the button never moves.
      message: Platform.isIOS
          ? 'A new update is available. Please update the app from TestFlight.'
          : widget.message,
      messageBuilder: step?.note == null
          ? null
          : (style) => Text.rich(
                TextSpan(children: [
                  TextSpan(text: step!.note),
                  // The website, when the download failed.
                  if (_step == _Step.failed && _hasValidUrl) ...[
                    const TextSpan(text: ' Or '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: GestureDetector(
                        onTap: _openWebsite,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Text(
                            'download it from the website',
                            style: style.copyWith(
                              color: Colors.white.withValues(alpha: 0.9),
                              decoration: TextDecoration.underline,
                              decorationColor:
                                  Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ]),
                textAlign: TextAlign.center,
                style: style,
              ),
      footer: step == null
          ? null
          : StatusPrimaryButton(
              label: step.label,
              onPressed: step.onPressed,
              // Downloading: the button fills as it goes.
              progress: _step == _Step.downloading ? _progress : null,
            ),
    );
  }

  /// The button's label and action for where the update's at, and what to
  /// do next, if anything; null where there's no button (an iPhone).
  ({String label, VoidCallback? onPressed, String? note})? _stepParts() {
    if (Platform.isIOS) return null;
    // Nowhere else it can update from here: the website, as before. No
    // link given either: no button, rather than a dead one.
    if (!UpdateInstaller.supported) {
      return _hasValidUrl
          ? (label: 'Download Update', onPressed: _openWebsite, note: null)
          : null;
    }
    return switch (_step) {
      _Step.ready => (label: 'Update Now', onPressed: _update, note: null),
      // The progress is in the button's label.
      _Step.downloading => (
          label: 'Downloading… ${(_progress * 100).round()}%',
          onPressed: null,
          note: null,
        ),
      _Step.needsPermission => (
          label: 'Allow Updates',
          onPressed: UpdateInstaller.openInstallPermission,
          note: 'Android asks this once: turn on "Allow from this source" '
              'for Popcorn, then come back here.',
        ),
      _Step.install => (
          label: 'Install Update',
          onPressed: _install,
          note: 'Tap Update when Android asks. Your favourites and history '
              'stay.',
        ),
      _Step.installing => (
          label: 'Installing…',
          onPressed: null,
          note: 'Popcorn will close and open again by itself.',
        ),
      _Step.failed => (
          label: 'Try Again',
          onPressed: _update,
          note: "Couldn't download the update. Check your connection.",
        ),
    };
  }
}
