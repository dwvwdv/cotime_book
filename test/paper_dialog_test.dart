import 'package:cotime_book/config/theme.dart';
import 'package:cotime_book/widgets/paper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A phone with a 40dp status bar and a 48dp navigation bar.
  void phone(WidgetTester tester, {double keyboard = 0}) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 48);
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
  }

  Future<void> openDialog(WidgetTester tester, WidgetBuilder builder) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.paperTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showPaperDialog<void>(context: context, builder: builder),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
  }

  testWidgets('a dialog closes with a button, not only a swipe', (
    tester,
  ) async {
    // A swipe is slow and unreliable on an e-reader's panel.
    phone(tester);
    await openDialog(tester, (_) => const Text('Dialog body'));
    expect(find.text('Dialog body'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(find.text('Dialog body'), findsNothing);
  });

  testWidgets('the close button stays clear of the status bar', (tester) async {
    // Regression: as a bottom sheet, content as tall as the screen (Reading
    // Settings, the Library) ran up under the status bar and put the close
    // button there, where it could hardly be tapped.
    phone(tester);
    await openDialog(
      tester,
      (context) => SizedBox(height: MediaQuery.of(context).size.height),
    );
    expect(tester.takeException(), isNull);
    final button = tester.getRect(find.byTooltip('Close'));
    expect(button.top, greaterThanOrEqualTo(40));
    expect(button.bottom, lessThanOrEqualTo(800 - 48));
    expect(button.width, greaterThanOrEqualTo(PaperDialog.closeButtonSize));
    expect(button.height, greaterThanOrEqualTo(PaperDialog.closeButtonSize));
  });

  testWidgets('the dialog keeps clear of the keyboard', (tester) async {
    phone(tester, keyboard: 300);
    await openDialog(
      tester,
      (context) => const SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: 900),
            TextField(key: Key('field')),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // The dialog's own box, not the padded area it is placed in.
    final dialog = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(dialog.bottom, lessThanOrEqualTo(800 - 300));
    expect(
      tester.getRect(find.byTooltip('Close')).top,
      greaterThanOrEqualTo(40),
    );
  });
}
