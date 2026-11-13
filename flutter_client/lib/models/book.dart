class Book {
  final String id;
  final String title;
  final String author;
  final String? coverUrl;
  final int? firstPublishYear;
  final String? description;
  final double? rating;

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.coverUrl,
    this.firstPublishYear,
    this.description,
    this.rating,
  });

  // Factory for Search API results (docs)
  factory Book.fromSearchJson(Map<String, dynamic> json) {
    String? cover;
    if (json.containsKey('cover_i') &&
        json['cover_i'] != null &&
        json['cover_i'] != -1) {
      cover = 'https://covers.openlibrary.org/b/id/${json['cover_i']}-L.jpg';
    }

    String authorName = 'Unknown Author';
    if (json.containsKey('author_name') &&
        (json['author_name'] as List).isNotEmpty) {
      authorName = (json['author_name'] as List).first.toString();
    }

    return Book(
      id: json['key'] ?? '',
      title: json['title'] ?? 'Untitled',
      author: authorName,
      coverUrl: cover,
      firstPublishYear: json['first_publish_year'],
      rating: json['ratings_average'] != null
          ? (json['ratings_average'] as num).toDouble()
          : null,
    );
  }

  // Factory for Subject API results (works)
  factory Book.fromSubjectJson(Map<String, dynamic> json) {
    String? cover;
    if (json.containsKey('cover_id') &&
        json['cover_id'] != null &&
        json['cover_id'] != -1) {
      cover = 'https://covers.openlibrary.org/b/id/${json['cover_id']}-L.jpg';
    } else if (json.containsKey('cover_i') &&
        json['cover_i'] != null &&
        json['cover_i'] != -1) {
      cover = 'https://covers.openlibrary.org/b/id/${json['cover_i']}-L.jpg';
    } else if (json.containsKey('cover_edition_key') &&
        json['cover_edition_key'] != null) {
      cover =
          'https://covers.openlibrary.org/b/olid/${json['cover_edition_key']}-L.jpg';
    }

    String authorName = 'Unknown Author';
    if (json.containsKey('authors') && (json['authors'] as List).isNotEmpty) {
      authorName = json['authors'][0]['name'] ?? 'Unknown Author';
    } else if (json.containsKey('author_name') &&
        (json['author_name'] as List).isNotEmpty) {
      authorName = (json['author_name'] as List).first.toString();
    }

    return Book(
      id: json['key'] ?? '',
      title: json['title'] ?? 'Untitled',
      author: authorName,
      coverUrl: cover,
      firstPublishYear: json['first_publish_year'],
    );
  }

  // Factory for Work Details API
  factory Book.fromDetailsJson(Map<String, dynamic> json) {
    String? cover;
    if (json.containsKey('covers') &&
        (json['covers'] as List).isNotEmpty &&
        json['covers'][0] != null &&
        json['covers'][0] != -1) {
      cover = 'https://covers.openlibrary.org/b/id/${json['covers'][0]}-L.jpg';
    }

    String desc = 'No description available.';
    if (json['description'] is String) {
      desc = json['description'];
    } else if (json['description'] is Map) {
      desc = json['description']['value'] ?? 'No description available.';
    }

    // Authors are references in details usually, so we might keep existing author or fetch separately
    // For this model we'll default to Unknown if not provided (usually client merges this)

    return Book(
      id: json['key'] ?? '',
      title: json['title'] ?? 'Untitled',
      author:
          'Unknown Author', // Placeholder, usually updated from previous state
      coverUrl: cover,
      description: desc,
    );
  }

  Book copyWith({
    String? id,
    String? title,
    String? author,
    String? coverUrl,
    int? firstPublishYear,
    String? description,
    double? rating,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      firstPublishYear: firstPublishYear ?? this.firstPublishYear,
      description: description ?? this.description,
      rating: rating ?? this.rating,
    );
  }
}
