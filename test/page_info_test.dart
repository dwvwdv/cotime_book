import 'package:cotime_book/models/page_info.dart';
import 'package:cotime_book/widgets/page_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the page counter from the viewer script', () {
    final info = PageInfo.fromWire({
      'section': 4,
      'page': 3,
      'pages': 12,
      'percent': 0.456,
    });
    expect(info, const PageInfo(page: 3, pages: 12, progress: 0.456));
    expect(info!.pageLabel, '3 / 12');
    expect(info.progressLabel, '45%');
  });

  test('a book whose locations are not worked out yet shows no percent', () {
    final info = PageInfo.fromWire({'page': 1, 'pages': 5, 'percent': null});
    expect(info!.progressLabel, isNull);
  });

  test('only the end of the book reads 100%', () {
    expect(
      const PageInfo(page: 9, pages: 9, progress: 0.999).progressLabel,
      '99%',
    );
    expect(
      const PageInfo(page: 9, pages: 9, progress: 1).progressLabel,
      '100%',
    );
  });

  test('anything but a page counter is no page counter', () {
    expect(PageInfo.fromWire(null), isNull);
    expect(PageInfo.fromWire('nope'), isNull);
    expect(PageInfo.fromWire({'page': 0, 'pages': 3}), isNull);
    expect(PageInfo.fromWire({'page': 4, 'pages': 3}), isNull);
  });

  testWidgets('the counter keeps one width whatever it says', (tester) async {
    for (final info in [
      null,
      const PageInfo(page: 1, pages: 2),
      const PageInfo(page: 1234, pages: 5678, progress: 0.5),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: 64,
                child: PageCounter(info: info, ink: Colors.black),
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(PageCounter)).width, PageCounter.width);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('1234 / 5678'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
  });
}
