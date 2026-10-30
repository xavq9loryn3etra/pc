import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../models/movie.dart';
import '../screens/details_screen.dart';
import '../services/tmdb_service.dart';
import 'details_overview.dart';
import 'episode_card.dart';
import 'movie_poster.dart';

/// A person's page, as a bottom sheet in the quality popup's style (a
/// frosted [EpisodeSheetFrame]): photo, name, what
/// they're known for, when and where they were born, their biography, and
/// the movies and shows they're best known for — tapping one opens it.
/// Opened from a title's Cast & Crew row ([CastRow]).
class PersonSheet extends StatefulWidget {
  final CastMember member;

  const PersonSheet({super.key, required this.member});

  static Future<void> show(BuildContext context, CastMember member) =>
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        barrierColor: Colors.black54,
        builder: (_) => PersonSheet(member: member),
      );

  @override
  State<PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends State<PersonSheet> {
  late final Future<Person?> _person =
      TMDBService().getPerson(widget.member.id!);

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "Born 30 Jan 1976 · Jersey, UK", from what's known.
  static String? _bornLine(Person p) {
    final date = DateTime.tryParse(p.birthday ?? '');
    final parts = [
      if (date != null)
        'Born ${date.day} ${_months[date.month - 1]} ${date.year}',
      if (p.placeOfBirth?.isNotEmpty ?? false) p.placeOfBirth!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  void _open(Movie movie) {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(builder: (_) => DetailsScreen(movie: movie)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return EpisodeSheetFrame(
      frosted: true,
      image: widget.member.profileUrl,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: FutureBuilder<Person?>(
          future: _person,
          builder: (context, snapshot) {
            final person = snapshot.data;
            final loading = snapshot.connectionState != ConnectionState.done;
            return CustomScrollView(
              shrinkWrap: true,
              // Pulling past the top drags the sheet (EpisodeSheetFrame).
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _header(person)),
                if (loading)
                  SliverToBoxAdapter(child: _loadingBody())
                else if (person == null)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 24, 24, 40),
                      child: Text(
                        "Couldn't load their details. Try again in a bit.",
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                else ...[
                  if (person.biography.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                      sliver: SliverToBoxAdapter(
                        child: ExpandableSynopsis(text: person.biography),
                      ),
                    ),
                  if (person.credits.isNotEmpty) ...[
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(24, 28, 24, 14),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          'Known For',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                          24, 0, 24, 24 + MediaQuery.paddingOf(context).bottom),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 2 / 3,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final movie = person.credits[i];
                            return MoviePoster(
                              movie: movie,
                              width: double.infinity,
                              height: double.infinity,
                              onTap: () => _open(movie),
                            );
                          },
                          childCount: person.credits.length,
                        ),
                      ),
                    ),
                  ] else
                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Photo, name, and what they're known for and when/where they were
  /// born — the name and photo straight away, from the cast row, the rest
  /// once loaded.
  Widget _header(Person? person) {
    final member = widget.member;
    final born = person == null ? null : _bornLine(person);
    final role = person?.knownFor ?? member.character;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Row(
        children: [
          PersonPhoto(url: person?.profileUrl ?? member.profileUrl, size: 96),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person?.name ?? member.name,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    height: 1.2,
                  ),
                ),
                if (role != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    role,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                ],
                if (born != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    born,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _loadingBody() {
    Widget bar(double width) => Container(
          width: width,
          height: 14,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(4),
          ),
        );
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bar(double.infinity),
            bar(double.infinity),
            bar(220),
            const SizedBox(height: 24),
            Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
