import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cotime_book/services/txt_book.dart';
import 'package:cotime_book/widgets/txt_import_sheet.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const story = '第一章 雨夜\n　　那天晚上下着很大的雨，他一个人走在回家的路上。\n';

TxtSource gbkFile(String name) => TxtSource(
  fileName: name,
  bytes: Uint8List.fromList(const GbkCodec().encode(story)),
);

TxtSource utf8File(String name, String text) =>
    TxtSource(fileName: name, bytes: Uint8List.fromList(utf8.encode(text)));

Future<TxtBookRequest?> pump(
  WidgetTester tester,
  List<TxtSource> sources, {
  List<TxtFileAnalysis>? analyses,
  TxtReanalyze? reanalyze,
}) async {
  TxtBookRequest? confirmed;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TxtImportSheet(
          draft: TxtImportDraft(
            sources: sources,
            analyses: analyses ?? [for (final s in sources) analyzeTxt(s)],
            title: suggestTxtTitle(sources.map((s) => s.fileName).toList()),
          ),
          onConfirm: (request) => confirmed = request,
          onCancel: () {},
          reanalyze:
              reanalyze ??
              (source, encoding) async =>
                  analyzeTxt(source, encoding: encoding),
        ),
      ),
    ),
  );
  return confirmed;
}

Future<void> chooseEncoding(
  WidgetTester tester,
  TxtEncoding encoding, {
  int file = 0,
}) async {
  await tester.tap(find.textContaining('Encoding:').at(file));
  await tester.pump();
  await tester.tap(find.text(encoding.label).last);
  await tester.pump();
}

void main() {
  testWidgets('a wrongly guessed encoding can be changed, and the preview '
      'shows the text read correctly', (tester) async {
    final file = gbkFile('雨夜.txt');
    TxtBookRequest? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TxtImportSheet(
            draft: TxtImportDraft(
              sources: [file],
              // Detection guessed wrong.
              analyses: [analyzeTxt(file, encoding: TxtEncoding.big5)],
              title: '雨夜',
            ),
            onConfirm: (request) => confirmed = request,
            onCancel: () {},
            reanalyze: (source, encoding) async =>
                analyzeTxt(source, encoding: encoding),
          ),
        ),
      ),
    );
    expect(find.textContaining('第一章 雨夜'), findsNothing);

    await chooseEncoding(tester, TxtEncoding.gbk);
    await tester.pump();

    expect(find.textContaining('第一章 雨夜'), findsOneWidget);
    expect(find.text('Encoding: GBK / GB18030'), findsOneWidget);
    expect(find.textContaining('1 chapter ·'), findsOneWidget);

    await tester.tap(find.text('Share Book'));
    expect(confirmed!.title, '雨夜');
    expect(confirmed!.parts.single.encoding, TxtEncoding.gbk);
  });

  testWidgets('a slow decode of an encoding already moved away from does '
      'not replace the newer one', (tester) async {
    final file = gbkFile('雨夜.txt');
    final pending = <TxtEncoding, Completer<TxtFileAnalysis>>{};
    await pump(
      tester,
      [file],
      analyses: [analyzeTxt(file, encoding: TxtEncoding.utf8)],
      reanalyze: (source, encoding) =>
          (pending[encoding] = Completer<TxtFileAnalysis>()).future,
    );

    await chooseEncoding(tester, TxtEncoding.big5);
    expect(find.text('Reading...'), findsWidgets);
    await chooseEncoding(tester, TxtEncoding.gbk);

    pending[TxtEncoding.gbk]!.complete(
      analyzeTxt(file, encoding: TxtEncoding.gbk),
    );
    await tester.pump();
    pending[TxtEncoding.big5]!.complete(
      analyzeTxt(file, encoding: TxtEncoding.big5),
    );
    await tester.pump();

    expect(find.text('Encoding: GBK / GB18030'), findsOneWidget);
    expect(find.textContaining('第一章 雨夜'), findsOneWidget);
  });

  testWidgets('chapters found where there are none can be turned off, and '
      'the book is then split by length', (tester) async {
    // Read as chapters by rule; the reader knows better.
    final file = utf8File('雨夜.txt', '第一章 雨夜\n　　下雨了。\n第二章 天亮\n　　天亮了。\n');
    TxtBookRequest? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TxtImportSheet(
            draft: TxtImportDraft(
              sources: [file],
              analyses: [analyzeTxt(file)],
              title: '雨夜',
            ),
            onConfirm: (request) => confirmed = request,
            onCancel: () {},
          ),
        ),
      ),
    );
    expect(find.text('2 chapters'), findsOneWidget);

    await tester.tap(find.text('Split into chapters'));
    await tester.pump();
    expect(find.text('2 chapters'), findsNothing);
    expect(find.text('Split by length'), findsOneWidget);
    expect(find.textContaining('Split by length ·'), findsOneWidget);

    await tester.ensureVisible(find.text('Share Book'));
    await tester.tap(find.text('Share Book'));
    expect(confirmed!.findChapters, isFalse);

    // And back on.
    await tester.tap(find.text('Split into chapters'));
    await tester.pump();
    expect(find.text('2 chapters'), findsOneWidget);
    await tester.tap(find.text('Share Book'));
    expect(confirmed!.findChapters, isTrue);
  });

  testWidgets('a file with no chapters found has no switch to turn them off', (
    tester,
  ) async {
    await pump(tester, [utf8File('长夜.txt', '　　他沉默地走着。\n　　雨没有停。\n')]);
    expect(find.text('No chapters found'), findsOneWidget);
    expect(find.text('Split into chapters'), findsNothing);
  });

  testWidgets('volumes can be put in another order before sharing', (
    tester,
  ) async {
    TxtBookRequest? confirmed;
    final sources = [
      utf8File('雨夜 上.txt', '第一章\n　　上。\n'),
      utf8File('雨夜 下.txt', '第二章\n　　下。\n'),
      utf8File('雨夜 中.txt', '第三章\n　　中。\n'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TxtImportSheet(
            draft: TxtImportDraft(
              sources: sources,
              analyses: [for (final s in sources) analyzeTxt(s)],
              title: '雨夜',
            ),
            onConfirm: (request) => confirmed = request,
            onCancel: () {},
          ),
        ),
      ),
    );

    // Move 中 up above 下.
    await tester.ensureVisible(find.byTooltip('Move up').at(2));
    await tester.pump();
    await tester.tap(find.byTooltip('Move up').at(2));
    await tester.pump();
    await tester.tap(find.text('Share Book'));

    expect(confirmed!.parts.map((p) => p.source.fileName), [
      '雨夜 上.txt',
      '雨夜 中.txt',
      '雨夜 下.txt',
    ]);
  });

  testWidgets('a book needs a title, and files with no text are left out', (
    tester,
  ) async {
    TxtBookRequest? confirmed;
    final sources = [
      utf8File('a.txt', '第一章\n　　有字。\n'),
      utf8File('b.txt', '\n\n'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TxtImportSheet(
            draft: TxtImportDraft(
              sources: sources,
              analyses: [for (final s in sources) analyzeTxt(s)],
              title: 'Book',
            ),
            onConfirm: (request) => confirmed = request,
            onCancel: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('it will be skipped'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('txt-title')), '  ');
    await tester.pump();
    await tester.ensureVisible(find.text('Share Book'));
    await tester.pump();
    await tester.tap(find.text('Share Book'));
    expect(confirmed, isNull);

    await tester.enterText(find.byKey(const ValueKey('txt-title')), 'Book');
    await tester.pump();
    await tester.ensureVisible(find.text('Share Book'));
    await tester.pump();
    await tester.tap(find.text('Share Book'));
    expect(confirmed!.parts.map((p) => p.source.fileName), ['a.txt']);
  });

  testWidgets('with the keyboard up on a short screen the sheet scrolls '
      'instead of cutting off Share Book', (tester) async {
    // A 640px screen with a 300px keyboard leaves the sheet 244px: less than
    // the title and author fields and the buttons take on their own.
    TxtBookRequest? confirmed;
    final sources = [
      utf8File('雨夜 上.txt', '第一章\n　　上。\n'),
      utf8File('雨夜 下.txt', '第二章\n　　下。\n'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 244,
              child: TxtImportSheet(
                draft: TxtImportDraft(
                  sources: sources,
                  analyses: [for (final s in sources) analyzeTxt(s)],
                  title: '雨夜',
                ),
                onConfirm: (request) => confirmed = request,
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byKey(const ValueKey('txt-title')), '夜雨');
    await tester.pump();
    await tester.ensureVisible(find.text('Share Book'));
    await tester.pump();
    await tester.tap(find.text('Share Book'));

    expect(confirmed!.title, '夜雨');
  });
}
