// Writes an EPUB the TXT import made, for check.js: a GBK novel with chapter
// headings, full-width indents and paragraphs longer than a page, the way
// Chinese TXT novels come. Not part of `flutter test` (it only runs test/).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cotime_book/services/txt_book.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';

const _phrases = [
  '他推开窗',
  '外面的雨还没有停',
  '院子里的灯一盏一盏亮起来',
  '她说',
  '“明天再走吧。”',
  '没有人回答',
  '远处传来钟声',
  '我们沿着河岸走了很久',
  '风把纸页吹得哗哗作响',
  '（这件事后来谁也没再提起）',
  '他终于明白了',
  '天色渐渐暗下来',
];

String _paragraph(Random random, int phrases) => List.generate(
  phrases,
  (_) => _phrases[random.nextInt(_phrases.length)],
).join('，');

void main() {
  test('make txt book', () {
    final random = Random(7);
    final text = StringBuffer('雨夜\n作者：测试\n\n');
    for (var c = 1; c <= 4; c++) {
      text.writeln('第$c章 夜里的事');
      for (var p = 0; p < 30; p++) {
        // Some longer than a page: a page that starts inside one has no
        // space to start a "word" at (issue #21).
        final phrases = p % 9 == 8 ? 120 : 3 + random.nextInt(20);
        text.writeln('　　${_paragraph(random, phrases)}。');
        if (p % 4 == 0) text.writeln();
      }
    }
    final source = TxtSource(
      fileName: '雨夜.txt',
      bytes: Uint8List.fromList(const GbkCodec().encode(text.toString())),
    );
    final epub = buildTxtEpub(
      TxtBookRequest(
        title: '雨夜',
        parts: [TxtPart(source, detectTxtEncoding(source.bytes))],
      ),
    );
    File('build/shared_page_check/txt_book.epub')
      ..createSync(recursive: true)
      ..writeAsBytesSync(epub);
  });
}
