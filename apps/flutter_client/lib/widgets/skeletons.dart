import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// The skeletons' shapes, built by [builder] in [color]: the shimmer's
/// grey, with its highlight sweeping across them when [animate] — or
/// still, without it. Still costs less: the shimmer draws through a layer
/// of its own on every frame, too much for a page while it slides in (see
/// DetailsScreen).
class _Shimmering extends StatelessWidget {
  final bool animate;
  final Widget Function(Color color) builder;

  const _Shimmering({required this.animate, required this.builder});

  static final _base = Colors.grey[900]!;

  @override
  Widget build(BuildContext context) {
    if (!animate) return builder(_base);
    return Shimmer.fromColors(
      baseColor: _base,
      highlightColor: Colors.grey[800]!,
      // Shimmer colours whatever it's given; black shapes take it fully.
      child: builder(Colors.black),
    );
  }
}

class SkeletonHero extends StatelessWidget {
  final bool animate;

  const SkeletonHero({super.key, this.animate = true});

  @override
  Widget build(BuildContext context) {
    return _Shimmering(
      animate: animate,
      builder: (color) => Container(
        width: double.infinity,
        height: 620, // MovieHeroBanner's
        color: color,
      ),
    );
  }
}

class SkeletonSection extends StatelessWidget {
  const SkeletonSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Shimmer.fromColors(
            baseColor: Colors.grey[900]!,
            highlightColor: Colors.grey[800]!,
            child: Container(
              width: 150,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            scrollDirection: Axis.horizontal,
            itemCount: 5,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              return Shimmer.fromColors(
                baseColor: Colors.grey[900]!,
                highlightColor: Colors.grey[800]!,
                child: Container(
                  width: 120, // Approximate width of MoviePoster
                  height: 180,
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

class SkeletonDetails extends StatelessWidget {
  /// Whether it shimmers; DetailsScreen holds it still while sliding in.
  final bool animate;

  const SkeletonDetails({super.key, this.animate = true});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonHero(animate: animate),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _Shimmering(
              animate: animate,
              builder: (color) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    height: 20,
                    color: color,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 20,
                    color: color,
                  ),
                  const SizedBox(height: 8),
                  Container(width: 200, height: 20, color: color),
                  const SizedBox(height: 32),
                  Container(
                    width: 100,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SkeletonHome extends StatelessWidget {
  const SkeletonHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        children: [
          const SkeletonHero(),
          const SizedBox(height: 20),
          const SkeletonSection(),
          const SizedBox(height: 24),
          const SkeletonSection(),
        ],
      ),
    );
  }
}
