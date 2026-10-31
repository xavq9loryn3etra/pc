import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../models/movie.dart';
import '../screens/details_screen.dart';
import '../services/tmdb_service.dart';
import 'details_overview.dart';
import 'episode_card.dart';
import 'glass_blur.dart';
import 'movie_poster.dart';

/// A person's page, as a bottom sheet in the quality popup's style (a
/// frosted [EpisodeSheetFrame]): their photo across the top with their
/// name over it, a strip of quick facts (born, age, from), their
/// biography, and a grid of the movies and shows they're best known for,
/// to take in at a glance — tapping one opens it. Opened from a title's
/// Cast & Crew row ([CastRow]).
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

  static const _side = 24.0;

  static String _date(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year}';

  static int _yearsBetween(DateTime from, DateTime to) =>
      to.year -
      from.year -
      (to.month < from.month || (to.month == from.month && to.day < from.day)
          ? 1
          : 0);

  /// "Haverfordwest, Pembrokeshire, Wales, UK" → "Haverfordwest, UK".
  static String _shortPlace(String place) {
    final parts = place
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length <= 2) return parts.join(', ');
    return '${parts.first}, ${parts.last}';
  }

  /// The facts strip under the photo, as (label, value) pairs, from what's
  /// known.
  static List<(String, String)> _facts(Person p) {
    final born = DateTime.tryParse(p.birthday ?? '');
    final died = DateTime.tryParse(p.deathday ?? '');
    final place = p.placeOfBirth?.trim() ?? '';
    return [
      if (born != null) ('Born', _date(born)),
      if (born != null && died == null)
        ('Age', '${_yearsBetween(born, DateTime.now())}'),
      if (died != null)
        (
          born != null ? 'Died, aged ${_yearsBetween(born, died)}' : 'Died',
          _date(died),
        ),
      if (place.isNotEmpty) ('From', _shortPlace(place)),
    ];
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
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
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
                SliverToBoxAdapter(child: _hero(person)),
                if (loading)
                  SliverToBoxAdapter(child: _loadingBody())
                else if (person == null)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(_side, 20, _side, 40),
                      child: Text(
                        "Couldn't load their details. Try again in a bit.",
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(child: _intro(person)),
                  if (person.credits.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: _sectionTitle('Known For',
                          count: person.credits.length),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(_side, 0, _side,
                          24 + MediaQuery.paddingOf(context).bottom),
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

  /// Their photo across the sheet, fading into it at the bottom, with
  /// what they do and their name over it — the photo and name straight
  /// away, from the cast row, the rest once loaded. Without a photo,
  /// their initials stand in.
  Widget _hero(Person? person) {
    final member = widget.member;
    final name = person?.name ?? member.name;
    final photo = person?.profileUrl ?? member.profileUrl;
    final department = person?.knownFor;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = photo == null
          ? 200.0
          : math.min(width * 1.05, screenHeight * 0.5);
      return SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ShaderMask(
              // Fades the photo out into the sheet's glass.
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.5, 1],
                colors: [Colors.white, Colors.white, Colors.transparent],
              ).createShader(rect),
              child: photo == null
                  ? _initials(name)
                  : CachedNetworkImage(
                      imageUrl: photo,
                      fit: BoxFit.cover,
                      // Faces sit in the top part of a portrait.
                      alignment: const Alignment(0, -0.6),
                      memCacheWidth: (width * dpr).round(),
                      fadeInDuration: const Duration(milliseconds: 200),
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => _initials(name),
                    ),
            ),
            // Keeps the sheet's handle visible on a light photo.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 64,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x59000000), Colors.transparent],
                  ),
                ),
              ),
            ),
            Positioned(
              left: _side,
              right: _side,
              bottom: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (department != null) ...[
                    Text(
                      department.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      letterSpacing: -0.5,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 16)],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _initials(String name) {
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
      ),
      child: Align(
        alignment: const Alignment(0.7, -0.2),
        child: Text(
          initials,
          style: TextStyle(
            fontSize: 96,
            fontWeight: FontWeight.w800,
            color: Colors.white.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }

  /// The facts strip and biography, above the grid.
  Widget _intro(Person person) {
    final facts = _facts(person);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 20),
          _factsStrip(facts),
        ],
        if (person.biography.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(_side, 20, _side, 0),
            child: ExpandableSynopsis(text: person.biography),
          ),
      ],
    );
  }

  Widget _factsStrip(List<(String, String)> facts) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: _side),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGlassEdge),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < facts.length; i++) ...[
              if (i > 0)
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      Text(
                        facts[i].$1.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                          color: Colors.white.withValues(alpha: 0.45),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        facts[i].$2,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, {int? count}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_side, 28, _side, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _loadingBody() {
    Widget block(double width, double height, {double radius = 4}) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(radius),
          ),
        );
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_side, 20, 0, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: _side),
              child: block(double.infinity, 64, radius: 16),
            ),
            const SizedBox(height: 20),
            for (final width in [double.infinity, double.infinity, 220.0])
              Padding(
                padding: const EdgeInsets.only(right: _side, bottom: 10),
                child: block(width, 14),
              ),
            const SizedBox(height: 22),
            block(120, 20),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: _side),
              child: Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: block(double.infinity, double.infinity,
                            radius: 8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
