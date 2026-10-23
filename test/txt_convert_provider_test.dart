import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/providers/txt_convert_provider.dart';
import 'package:cotime_book/services/txt_book.dart';
import 'package:flutter_test/flutter_test.dart';

TxtSource txt(String name, String text) =>
    TxtSource(fileName: name, bytes: Uint8List.fromList(utf8.encode(text)));

/// The XHTML of [epub] in archive order, which is reading order.
String epubText(Uint8List epub) => ZipDecoder()
    .decodeBytes(epub)
    .files
    .where((f) => f.name.startsWith('OEBPS/text/'))
    .map((f) => utf8.decode(f.content as List<int>))
    .join();

TxtBookRequest everything(TxtImportDraft draft, {String? title}) =>
    TxtBookRequest(
      title: title ?? draft.title,
      author: draft.author,
      parts: [
        for (var i = 0; i < draft.sources.length; i++)
          TxtPart(draft.sources[i], draft.analyses[i].encoding),
      ],
    );

void main() {
  late Directory dir;
  late List<(String, Uint8List)> exported;
  String? exportTo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('converted');
    exported = [];
    exportTo = '/sdcard/Download/book.epub';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  TxtConvertNotifier converter({Duration? errorAutoClearDelay}) {
    final notifier = TxtConvertNotifier(
      directory: () async => dir,
      export: (fileName, bytes) async {
        exported.add((fileName, bytes));
        return exportTo;
      },
      errorAutoClearDelay:
          errorAutoClearDelay ?? TxtConvertNotifier.defaultErrorAutoClearDelay,
    );
    addTearDown(() {
      if (notifier.mounted) notifier.dispose();
    });
    return notifier;
  }

  test('TXT volumes become one EPUB on this device, in volume order, ready '
      'to read before anyone else sees it', () async {
    final tool = converter();
    TxtImportDraft? shown;

    await tool.convert(
      [
        txt('雨夜_卷二.txt', '第二章 天亮\n　　院子里的树倒了。\n'),
        txt('雨夜_卷一.txt', '作者：林某\n第一章 雨夜\n　　他一个人走在路上。\n'),
      ],
      confirm: (draft) async {
        shown = draft;
        return everything(draft);
      },
    );

    expect(shown!.sources.map((s) => s.fileName), ['雨夜_卷一.txt', '雨夜_卷二.txt']);
    final state = tool.state;
    expect(state.error, isNull);
    expect(state.isBusy, isFalse);
    expect(state.isSaved, isFalse);
    final book = state.book!;
    expect(book.title, '雨夜');
    expect(book.author, '林某');
    expect(book.fileName, '雨夜.epub');

    final epub = book.file.readAsBytesSync();
    expect(book.sizeBytes, epub.length);
    final text = epubText(epub);
    expect(text.indexOf('他一个人走在路上'), lessThan(text.indexOf('院子里的树倒了')));
    // Nothing is saved anywhere the reader chose until they ask.
    expect(exported, isEmpty);
  });

  test('saving hands the converted EPUB to the save dialog, so it can be '
      'shared in a room from there', () async {
    final tool = converter();
    await tool.convert([
      txt('雨夜.txt', '第一章\n　　雨。\n'),
    ], confirm: (draft) async => everything(draft, title: 'Rain: Part 1'));

    exportTo = null; // Backed out of the dialog.
    await tool.saveBook();
    expect(tool.state.isSaved, isFalse);

    exportTo = '/sdcard/Download/Rain_ Part 1.epub';
    await tool.saveBook();

    expect(tool.state.isSaved, isTrue);
    expect(tool.state.isBusy, isFalse);
    expect(exported.last.$1, 'Rain_ Part 1.epub');
    expect(exported.last.$2, tool.state.book!.file.readAsBytesSync());
  });

  test('backing out of the TXT sheet makes nothing', () async {
    final tool = converter();

    await tool.convert([
      txt('雨夜.txt', '第一章\n　　雨。\n'),
    ], confirm: (_) async => null);

    expect(tool.state.isBusy, isFalse);
    expect(tool.state.error, isNull);
    expect(tool.state.book, isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('a conversion that fails keeps the book made before it', () async {
    final tool = converter();
    await tool.convert([
      txt('雨夜.txt', '第一章\n　　雨。\n'),
    ], confirm: (draft) async => everything(draft));
    final first = tool.state.book!;

    await tool.convert(
      [
        TxtSource(
          fileName: 'huge.txt',
          bytes: Uint8List(AppConstants.maxFileSize + 1),
        ),
      ],
      confirm: (_) async {
        fail('too large to show');
      },
    );

    expect(tool.state.book, same(first));
    expect(first.file.existsSync(), isTrue);
    expect(
      tool.state.error,
      'This file is 40.0 MB. A book can be made of at most 40.0 MB of text.',
    );
  });

  test('converting another book replaces the first and its file', () async {
    final tool = converter();
    await tool.convert([
      txt('雨夜.txt', '第一章\n　　雨。\n'),
    ], confirm: (draft) async => everything(draft));
    final first = tool.state.book!;
    await tool.saveBook();

    await tool.convert([
      txt('天亮.txt', '第一章\n　　天亮了。\n'),
    ], confirm: (draft) async => everything(draft));

    expect(tool.state.book!.title, '天亮');
    // Saved was about the first book.
    expect(tool.state.isSaved, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(first.file.existsSync(), isFalse);
  });

  test('an error goes away on its own', () async {
    final tool = converter(
      errorAutoClearDelay: const Duration(milliseconds: 20),
    );
    await tool.convert([
      TxtSource(
        fileName: 'huge.txt',
        bytes: Uint8List(AppConstants.maxFileSize + 1),
      ),
    ], confirm: (_) async => null);
    expect(tool.state.error, isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(tool.state.error, isNull);
  });

  test('leaving the tool deletes the converted file', () async {
    final tool = converter();
    await tool.convert([
      txt('雨夜.txt', '第一章\n　　雨。\n'),
    ], confirm: (draft) async => everything(draft));
    final file = tool.state.book!.file;

    tool.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(file.existsSync(), isFalse);
  });

  test('the saved file is named after the title, safe for any file system', () {
    expect(epubFileNameFor('雨夜'), '雨夜.epub');
    expect(epubFileNameFor('A/B: C?'), 'A_B_ C_.epub');
    expect(epubFileNameFor('  ..  '), 'book.epub');
  });
}
