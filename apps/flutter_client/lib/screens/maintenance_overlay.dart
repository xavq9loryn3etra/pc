import 'package:flutter/material.dart';
import '../widgets/status_screen.dart';

class MaintenanceOverlay extends StatelessWidget {
  final String message;

  const MaintenanceOverlay({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return StatusScreen(
      title: "We'll Be",
      highlight: 'Right Back.',
      message: message,
    );
  }
}
