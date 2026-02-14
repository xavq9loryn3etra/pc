import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../models/movie.dart';
import '../theme/app_theme.dart';

class MoviePoster extends StatefulWidget {
  final Movie movie;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double width;
  final double height;
  final String? heroTag;
  final bool showTitle;

  const MoviePoster({
    super.key,
    required this.movie,
    this.onTap,
    this.onLongPress,
    this.width = 120,
    this.height = 180,
    this.showTitle = false,
    this.heroTag,
  });

  @override
  State<MoviePoster> createState() => _MoviePosterState();
}

class _MoviePosterState extends State<MoviePoster> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    Widget imageContent = Hero(
      tag: widget.heroTag ?? 'movie_${widget.movie.id}_${hashCode}',
      child: Container(
        width: widget.width == double.infinity ? double.infinity : widget.width,
        height:
            widget.height == double.infinity ? double.infinity : widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            (widget.movie.posterUrl != null &&
                    widget.movie.posterUrl!.isNotEmpty)
                ? (widget.movie.posterUrl!.toLowerCase().endsWith('.svg')
                    ? SvgPicture.network(
                        widget.movie.posterUrl!,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        placeholderBuilder: (context) => Shimmer.fromColors(
                          baseColor: Colors.grey[900]!,
                          highlightColor: Colors.grey[800]!,
                          child: Container(color: Colors.black),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: widget.movie.posterUrl!,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        // Multiply by 1.5 to ensure sharpness (supersample slightly)
                        memCacheHeight: ((widget.height == double.infinity
                                    ? 400
                                    : widget.height) *
                                MediaQuery.of(context).devicePixelRatio *
                                1.5)
                            .toInt(),
                        placeholder: (context, url) => Shimmer.fromColors(
                          baseColor: Colors.grey[900]!,
                          highlightColor: Colors.grey[800]!,
                          child: Container(color: Colors.black),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: Colors.grey[900],
                          child: const Center(
                            child: Icon(
                              Icons.broken_image,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                      ))
                : Container(
                    color: Colors.grey[900],
                    child: const Center(
                      child: Icon(Icons.movie, color: Colors.white24),
                    ),
                  ),
            // History Badge (S1 E1)
            if (widget.movie.currentSeason != null &&
                widget.movie.currentEpisode != null)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white24, width: 0.5),
                  ),
                  child: Text(
                    'S${widget.movie.currentSeason} E${widget.movie.currentEpisode}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

            // Progress Bar
            if (widget.movie.progress != null && widget.movie.progress! > 0)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: widget.movie.progress,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppTheme.primaryColor,
                  ),
                  minHeight: 3,
                ),
              ),
          ],
        ),
      ),
    );

    // If height is infinite (e.g. in GridView), we want the image to take available space
    // minus the text height.
    if (widget.height == double.infinity) {
      imageContent = Expanded(child: imageContent);
    }

    if (!widget.showTitle) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: _isHovered ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: imageContent,
          ),
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _isHovered ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              imageContent,
              if (widget.showTitle) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: widget.width == double.infinity ? null : widget.width,
                  child: Text(
                    widget.movie.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
