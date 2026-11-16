import 'package:flutter/material.dart';
import 'package:flutter_client/widgets/status_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the download button fills with its progress', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: StatusPrimaryButton(
                label: 'Downloading… 50%', onPressed: null, progress: 0.5),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final fill = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .where((b) => b.color == Colors.white);
    expect(fill, isNotEmpty);
    final box = tester.getSize(find.byWidget(fill.first));
    expect(box.width, closeTo(200, 1));
  });
}
