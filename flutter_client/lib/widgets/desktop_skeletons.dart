import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

class DesktopSkeletonHome extends StatelessWidget {
  const DesktopSkeletonHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        children: [
          // Desktop Hero Skeleton
          Shimmer.fromColors(
            baseColor: Colors.grey[900]!,
            highlightColor: Colors.grey[800]!,
            child: Container(
              width: double.infinity,
              height: MediaQuery.of(context).size.height * 0.95,
              color: Colors.black,
              child: Stack(
                children: [
                  // Simulate Hero Content (Left side)
                  Positioned(
                    left: 60,
                    top: MediaQuery.of(context).size.height * 0.4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 300,
                          height: 60,
                          color: Colors.black,
                        ), // Title
                        const SizedBox(height: 24),
                        Container(
                          width: 400,
                          height: 20,
                          color: Colors.black,
                        ), // Meta
                        const SizedBox(height: 24),
                        Container(
                          width: 500,
                          height: 80,
                          color: Colors.black,
                        ), // Desc
                        const SizedBox(height: 32),
                        Row(
                          children: [
                            Container(
                              width: 140,
                              height: 50,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Container(
                              width: 140,
                              height: 50,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Overlapping Lists
          Transform.translate(
            offset: const Offset(0, -150),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDesktopSkeletonSection(),
                const SizedBox(height: 40),
                _buildDesktopSkeletonSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopSkeletonSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 8),
          child: Shimmer.fromColors(
            baseColor: Colors.grey[900]!,
            highlightColor: Colors.grey[800]!,
            child: Container(
              width: 200,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 300,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 60),
            scrollDirection: Axis.horizontal,
            itemCount: 6,
            separatorBuilder: (context, index) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              return Shimmer.fromColors(
                baseColor: Colors.grey[900]!,
                highlightColor: Colors.grey[800]!,
                child: Container(
                  width: 200,
                  height: 300,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
