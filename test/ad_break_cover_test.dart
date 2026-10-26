import 'package:cotime_book/widgets/ad_break_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<int> pumpOverPage(
    WidgetTester tester,
    List<String> readersInAd,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const Text('The next page'),
                ),
              ),
              Positioned.fill(child: AdBreakCover(readersInAd: readersInAd)),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(AdBreakCover)));
    await tester.pump();
    return taps;
  }

  testWidgets('the page under an ad break is neither shown nor turned', (
    tester,
  ) async {
    final taps = await pumpOverPage(tester, ['Alice', 'Bob']);

    expect(find.text('Ad break'), findsOneWidget);
    expect(
      find.text('Waiting for Alice, Bob to finish an ad...'),
      findsOneWidget,
    );
    // Painted over, solid: nothing of the page shows through.
    final box = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(AdBreakCover),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(box.color.a, 1.0);
    expect(taps, 0);
  });

  testWidgets('says the page is coming while nobody else is named', (
    tester,
  ) async {
    await pumpOverPage(tester, const []);

    expect(
      find.text('The page opens when every reader is back.'),
      findsOneWidget,
    );
  });
}
