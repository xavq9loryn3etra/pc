import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/book.dart';

class BooksService {
  static const String _baseUrl = 'https://openlibrary.org';

  Future<List<Book>> searchBooks(String query) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$_baseUrl/search.json?q=${Uri.encodeComponent(query)}&fields=key,title,author_name,cover_i,first_publish_year,ratings_average&limit=20',
        ),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final docs = data['docs'] as List;
        return docs.map((json) => Book.fromSearchJson(json)).toList();
      } else {
        throw Exception('Failed to search books: ${response.statusCode}');
      }
    } catch (e) {
      print('Error searching books: $e');
      return [];
    }
  }

  Future<List<Book>> getBooksBySubject(String subject) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/subjects/$subject.json?limit=20'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final works = data['works'] as List;
        return works.map((json) => Book.fromSubjectJson(json)).toList();
      } else {
        throw Exception('Failed to load subject books: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching subject $subject: $e');
      return [];
    }
  }

  Future<List<Book>> getTrendingBooks() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/trending/daily.json?limit=20'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final works = data['works'] as List;
        return works.map((json) => Book.fromSubjectJson(json)).toList();
      } else {
        throw Exception(
            'Failed to load trending books: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching trending books: $e');
      // Fallback to a popular subject if trending fails
      return getBooksBySubject('thriller');
    }
  }

  Future<List<Book>> getClassicBooks() async {
    return getBooksBySubject('classic_literature');
  }

  Future<Book> getBookDetails(String workId) async {
    try {
      // Ensure workId is in /works/OL... format
      final cleanId = workId.startsWith('/works/') ? workId : '/works/$workId';

      final response = await http.get(Uri.parse('$_baseUrl$cleanId.json'));

      if (response.statusCode == 200) {
        final jsonMap = json.decode(response.body);
        return Book.fromDetailsJson(jsonMap);
      } else {
        throw Exception('Failed to load book details: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching book details: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getBookEditions(String workId) async {
    try {
      final cleanId = workId.startsWith('/works/') ? workId : '/works/$workId';
      final response = await http.get(
        Uri.parse('$_baseUrl$cleanId/editions.json?limit=50'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<Map<String, dynamic>>.from(data['entries']);
      } else {
        print('Failed to load editions: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error fetching editions: $e');
      return [];
    }
  }
}
