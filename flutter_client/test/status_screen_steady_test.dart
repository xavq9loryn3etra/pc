import 'package:flutter/material.dart';
import 'package:flutter_client/widgets/status_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// The update screen's words change as it goes (its steps' instructions).
/// On a wide window they sit beside the logo, centred top to bottom, and a
/// longer or shorter message used to move the title and the button with
/// it: room is kept for the longest instead.
void main() {
  const short = 'A new version is ready.';
  const long = "Android asks this once: turn on \"Allow from this source\" for "
      'Popcorn, then come back here. It only takes a moment, and your lists '
      'stay as they are.';

  Future<({Offset title, Offset button})> layout(
      WidgetTester tester, Size size, String message) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      home: StatusScreen(
        title: 'A New Version',
        highlight: 'Is Ready.',
        message: message,
        roomFor: const [short, long],
        footer: const SizedBox(key: Key('button'), height: 56, width: 200),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    return (
      title: tester.getTopLeft(find.text('A New Version')),
      button: tester.getTopLeft(find.byKey(const Key('button'))),
    );
  }

  for (final size in const [Size(1600, 900), Size(400, 860)]) {
    testWidgets('nothing moves when the message changes (${size.width.toInt()} wide)',
        (tester) async {
      addTearDown(tester.view.reset);
      final a = await layout(tester, size, short);
      final b = await layout(tester, size, long);
      expect(b.title, a.title);
      expect(b.button, a.button);
    });
  }
}
