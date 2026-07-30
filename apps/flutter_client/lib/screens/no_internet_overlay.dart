import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/shimmer_loader.dart';

class NoInternetOverlay extends StatelessWidget {
  const NoInternetOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 80,
                  color: AppTheme.primaryColor,
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'No Connection',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Please check your internet settings and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white60,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              // Optional: A subtle retry hint or button
              const ShimmerLoader(size: 40),
              const SizedBox(height: 16),
              const Text(
                'Retrying...',
                style: TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
