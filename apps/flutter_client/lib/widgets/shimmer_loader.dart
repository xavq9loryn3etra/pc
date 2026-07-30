import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// App-icon loading indicator with a shimmer sweep, for full-screen/near-
/// full-screen loading states — the same treatment already used for the
/// app's own startup loading state (see main.dart's _AppScreen.checking)
/// and content-shaped skeleton screens. Not self-centering — drop it into
/// whatever `Center`/`Container` the call site already uses.
class ShimmerLoader extends StatelessWidget {
  final double size;

  const ShimmerLoader({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Image.asset(
        'assets/icon-transparent.png',
        width: size,
        height: size,
      ),
    );
  }
}
