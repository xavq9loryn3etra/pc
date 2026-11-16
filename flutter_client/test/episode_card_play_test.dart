import 'package:flutter/material.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/widgets/episode_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final episode = Episode(
    id: 1,
    episodeNumber: 5,
    name: 'An Episode',
    overview: 'Something happens.',
    airDate: '2020-01-01',
    voteAverage: 8,
    runtime: 46,
  );

  Future<({int taps, int plays})> pump(WidgetTester tester, double? progress,
      {bool tapPlay = false}) async {
    var taps = 0, plays = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 220,
          height: 260,
          child: EpisodeCard(
            episode: episode,
            progress: progress,
            onTap: () => taps++,
            onPlay: () => plays++,
          ),
        ),
      ),
    ));
    if (tapPlay) {
      await tester.tap(find.byTooltip('Resume'));
      await tester.pump();
    }
    return (taps: taps, plays: plays);
  }

  testWidgets('part-way watched: a play button that plays', (tester) async {
    final r = await pump(tester, 0.4, tapPlay: true);
    expect(r.plays, 1);
    expect(r.taps, 0, reason: 'the popup mustn\'t open too');
  });

  testWidgets('not started, or watched: no play button', (tester) async {
    await pump(tester, null);
    expect(find.byTooltip('Resume'), findsNothing);
    await pump(tester, 0.97);
    expect(find.byTooltip('Resume'), findsNothing);
  });
}
