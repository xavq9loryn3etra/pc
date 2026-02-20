import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/books_service.dart';
import '../widgets/custom_app_bar.dart';
import '../widgets/section_header.dart';
import '../widgets/book_card.dart';
import '../widgets/book_skeletons.dart';
import 'book_details_screen.dart';
import 'book_search_screen.dart';

class BooksHomeScreen extends StatefulWidget {
  const BooksHomeScreen({super.key});

  @override
  State<BooksHomeScreen> createState() => _BooksHomeScreenState();
}

class _BooksHomeScreenState extends State<BooksHomeScreen> {
  final ScrollController _scrollController = ScrollController();
  final BooksService _booksService = BooksService();
  double _scrollOffset = 0.0;

  // Future caching to prevent reload on scroll/rebuild
  late Future<List<Book>> _trendingBooks;
  late Future<List<Book>> _classicBooks;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _trendingBooks = _booksService.getTrendingBooks();
    _classicBooks = _booksService.getClassicBooks();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    setState(() => _scrollOffset = _scrollController.offset);
  }

  void _navigateToDetails(Book book) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => BookDetailsScreen(book: book),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: CustomAppBar(
        scrollOffset: _scrollOffset,
        showActions: true,
        onSearchTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const BookSearchScreen()),
          );
        },
        title: Row(
          children: [
            Image.asset(
              'assets/book-app-logo.png',
              height: 32,
            ),
          ],
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF2D1B0E), // Deep warm brown for "Books" feel
              Colors.black,
            ],
            stops: [0.0, 0.3],
          ),
        ),
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 80,
            bottom: 40,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: "Trending Now"),
              _buildHorizontalList(_trendingBooks),

              const SizedBox(height: 24),

              const SectionHeader(title: "Classic Literature"),
              _buildHorizontalList(_classicBooks),

              // Add more sections as needed (e.g., Romance, Sci-Fi)
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalList(Future<List<Book>> future) {
    return SizedBox(
      height: 260, // Height for Card + Text
      child: FutureBuilder<List<Book>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const BookSkeletonList();
          } else if (snapshot.hasError) {
            return Center(
                child: Text("Error: ${snapshot.error}",
                    style: const TextStyle(color: Colors.white54)));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(
                child: Text("No books found",
                    style: TextStyle(color: Colors.white54)));
          }

          final books = snapshot.data!;
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            scrollDirection: Axis.horizontal,
            itemCount: books.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0), // Space for shadow
                child: BookCard(
                  book: books[index],
                  onTap: () => _navigateToDetails(books[index]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
