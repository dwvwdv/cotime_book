import 'package:cotime_book/screens/book_preview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_test/flutter_test.dart';

EpubChapter chapter(
  String title,
  String href, [
  List<EpubChapter> subitems = const [],
]) => EpubChapter(title: title, href: href, id: href, subitems: subitems);

void main() {
  testWidgets('the contents list every chapter, parts included, and opens '
      'the one tapped', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookContents(
            chapters: [
              chapter('卷一', 'text/part1.xhtml', [
                chapter('第一章 雨夜', 'text/c1.xhtml'),
                chapter('第二章 天亮', 'text/c2.xhtml'),
              ]),
              chapter('', 'text/c3.xhtml'),
            ],
            onOpen: opened.add,
          ),
        ),
      ),
    );

    expect(find.text('4 entries'), findsOneWidget);
    expect(find.text('(untitled)'), findsOneWidget);
    await tester.tap(find.text('第二章 天亮'));
    expect(opened, ['text/c2.xhtml']);
  });

  testWidgets('a book with no contents says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookContents(chapters: const [], onOpen: (_) {}),
        ),
      ),
    );

    expect(find.text('This book has no contents.'), findsOneWidget);
  });
}
