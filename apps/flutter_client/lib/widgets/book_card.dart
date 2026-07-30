import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../models/book.dart';

class BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;
  final double width;
  final double height;

  const BookCard({
    super.key,
    required this.book,
    required this.onTap,
    this.width = 120,
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: book.coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: book.coverUrl!,
                      httpHeaders: const {
                        'User-Agent':
                            'PC_Flutter_Client/1.0 (megha@example.com)', // OpenLibrary requests a contact User-Agent
                      },
                      fit: BoxFit.cover,
                      // Cover art in a scrollable grid — cap decode to the
                      // tile size instead of the source cover's native size.
                      // Only height is constrained (not width too) — specifying
                      // both distorts covers whose aspect ratio isn't exactly
                      // 2:3, since ResizeImagePolicy.exact stretches to fit
                      // both dimensions regardless of the source's own ratio.
                      memCacheHeight:
                          (height * MediaQuery.of(context).devicePixelRatio)
                              .toInt(),
                      placeholder: (context, url) => Shimmer.fromColors(
                        baseColor: Colors.grey[800]!,
                        highlightColor: Colors.grey[700]!,
                        child: Container(color: Colors.black),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[900],
                        child: const Icon(Icons.book, color: Colors.white24),
                      ),
                    )
                  : Container(
                      color: Colors.grey[900],
                      child: const Center(
                        child:
                            Icon(Icons.book, color: Colors.white24, size: 40),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: width,
            child: Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          SizedBox(
            width: width,
            child: Text(
              book.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
