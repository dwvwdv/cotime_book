import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cotime_book/providers/txt_convert_provider.dart';
import 'package:cotime_book/screens/txt_convert_screen.dart';
import 'package:cotime_book/services/txt_book.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late TxtConvertNotifier tool;
  late List<ConvertedBook> opened;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('converted');
    opened = [];
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpTool(WidgetTester tester) async {
    tool = TxtConvertNotifier(
      directory: () async => dir,
      export: (fileName, bytes) async => '/sdcard/Download/$fileName',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [txtConvertProvider.overrideWith((ref) => tool)],
        child: MaterialApp(
          home: TxtConvertScreen(openBook: (_, book) => opened.add(book)),
        ),
      ),
    );
  }

  Future<void> convertRain(WidgetTester tester) async {
    await tester.runAsync(
      () => tool.convert(
        [
          TxtSource(
            fileName: '雨夜.txt',
            bytes: Uint8List.fromList(utf8.encode('第一章\n　　雨。\n')),
          ),
        ],
        confirm: (draft) async => TxtBookRequest(
          title: draft.title,
          parts: [TxtPart(draft.sources.single, TxtEncoding.utf8)],
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the tool starts from picking TXT files', (tester) async {
    await pumpTool(tester);

    expect(find.text('Pick TXT Files'), findsOneWidget);
    expect(find.text('Read'), findsNothing);
  });

  testWidgets('a converted book can be read on this device before it is '
      'saved', (tester) async {
    await pumpTool(tester);
    await convertRain(tester);

    expect(find.text('雨夜'), findsOneWidget);
    await tester.tap(find.text('Read'));
    await tester.pump();

    expect(opened.single.title, '雨夜');
    expect(opened.single.file.existsSync(), isTrue);
  });

  testWidgets('once saved, the tool says how to share the EPUB in a room', (
    tester,
  ) async {
    await pumpTool(tester);
    await convertRain(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Save EPUB'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.textContaining('tap Share Book and pick this file'), findsOne);
    expect(find.text('Save Again'), findsOneWidget);
  });
}
