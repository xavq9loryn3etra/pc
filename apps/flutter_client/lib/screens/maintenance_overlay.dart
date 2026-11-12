import 'package:flutter/material.dart';
import '../widgets/status_screen.dart';

class MaintenanceOverlay extends StatefulWidget {
  final String message;

  /// Checks again whether maintenance is over (a failed fetch leaves the
  /// last known state, and with it this screen, in place).
  final Future<void> Function()? onRetry;

  const MaintenanceOverlay({super.key, required this.message, this.onRetry});

  @override
  State<MaintenanceOverlay> createState() => _MaintenanceOverlayState();
}

class _MaintenanceOverlayState extends State<MaintenanceOverlay> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry!();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StatusScreen(
      title: "We'll Be",
      highlight: 'Right Back.',
      message: widget.message,
      footer: widget.onRetry == null
          ? null
          : StatusPrimaryButton(
              label: _retrying ? 'Checking…' : 'Try Again',
              onPressed: _retry,
            ),
    );
  }
}
