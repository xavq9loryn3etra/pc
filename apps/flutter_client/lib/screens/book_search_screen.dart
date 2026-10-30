import 'dart:async';
import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/books_service.dart';
import '../widgets/book_card.dart';
import 'book_details_screen.dart';
import '../widgets/custom_loader.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../services/movie_tab_service.dart';

class BookSearchScreen extends StatefulWidget {
  const BookSearchScreen({super.key});

  @override
  State<BookSearchScreen> createState() => _BookSearchScreenState();
}

class _BookSearchScreenState extends State<BookSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final BooksService _booksService = BooksService();
  final FocusNode _focusNode = FocusNode();

  List<Book> _searchResults = [];
  bool _isLoading = false;
  Timer? _debounce;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    MovieTabService().currentTab.addListener(_onActiveTabChanged);
  }

  void _onActiveTabChanged() {
    if (MovieTabService().currentTab.value == BottomNavTab.search) {
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    MovieTabService().currentTab.removeListener(_onActiveTabChanged);
    _searchController.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _errorMessage = null;
        _isLoading = false;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 600), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await _booksService.searchBooks(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isLoading = false;
          if (results.isEmpty) {
            _errorMessage = "No books found for '$query'";
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = "Error searching: $e";
        });
      }
    }
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
    return ScreenScaffold(
      bottomNavTab: BottomNavTab.search,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
        onPressed: () =>
            MovieTabService().currentTab.value = BottomNavTab.home,
      ),
      title: TextField(
        controller: _searchController,
        focusNode: _focusNode,
        onChanged: _onSearchChanged,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        decoration: const InputDecoration(
          hintText: "Search books, authors, ISBNs...",
          hintStyle: TextStyle(color: Colors.white54),
          border: InputBorder.none,
        ),
      ),
      actions: [
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.only(right: 16.0),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CustomLoader(size: 24),
            ),
          )
        else if (_searchController.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear_rounded, color: Colors.white54),
            onPressed: () {
              _searchController.clear();
              _onSearchChanged('');
            },
          ),
      ],
      body: (context, isDesktop, padding) => _buildBody(padding),
    );
  }

  Widget _buildBody(EdgeInsets padding) {
    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      if (_searchController.text.isNotEmpty && !_isLoading) {
        return const Center(
          child: Text("Use the search bar to find books",
              style: TextStyle(color: Colors.white24)),
        );
      }
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_books_rounded, size: 64, color: Colors.white10),
            SizedBox(height: 16),
            Text("Search for your next read",
                style: TextStyle(color: Colors.white24)),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: padding.copyWith(top: 16, left: 16, right: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.45,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final book = _searchResults[index];
        return BookCard(
          book: book,
          onTap: () => _navigateToDetails(book),
          width: double.infinity,
        );
      },
    );
  }
}
