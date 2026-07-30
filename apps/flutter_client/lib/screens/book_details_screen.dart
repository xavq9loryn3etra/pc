import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/book.dart';
import '../services/books_service.dart';
import '../widgets/book_skeletons.dart';
import 'epub_player_screen.dart';
import '../widgets/custom_loader.dart';

class BookDetailsScreen extends StatefulWidget {
  final Book book;

  const BookDetailsScreen({super.key, required this.book});

  @override
  State<BookDetailsScreen> createState() => _BookDetailsScreenState();
}

class _BookDetailsScreenState extends State<BookDetailsScreen> {
  final BooksService _booksService = BooksService();
  bool _isLoading = false;
  bool _isFetchingDetails = true;
  Book? _detailedBook;

  @override
  void initState() {
    super.initState();
    _fetchDetails();
  }

  Future<void> _fetchDetails() async {
    try {
      final details = await _booksService.getBookDetails(widget.book.id);
      if (mounted) {
        setState(() {
          // Merge details with existing info (keep cover if missing in details)
          _detailedBook = details.copyWith(
            author: widget.book
                .author, // Details often misses author name, keep from search
            coverUrl: details.coverUrl ?? widget.book.coverUrl,
          );
        });
      }
    } catch (e) {
      print('Error fetching details: $e');
    } finally {
      if (mounted) {
        setState(() => _isFetchingDetails = false);
      }
    }
  }

  Future<void> _handleRead() async {
    setState(() => _isLoading = true);

    try {
      // 1. Fetch editions to find a readable version (IA ID)
      String? downloadUrl;
      try {
        final editions = await _booksService.getBookEditions(widget.book.id);

        // Find first edition with an IA identifier
        final readableEdition = editions.firstWhere(
          (e) => (e['ocaid'] != null || e['ia'] != null),
          orElse: () => {},
        );

        if (readableEdition.isNotEmpty) {
          final iaId = readableEdition['ocaid'] ?? readableEdition['ia'];
          // Construct Internet Archive download URL
          // Format: https://archive.org/download/<id>/<id>.epub
          downloadUrl = 'https://archive.org/download/$iaId/$iaId.epub';
          print('Found readable edition: $iaId');
        }
      } catch (e) {
        print('Error finding readable edition: $e');
      }

      // 2. Fallback to sample if no real book found (for demo purposes)
      if (downloadUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Real copy not found. Opening sample book...'),
            duration: Duration(seconds: 2),
          ),
        );
        // Use a reliable Project Gutenberg link (Romeo and Juliet)
        downloadUrl = 'https://www.gutenberg.org/cache/epub/1513/pg1513.epub';
      }

      // 3. Download the file
      print('Downloading book from: $downloadUrl');
      final response = await http.get(
        Uri.parse(downloadUrl),
        headers: {'User-Agent': 'PC_Flutter_Client/1.0 (megha@example.com)'},
      );

      if (response.statusCode == 200) {
        final dir = await getTemporaryDirectory();
        // Use a unique name or overwrite temp_book.epub
        final file = File('${dir.path}/current_book.epub');
        await file.writeAsBytes(response.bodyBytes);

        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EpubPlayerScreen(file: file),
            ),
          );
        }
      } else {
        // If the constructed URL fails (e.g. 404 because epub doesn't exist for that IA item), try fallback
        if (downloadUrl.contains('archive.org')) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Book file not available. Opening sample...')),
          );
          // TODO: Retry with sample if real book fails?
          // For now, let it fail so user knows.
        }

        throw Exception(
            'Failed to download book: ${response.statusCode} from $downloadUrl');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening book: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _detailedBook ?? widget.book;

    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 400,
            backgroundColor: Colors.black,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Blurred Background
                  if (book.coverUrl != null)
                    Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl: book.coverUrl!,
                          httpHeaders: const {
                            'User-Agent':
                                'PC_Flutter_Client/1.0 (megha@example.com)',
                          },
                          fit: BoxFit.cover,
                          // This copy is blurred (BackdropFilter below), so a
                          // reduced decode resolution costs nothing visually.
                          memCacheWidth: (MediaQuery.of(context).size.width *
                                  MediaQuery.of(context).devicePixelRatio)
                              .toInt(),
                        ),
                        Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black45,
                                Colors.black,
                              ],
                              stops: [0.0, 1.0],
                            ),
                          ),
                        ),
                        BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            color: Colors.black.withOpacity(0.3),
                          ),
                        ),
                      ],
                    ),

                  // Main Content
                  Center(
                    child: Container(
                      width: 180,
                      height: 270,
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: book.coverUrl != null
                            ? CachedNetworkImage(
                                imageUrl: book.coverUrl!,
                                fit: BoxFit.cover,
                                // Only height constrained — see book_card.dart
                                // for why width isn't also capped here.
                                memCacheHeight: (270 *
                                        MediaQuery.of(context).devicePixelRatio)
                                    .toInt(),
                              )
                            : Container(color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontFamily: 'Merriweather',
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    book.author,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white70,
                        ),
                  ),
                  const SizedBox(height: 24),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _handleRead,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child:
                                      CustomLoader(size: 24))
                              : const Icon(Icons.menu_book),
                          label:
                              Text(_isLoading ? 'Downloading...' : 'Read Now'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            textStyle:
                                const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      IconButton.filledTonal(
                        onPressed: () {}, // TODO: Favorites
                        icon: const Icon(Icons.favorite_border),
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),
                  const Text(
                    "Synopsis",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Merriweather',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_isFetchingDetails)
                    const BookDescriptionSkeleton()
                  else
                    Text(
                      book.description ?? 'No description available.',
                      style: const TextStyle(
                        color: Colors.white70,
                        height: 1.6,
                        fontSize: 15,
                      ),
                    ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
