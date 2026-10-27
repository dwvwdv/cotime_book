import 'package:cotime_book/widgets/paper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openSheet(WidgetTester tester, WidgetBuilder builder) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showPaperSheet<void>(context: context, builder: builder),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
  }

  testWidgets('a sheet closes with a button, not only a swipe', (
    tester,
  ) async {
    // A swipe is slow and unreliable on an e-reader's panel.
    await openSheet(tester, (_) => const Text('Sheet body'));
    expect(find.text('Sheet body'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(find.text('Sheet body'), findsNothing);
  });

  testWidgets('a sheet as tall as the screen keeps its close button', (
    tester,
  ) async {
    // Sheets size themselves to a share of the screen (News, Library).
    await openSheet(
      tester,
      (context) => SizedBox(height: MediaQuery.of(context).size.height),
    );
    expect(tester.takeException(), isNull);
    final button = tester.getRect(find.byTooltip('Close'));
    final screen = tester.getRect(find.byType(Scaffold));
    expect(screen.contains(button.topLeft), isTrue);
    expect(screen.contains(button.bottomRight), isTrue);
  });
}
