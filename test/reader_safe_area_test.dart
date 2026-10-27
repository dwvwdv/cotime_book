import 'package:cotime_book/widgets/reader_safe_area.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // What Flutter reports on a phone with a 48dp navigation bar, before and
  // after the keyboard comes up: the keyboard covers the bar, so the bottom
  // padding drops to 0 while the view padding stays.
  const keyboardDown = MediaQueryData(
    size: Size(400, 800),
    padding: EdgeInsets.only(top: 24, bottom: 48),
    viewPadding: EdgeInsets.only(top: 24, bottom: 48),
  );
  const keyboardUp = MediaQueryData(
    size: Size(400, 800),
    padding: EdgeInsets.only(top: 24),
    viewPadding: EdgeInsets.only(top: 24, bottom: 48),
    viewInsets: EdgeInsets.only(bottom: 300),
  );

  Future<Size> areaUnder(
    WidgetTester tester,
    MediaQueryData media,
    Widget Function(Widget child) wrap,
  ) async {
    tester.view.physicalSize = media.size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: media,
        child: MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: wrap(const SizedBox.expand(key: Key('area'))),
          ),
        ),
      ),
    );
    return tester.getSize(find.byKey(const Key('area')));
  }

  testWidgets('the keyboard does not resize the reader', (tester) async {
    // Regression: typing a page number in the jump preview grew the viewer
    // by the navigation bar, which laid the room's page out again, took the
    // focus from the box and closed the keyboard, so nothing could be typed.
    Widget reader(Widget child) => ReaderSafeArea(child: child);
    final down = await areaUnder(tester, keyboardDown, reader);
    final up = await areaUnder(tester, keyboardUp, reader);
    expect(up, down);
    expect(down, const Size(400, 800 - 24 - 48));
  });

  testWidgets('a plain safe area would have resized it', (tester) async {
    // Shows the case above is the one that went wrong.
    Widget plain(Widget child) => SafeArea(child: child);
    final down = await areaUnder(tester, keyboardDown, plain);
    final up = await areaUnder(tester, keyboardUp, plain);
    expect(up.height, down.height + 48);
  });
}
