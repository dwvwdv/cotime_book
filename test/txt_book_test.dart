import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cotime_book/services/txt_book.dart';
import 'package:crypto/crypto.dart';
import 'package:enough_convert/big5.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const simplified =
    '第一章 雨夜\n'
    '　　那天晚上下着很大的雨，他一个人走在回家的路上。\n'
    '　　我们都知道他不会回头，可是她还是在门口等了很久。\n'
    '\n'
    '第二章 天亮\n'
    '　　天亮以后，大家发现院子里的树倒了。\n';

const traditional =
    '第一章 雨夜\n'
    '　　那天晚上下著很大的雨，他一個人走在回家的路上。\n'
    '　　我們都知道他不會回頭，可是她還是在門口等了很久。\n'
    '\n'
    '第二章 天亮\n'
    '　　天亮以後，大家發現院子裡的樹倒了。\n';

TxtSource source(String name, List<int> bytes) =>
    TxtSource(fileName: name, bytes: Uint8List.fromList(bytes));

Map<String, String> unzip(Uint8List epub) {
  final archive = ZipDecoder().decodeBytes(epub);
  return {
    for (final file in archive.files)
      if (file.isFile) file.name: utf8.decode(file.content as List<int>),
  };
}

Uint8List build(List<TxtSource> files, {String title = 'Book'}) => buildTxtEpub(
  TxtBookRequest(
    title: title,
    parts: [
      for (final file in files) TxtPart(file, detectTxtEncoding(file.bytes)),
    ],
  ),
);

/// The visible text of every section, in spine order.
List<String> spineText(Map<String, String> files) {
  final opf = XmlDocument.parse(files['OEBPS/content.opf']!);
  final hrefs = {
    for (final item in opf.findAllElements('item'))
      item.getAttribute('id'): item.getAttribute('href'),
  };
  return [
    for (final ref in opf.findAllElements('itemref'))
      XmlDocument.parse(
        files['OEBPS/${hrefs[ref.getAttribute('idref')]}']!,
      ).findAllElements('body').single.innerText.trim(),
  ];
}

/// [text] as UTF-16 with no byte-order mark, the way some editors save it.
Uint8List utf16(String text, {required bool little}) => Uint8List.fromList([
  for (final u in text.codeUnits)
    ...(little ? [u & 0xFF, u >> 8] : [u >> 8, u & 0xFF]),
]);

/// A few thousand characters of made-up prose, a chapter heading every
/// thirty paragraphs, the way TXT novels come.
String novel({required bool traditional, int chapters = 4}) {
  const simplifiedPhrases = [
    '他推开窗', '外面的雨还没有停', '院子里的灯一盏一盏亮起来', '她说', //
    '“明天再走吧。”', '没有人回答', '远处传来钟声', '我们沿着河岸走了很久',
    '风把纸页吹得哗哗作响', '（这件事后来谁也没再提起）', '他终于明白了',
  ];
  const traditionalPhrases = [
    '他推開窗', '外面的雨還沒有停', '院子裡的燈一盞一盞亮起來', '她說', //
    '「明天再走吧。」', '沒有人回答', '遠處傳來鐘聲', '我們沿著河岸走了很久',
    '風把紙頁吹得嘩嘩作響', '（這件事後來誰也沒再提起）', '他終於明白了',
  ];
  final phrases = traditional ? traditionalPhrases : simplifiedPhrases;
  final random = Random(7);
  final text = StringBuffer();
  for (var c = 1; c <= chapters; c++) {
    text.write('第$c章 夜裡\r\n');
    for (var p = 0; p < 30; p++) {
      final words = [
        for (var w = 0; w < 3 + random.nextInt(12); w++)
          phrases[random.nextInt(phrases.length)],
      ];
      text.write('　　${words.join('，')}。\r\n');
    }
  }
  return text.toString();
}

/// A paragraph of about 130 characters: chapters made of a few are pages
/// apart, the way chapters are and list items are not.
const longParagraph =
    '　　他沉默地走着，雨一直没有停，路边的灯一盏一盏亮起来，'
    '远处传来钟声，他想起很多年前的那个晚上，她站在门口等他回家，'
    '可是他没有回去，后来也再没有人提起这件事，风把纸页吹得哗哗作响，'
    '他终于明白了她那天为什么不说话。';

String chaptered(List<String> headings) => [
  for (final heading in headings) ...[
    heading,
    longParagraph,
    longParagraph,
    longParagraph,
  ],
].join('\n');

List<String?> headingsOf(String text) =>
    splitTxtChapters(text).map((c) => c.heading).toList();

List<String> navTitles(Map<String, String> files) => XmlDocument.parse(
  files['OEBPS/nav.xhtml']!,
).findAllElements('a').map((a) => a.innerText).toList();

void main() {
  group('encoding', () {
    test('a Chinese novel saved in GBK reads as Chinese', () {
      final bytes = Uint8List.fromList(const GbkCodec().encode(simplified));
      expect(detectTxtEncoding(bytes), TxtEncoding.gbk);
      expect(decodeTxt(bytes, TxtEncoding.gbk), simplified);
    });

    test('a Chinese novel saved in Big5 reads as Chinese', () {
      final bytes = Uint8List.fromList(const Big5Codec().encode(traditional));
      expect(detectTxtEncoding(bytes), TxtEncoding.big5);
      expect(decodeTxt(bytes, TxtEncoding.big5), traditional);
    });

    test('UTF-8, with or without a byte-order mark', () {
      final plain = Uint8List.fromList(utf8.encode(traditional));
      final marked = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...plain]);
      expect(detectTxtEncoding(plain), TxtEncoding.utf8);
      expect(detectTxtEncoding(marked), TxtEncoding.utf8);
      expect(decodeTxt(marked, TxtEncoding.utf8), traditional);
    });

    test('UTF-8 cut off mid-character by the detection sample is UTF-8', () {
      // Long enough that the sample ends inside a three-byte character.
      final text = '的' * 100000;
      expect(
        detectTxtEncoding(Uint8List.fromList(utf8.encode(text))),
        TxtEncoding.utf8,
      );
    });

    test('UTF-16 from Windows Notepad', () {
      final units = 'Chapter 1\n他走了。'.codeUnits;
      final le = [
        0xFF,
        0xFE,
        for (final u in units) ...[u & 0xFF, u >> 8],
      ];
      final beNoBom = [
        for (final u in 'Chapter 1\nHe left.'.codeUnits) ...[u >> 8, u & 0xFF],
      ];
      expect(detectTxtEncoding(Uint8List.fromList(le)), TxtEncoding.utf16le);
      expect(
        decodeTxt(Uint8List.fromList(le), TxtEncoding.utf16le),
        'Chapter 1\n他走了。',
      );
      expect(
        detectTxtEncoding(Uint8List.fromList(beNoBom)),
        TxtEncoding.utf16be,
      );
    });

    test('UTF-16 with no byte-order mark that is mostly Chinese is UTF-16', () {
      // Its only zero bytes are in line breaks, too few to tell by.
      for (final text in [
        simplified,
        traditional,
        novel(traditional: false),
        novel(traditional: true),
      ]) {
        final le = utf16(text, little: true);
        final be = utf16(text, little: false);
        expect(detectTxtEncoding(le), TxtEncoding.utf16le, reason: text);
        expect(detectTxtEncoding(be), TxtEncoding.utf16be, reason: text);
        expect(decodeTxt(le, TxtEncoding.utf16le), text);
        expect(decodeTxt(be, TxtEncoding.utf16be), text);
      }
    });

    test('UTF-16 longer than the detection sample, cut between the two '
        'halves of a character, is still UTF-16', () {
      // 𠀾 takes two UTF-16 units. Placed to straddle the end of the 256KB
      // sample: 131071 units in, so the sample ends after its first half.
      const line = '我们都知道他不会回头，可是她还是在门口等了很久。\n';
      final before = line * (131071 ~/ line.length);
      final padding = '的' * (131071 - before.length);
      final text = '$before$padding\u{2003E}$line';
      final bytes = utf16(text, little: true);
      expect(bytes[256 * 1024 - 2] | bytes[256 * 1024 - 1] << 8, 0xD840);
      expect(detectTxtEncoding(bytes), TxtEncoding.utf16le);
    });

    test('GBK, Big5 and UTF-8 novels are not taken for UTF-16', () {
      for (final traditional in [false, true]) {
        final text = novel(traditional: traditional);
        final bytes = Uint8List.fromList(
          traditional
              ? const Big5Codec().encode(text)
              : const GbkCodec().encode(text),
        );
        // An even length, so the UTF-16 readings are really tried.
        final even = bytes.length.isEven
            ? bytes
            : Uint8List.fromList([...bytes, 0x0A]);
        expect(
          detectTxtEncoding(even),
          traditional ? TxtEncoding.big5 : TxtEncoding.gbk,
          reason: traditional ? 'Big5' : 'GBK',
        );
        final utf8Bytes = Uint8List.fromList(utf8.encode(text));
        expect(detectTxtEncoding(utf8Bytes), TxtEncoding.utf8);
      }
      // The short samples above, at both an odd and an even length.
      for (final text in [simplified, '$simplified\n']) {
        final bytes = Uint8List.fromList(const GbkCodec().encode(text));
        expect(detectTxtEncoding(bytes), TxtEncoding.gbk);
      }
      for (final text in [traditional, '$traditional\n']) {
        final bytes = Uint8List.fromList(const Big5Codec().encode(text));
        expect(detectTxtEncoding(bytes), TxtEncoding.big5);
      }
    });

    test('GB18030 four-byte characters read as themselves, not as �', () {
      // The four-byte sequences are what Python's gb18030 codec encodes
      // U+20087, U+3400, U+2A6A5 and ḿ to.
      final bytes = Uint8List.fromList([
        ...const GbkCodec().encode('他叫'),
        0x95, 0x32, 0x90, 0x31, //
        0x81, 0x39, 0xEE, 0x39,
        0x98, 0x35, 0xEE, 0x37,
        0x81, 0x35, 0xF4, 0x37,
        ...const GbkCodec().encode('来了。第3章'),
      ]);
      expect(
        decodeTxt(bytes, TxtEncoding.gbk),
        '他叫\u{20087}\u3400\u{2A6A5}\u1E3F来了。第3章',
      );
    });

    test('the wrong encoding shows as nonsense in the preview, '
        'and the right one fixes it', () {
      final file = source('雨夜.txt', const GbkCodec().encode(simplified));
      final wrong = analyzeTxt(file, encoding: TxtEncoding.big5);
      final right = analyzeTxt(file, encoding: TxtEncoding.gbk);
      expect(wrong.preview.first, isNot('第一章 雨夜'));
      expect(right.preview.first, '第一章 雨夜');
      expect(right.chapterCount, 2);
    });
  });

  group('chapters', () {
    test('headings start chapters; blank lines and padding are dropped', () {
      final chapters = splitTxtChapters(
        '書名：雨夜\n作者：某人\n\n$simplified\n序章\n楔子\n',
      );
      expect(chapters.map((c) => c.heading), [
        null,
        '第一章 雨夜',
        '第二章 天亮',
        '序章',
        '楔子',
      ]);
      expect(chapters.first.paragraphs, ['書名：雨夜', '作者：某人']);
      // The novel's own full-width indent stays.
      expect(chapters[1].paragraphs.first, startsWith('　　那天晚上'));
    });

    test('heading forms found in real novels', () {
      for (final line in [
        '第1章',
        '第１２章 归来',
        '  第一百零五章：决战',
        '第三回 夜宴',
        '第二卷 风起',
        'Chapter 12',
        'CHAPTER IV The Storm',
        'Prologue',
        '番外 旧事',
        '尾聲',
      ]) {
        expect(isTxtHeading(line), isTrue, reason: line);
      }
    });

    test('a heading in brackets', () {
      expect(isTxtHeading('【第一章】雨夜'), isTrue);
      expect(isTxtHeading('（第二回）夜宴'), isTrue);
    });

    test('prose that only begins like a heading stays prose', () {
      for (final line in [
        '第二回合他又输了。',
        '第一部分的人已经离开。',
        '第二节课开始了',
        '第三章写完了。',
        '第一章就这样，',
        '第一章写得很好，可是第二章就不行了，作者显然没有想清楚后面要怎么发展，'
            '读者也只能慢慢等。',
        'Chapter by chapter, the story grew.',
        '序列号在背面。',
      ]) {
        expect(isTxtHeading(line), isFalse, reason: line);
      }
    });

    test('chapters numbered the way lists are, when the whole file does', () {
      expect(headingsOf(chaptered(['一、雨夜', '二、天亮', '三、远行', '四、归来'])), [
        '一、雨夜',
        '二、天亮',
        '三、远行',
        '四、归来',
      ]);
      expect(headingsOf(chaptered(['【01】', '【02】', '【03】'])), [
        '【01】',
        '【02】',
        '【03】',
      ]);
      expect(headingsOf(chaptered(['（一）', '（二）', '（三）'])), [
        '（一）',
        '（二）',
        '（三）',
      ]);
      expect(headingsOf(chaptered(['1. Rain', '2. Dawn', '3. Away'])), [
        '1. Rain',
        '2. Dawn',
        '3. Away',
      ]);
      // A second volume starting over at one.
      expect(
        headingsOf(chaptered(['一、雨', '二、风', '三、雪', '一、春', '二、夏'])),
        hasLength(5),
      );
      // A later file of a book split into several starts where the last
      // one stopped.
      expect(headingsOf(chaptered(['31、雨', '32、风', '33、雪'])), [
        '31、雨',
        '32、风',
        '33、雪',
      ]);
    });

    test('a numbered list in the prose is not taken for chapters', () {
      // Items on adjacent lines: lists are, chapters are not.
      final list = [
        longParagraph,
        '　　师父定下三条规矩：',
        '一、不许说谎',
        '二、不许偷懒',
        '三、不许下山',
        '四、不许问为什么',
        longParagraph,
        longParagraph,
      ].join('\n');
      expect(headingsOf(list), [null]);

      // Items that are sentences, however far apart.
      final sentences = chaptered(['一、他先走了。', '二、她留了下来。', '三、谁也没有回头。']);
      expect(headingsOf(sentences), [null]);

      // Numbers that do not count up are not chapter numbers.
      expect(headingsOf(chaptered(['3、雨', '7、风', '1、雪', '12、远'])), [null]);

      // Only twice: not enough to call a pattern.
      expect(headingsOf(chaptered(['一、雨夜', '二、天亮'])), [null]);
    });

    test('in a file with 第…章 chapters, numbered lines stay in them', () {
      final text = chaptered([
        '第一章 雨夜',
        '一、来客',
        '二、夜谈',
        '第二章 天亮',
        '三、离别',
        '第三章 远行',
      ]);
      expect(headingsOf(text), ['第一章 雨夜', '第二章 天亮', '第三章 远行']);
    });

    test('with chapters turned off the text is one untitled chapter', () {
      final chapters = splitTxtChapters(simplified, findChapters: false);
      expect(chapters.map((c) => c.heading), [null]);
      expect(chapters.single.paragraphs.first, '第一章 雨夜');
      expect(chapters.single.paragraphs, hasLength(5));
    });

    test('the author line near the top is picked up', () {
      final file = source('a.txt', utf8.encode('雨夜\n作者：林某\n\n$simplified'));
      expect(analyzeTxt(file).author, '林某');
    });
  });

  group('ordering and title', () {
    test('volumes sort by number, Chinese numerals included', () {
      final names = ['卷十.txt', '卷二.txt', '卷一.txt', '卷十一.txt', '卷三.txt'];
      names.sort(naturalCompare);
      expect(names, ['卷一.txt', '卷二.txt', '卷三.txt', '卷十.txt', '卷十一.txt']);

      final parts = ['part10.txt', 'part2.txt', 'part1.txt'];
      parts.sort(naturalCompare);
      expect(parts, ['part1.txt', 'part2.txt', 'part10.txt']);
    });

    test('the title is what the file names share', () {
      expect(suggestTxtTitle(['雨夜.txt']), '雨夜');
      expect(suggestTxtTitle(['雨夜_卷一.txt', '雨夜_卷二.txt']), '雨夜');
      expect(suggestTxtTitle(['book01.txt', 'book02.TXT']), 'book');
      expect(suggestTxtTitle(['三体1.txt', '三体2.txt']), '三体');
      // Nothing shared but the marker: fall back to the first name.
      expect(suggestTxtTitle(['第一卷.txt', '第二卷.txt']), '第一卷');
    });
  });

  group('epub', () {
    test('is a valid EPUB whose pages read the text in order', () {
      final epub = build([source('雨夜.txt', utf8.encode(simplified))]);
      final archive = ZipDecoder().decodeBytes(epub);
      // Readers require the mimetype first and uncompressed.
      expect(archive.files.first.name, 'mimetype');
      expect(utf8.decode(epub.sublist(30, 30 + 'mimetype'.length)), 'mimetype');
      expect(
        utf8.decode(epub.sublist(38, 38 + 'application/epub+zip'.length)),
        'application/epub+zip',
      );

      final files = unzip(epub);
      for (final entry in files.entries) {
        if (entry.key.endsWith('.css') || entry.key == 'mimetype') continue;
        expect(
          () => XmlDocument.parse(entry.value),
          returnsNormally,
          reason: entry.key,
        );
      }
      final text = spineText(files);
      expect(text, hasLength(2));
      expect(text.first, startsWith('第一章 雨夜'));
      expect(text.first, contains('她还是在门口等了很久'));
      expect(text.last, contains('院子里的树倒了'));
      expect(navTitles(files), ['第一章 雨夜', '第二章 天亮']);
      expect(
        files['OEBPS/content.opf'],
        contains('<dc:language>zh</dc:language>'),
      );
    });

    test('the same import always builds the same bytes', () {
      // Two people importing one TXT get one book hash, so nothing is sent.
      final file = source('雨夜.txt', utf8.encode(simplified));
      expect(
        sha256.convert(build([file])).toString(),
        sha256.convert(build([file])).toString(),
      );
    });

    test('several files become one book, a volume per file, in order', () {
      final epub = build([
        source('雨夜_卷一.txt', utf8.encode(simplified)),
        source('雨夜_卷二.txt', utf8.encode('第三章 远行\n　　他终于出发了。\n')),
      ], title: '雨夜');
      final files = unzip(epub);
      expect(navTitles(files), [
        '雨夜_卷一',
        '第一章 雨夜',
        '第二章 天亮',
        '雨夜_卷二',
        '第三章 远行',
      ]);
      expect(spineText(files).last, contains('他终于出发了'));
    });

    test('a text with no headings is cut into pages-sized parts', () {
      final paragraph = '　　${'他沉默地走着。' * 200}';
      final text = List.filled(30, paragraph).join('\n');
      final files = unzip(
        build([source('长夜.txt', utf8.encode(text))], title: '长夜'),
      );
      final sections = spineText(files);
      expect(sections.length, greaterThan(1));
      for (final section in sections) {
        expect(
          section.length,
          lessThanOrEqualTo(txtMaxSectionCharacters + paragraph.length),
        );
      }
      expect(
        sections.join().replaceAll(RegExp(r'[\s\u3000]'), ''),
        '他沉默地走着。' * 200 * 30,
      );
      expect(navTitles(files).first, '长夜 1');
      expect(navTitles(files), hasLength(sections.length));
    });

    test('with chapters turned off the book is split by length alone', () {
      final file = source('雨夜.txt', utf8.encode(simplified));
      final request = TxtBookRequest(
        title: '雨夜',
        parts: [TxtPart(file, TxtEncoding.utf8)],
        findChapters: false,
      );
      final epub = buildTxtEpub(request);
      final files = unzip(epub);
      expect(navTitles(files), ['雨夜']);
      expect(spineText(files).single, startsWith('第一章 雨夜'));
      expect(files.values.where((f) => f.contains('<h2>')), isEmpty);
      // Still the same bytes every time, and not the book with chapters.
      expect(sha256.convert(buildTxtEpub(request)), sha256.convert(epub));
      expect(
        sha256.convert(epub),
        isNot(sha256.convert(build([file], title: '雨夜'))),
      );
    });

    test('markup and control characters in the text cannot break a page', () {
      final files = unzip(
        build([
          source(
            'a.txt',
            utf8.encode('第一章 <b>&"\n　　a < b && c > d\u0001\u000B。\n'),
          ),
        ]),
      );
      final text = spineText(files).single;
      expect(text, contains('第一章 <b>&"'));
      expect(text, contains('a < b && c > d。'));
    });

    test('files with no text are refused with a reason', () {
      expect(
        () => build([source('empty.txt', utf8.encode('\n　　\n  \n'))]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'These files have no text in them.',
          ),
        ),
      );
    });
  });
}
