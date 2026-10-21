import 'dart:convert';
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

    test('prose that only begins like a heading stays prose', () {
      for (final line in [
        '第二回合他又输了。',
        '第一部分的人已经离开。',
        '第一章写得很好，可是第二章就不行了，作者显然没有想清楚后面要怎么发展，'
            '读者也只能慢慢等。',
        'Chapter by chapter, the story grew.',
        '序列号在背面。',
      ]) {
        expect(isTxtHeading(line), isFalse, reason: line);
      }
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
