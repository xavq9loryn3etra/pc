import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

class BookSkeletonCard extends StatelessWidget {
  const BookSkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cover Image Placeholder
          Container(
            width: 120,
            height: 180,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(height: 8),
          // Title Line 1
          Container(
            width: 100,
            height: 14,
            color: Colors.black,
          ),
          const SizedBox(height: 4),
          // Title Line 2 (shorter)
          Container(
            width: 60,
            height: 14,
            color: Colors.black,
          ),
          const SizedBox(height: 8),
          // Author Line
          Container(
            width: 80,
            height: 10,
            color: Colors.black,
          ),
        ],
      ),
    );
  }
}

class BookSkeletonList extends StatelessWidget {
  const BookSkeletonList({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      scrollDirection: Axis.horizontal,
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(width: 16),
      itemBuilder: (_, __) => const BookSkeletonCard(),
    );
  }
}

class BookDescriptionSkeleton extends StatelessWidget {
  const BookDescriptionSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            height: 14,
            color: Colors.black,
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            height: 14,
            color: Colors.black,
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            height: 14,
            color: Colors.black,
          ),
          const SizedBox(height: 8),
          Container(
            width: 200,
            height: 14,
            color: Colors.black,
          ),
        ],
      ),
    );
  }
}
