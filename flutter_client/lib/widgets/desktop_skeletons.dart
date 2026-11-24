import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// The wide home while it loads: one shimmer over the whole window, no
/// placeholder cards (owner, 24 Nov 2026). It used to be a hero-sized block
/// (95% of the height) with a row of poster cards over its foot, which left
/// a black strip along the bottom and the cards' shapes showing.
class DesktopSkeletonHome extends StatelessWidget {
  const DesktopSkeletonHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: const SizedBox.expand(child: ColoredBox(color: Colors.black)),
    );
  }
}
