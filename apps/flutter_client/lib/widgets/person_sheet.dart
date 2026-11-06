import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../models/movie.dart';
import '../screens/details_screen.dart';
import '../services/tmdb_service.dart';
import 'artwork_glow.dart';
import 'details_overview.dart';
import 'episode_card.dart';
import 'glass_blur.dart';
import 'movie_poster.dart';

/// A person's page, as a bottom sheet in the quality popup's frosted style
/// ([EpisodeSheetFrame]): a scene from the title they're best known for
/// across the top, melting into the sheet, their portrait in a circle over
/// its foot, their name, what they do and where from, when they were born,
/// their biography — then their movies and shows, switched between, as a
/// grid of posters each with who they played on it. Tapping a poster opens
/// it over the sheet; tapping the portrait shows it full screen.
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

  // The grid's choice, when they've both movies and shows.
  bool _shows = false;

  static const _side = 20.0;
  static const _banner = 190.0;
  static const _portrait = 116.0;

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

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

  /// What they do, as a word for them: "Acting" → "Actor".
  static String? _calling(String? department) => switch (department) {
        null || '' => null,
        'Acting' => 'Actor',
        'Directing' => 'Director',
        'Writing' => 'Writer',
        'Production' => 'Producer',
        'Sound' => 'Composer',
        'Camera' => 'Cinematographer',
        'Editing' => 'Editor',
        final other => other,
      };

  /// "Born 30 Jan 1976 (49)", or their years when they've died.
  static String? _lifeLine(Person p) {
    final born = DateTime.tryParse(p.birthday ?? '');
    final died = DateTime.tryParse(p.deathday ?? '');
    if (born == null) return died == null ? null : 'Died ${_date(died)}';
    if (died != null) {
      return '${_date(born)} to ${_date(died)} (${_yearsBetween(born, died)})';
    }
    return 'Born ${_date(born)} (${_yearsBetween(born, DateTime.now())})';
  }

  /// The scene across the top: from the most watched of their titles that
  /// has one.
  static String? _scene(Person? p) {
    Movie? best;
    for (final m in p?.credits ?? const <Movie>[]) {
      if (m.backdrop == null) continue;
      if (best == null || m.voteCount > best.voteCount) best = m;
    }
    return best?.backdrop;
  }

  // Over the sheet, which stays open beneath: back from the title is back
  // here, scrolled to where it was — not to the page the sheet was opened
  // from, to open it and find the title again.
  void _open(Movie movie) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailsScreen(movie: movie)),
    );
  }

  String get _heroTag => 'person-photo-${widget.member.id}';

  void _viewPhoto(String photo, String? full) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) =>
          _PhotoView(tag: _heroTag, photo: photo, full: full ?? photo),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ));
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
            final credits = person?.credits ?? const <Movie>[];
            final movies = [
              for (final m in credits)
                if (m.type != 'tv') m,
            ];
            final shows = [
              for (final m in credits)
                if (m.type == 'tv') m,
            ];
            final both = movies.isNotEmpty && shows.isNotEmpty;
            final grid = both ? (_shows ? shows : movies) : credits;
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
                      padding: EdgeInsets.fromLTRB(_side, 8, _side, 40),
                      child: Text(
                        "Couldn't load their details. Try again in a bit.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                else if (grid.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(_side, 26, _side, 18),
                      child: both
                          ? _switch(person.movieCount, person.showCount)
                          : Text(
                              'Known For',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(_side, 0, _side,
                        28 + MediaQuery.paddingOf(context).bottom),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 18,
                        // The poster, then two lines under it.
                        childAspectRatio: 0.5,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _tile(grid[i], person.roleIn(grid[i])),
                        childCount: grid.length,
                      ),
                    ),
                  ),
                ] else
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The scene, the portrait over its foot, and who they are under it —
  /// the portrait and name straight away, from the cast row, the rest once
  /// loaded.
  Widget _header(Person? person) {
    final member = widget.member;
    final name = person?.name ?? member.name;
    final photo = person?.profileUrl ?? member.profileUrl;
    final scene = _scene(person);
    final place = person?.placeOfBirth?.trim() ?? '';
    final about = [
      if (_calling(person?.knownFor) case final calling?) calling,
      if (place.isNotEmpty) _shortPlace(place),
    ].join(' · ');
    final life = person == null ? null : _lifeLine(person);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = MediaQuery.sizeOf(context).width;

    return Column(
      children: [
        SizedBox(
          height: _banner + _portrait / 2,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: _banner,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: scene == null
                      ? const SizedBox.expand()
                      : Stack(
                          key: ValueKey(scene),
                          fit: StackFit.expand,
                          children: [
                            FadingCoverImage(
                              url: scene,
                              cacheWidth: (width * dpr).round(),
                              fadeFrom: 0.35,
                            ),
                            // Shaded from the top: the sheet's handle
                            // shows on a bright scene, and the scene
                            // stays the backdrop, not the subject.
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x8C000000),
                                    Color(0x00000000),
                                  ],
                                  stops: [0, 0.7],
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              Positioned(
                bottom: 0,
                child: GestureDetector(
                  onTap: photo == null
                      ? null
                      : () => _viewPhoto(photo, person?.photoUrl),
                  child: _portraitOf(name, photo),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(_side, 14, _side, 0),
          child: Column(
            children: [
              Text(
                name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                  letterSpacing: -0.5,
                ),
              ),
              if (about.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  about,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ],
              if (life != null) ...[
                const SizedBox(height: 3),
                Text(
                  life,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
              if (person != null && person.biography.isNotEmpty) ...[
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ExpandableSynopsis(
                    text: person.biography,
                    collapsedLines: 3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Their portrait in a circle with a fine edge, lifted off the scene by a
  /// soft shadow; without one, their initials.
  Widget _portraitOf(String name, String? photo) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      width: _portrait,
      height: _portrait,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24, width: 1.5),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: Hero(
        tag: _heroTag,
        child: ClipOval(
          child: photo == null
              ? _initials(name)
              : CachedNetworkImage(
                  imageUrl: photo,
                  fit: BoxFit.cover,
                  // Faces sit in the top part of a portrait.
                  alignment: const Alignment(0, -0.5),
                  memCacheWidth: (_portrait * dpr).round(),
                  fadeInDuration: const Duration(milliseconds: 200),
                  placeholder: (_, __) =>
                      const ColoredBox(color: Color(0xFF2A2A2C)),
                  errorWidget: (_, __, ___) => _initials(name),
                ),
        ),
      ),
    );
  }

  Widget _initials(String name) {
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return ColoredBox(
      color: const Color(0xFF2A2A2C),
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w700,
            color: Colors.white38,
          ),
        ),
      ),
    );
  }

  /// Movies or Shows, with how many of each: a glass switch, its thumb
  /// sliding to the one chosen.
  Widget _switch(int movieCount, int showCount) {
    Widget half(bool shows, String label, int count) {
      final chosen = _shows == shows;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _shows = shows),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: chosen ? Colors.white : Colors.white54,
              ),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: label),
                TextSpan(
                  text: '  $count',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: chosen ? Colors.white60 : Colors.white30,
                  ),
                ),
              ])),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kGlassEdge),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: _shows ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(17),
                ),
              ),
            ),
          ),
          Row(
            children: [
              half(false, 'Movies', movieCount),
              half(true, 'Shows', showCount),
            ],
          ),
        ],
      ),
    );
  }

  /// A poster, then its title and who they played on it.
  Widget _tile(Movie movie, String? role) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: MoviePoster(
            movie: movie,
            width: double.infinity,
            height: double.infinity,
            onTap: () => _open(movie),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          movie.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (role != null)
          Text(
            role,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
      ],
    );
  }

  Widget _loadingBody() {
    Widget block(double width, double height, {double radius = 4}) => Container(
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
        padding: const EdgeInsets.fromLTRB(_side, 10, _side, 40),
        child: Column(
          children: [
            block(160, 14),
            const SizedBox(height: 22),
            for (final width in [double.infinity, double.infinity, 220.0])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: block(width, 14),
                ),
              ),
            const SizedBox(height: 18),
            block(double.infinity, 40, radius: 20),
            const SizedBox(height: 18),
            Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: block(double.infinity, double.infinity, radius: 8),
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

/// Their portrait full screen: grown out of the circle's, sharp at TMDB's
/// original size once that's in, pinch to zoom, and a tap anywhere to
/// close.
class _PhotoView extends StatelessWidget {
  final String tag;
  final String photo;
  final String full;

  const _PhotoView(
      {required this.tag, required this.photo, required this.full});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: InteractiveViewer(
            maxScale: 4,
            child: Hero(
              tag: tag,
              child: CachedNetworkImage(
                imageUrl: full,
                fit: BoxFit.contain,
                // The circle's smaller copy while the full one loads.
                placeholder: (_, __) =>
                    CachedNetworkImage(imageUrl: photo, fit: BoxFit.contain),
                fadeInDuration: const Duration(milliseconds: 150),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
