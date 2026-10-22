import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:enough_convert/big5.dart';

import 'gb18030.dart';

/// Turns plain-text novels into an EPUB on the sharer's device.
///
/// The room only ever sees EPUBs: page sync, the shared page and book
/// transfer all work on the EPUB's bytes, so a TXT import never touches them
/// and older app versions can read the result. Converting once, here, also
/// means everyone reads the very same bytes; converting on each receiver
/// would let two app versions lay out two different books.
///
/// Everything in this file is pure Dart so it can run in an isolate: a
/// 20MB novel takes seconds to decode, and the UI must not freeze meanwhile.

/// A TXT file as picked, before it is decoded.
class TxtSource {
  final String fileName;
  final Uint8List bytes;

  const TxtSource({required this.fileName, required this.bytes});

  /// The file name without its extension.
  String get stem => txtStem(fileName);
}

/// The encodings Chinese and English TXT novels actually come in.
enum TxtEncoding {
  utf8('UTF-8'),
  utf16le('UTF-16 LE'),
  utf16be('UTF-16 BE'),
  // GB18030 is GBK with four-byte characters added, and reads every GBK file
  // the same; the name stays `gbk` because book identifiers are made from it.
  gbk('GBK / GB18030'),
  big5('Big5');

  final String label;
  const TxtEncoding(this.label);
}

String txtStem(String fileName) {
  final name = fileName.split(RegExp(r'[\\/]')).last;
  return name.toLowerCase().endsWith('.txt')
      ? name.substring(0, name.length - 4)
      : name;
}

// ---------------------------------------------------------------------------
// Encoding

/// How many bytes encoding detection looks at. Enough for a few thousand
/// characters of prose; decoding the whole file twice just to choose would
/// double the wait on a slow e-reader.
const _detectionSampleBytes = 256 * 1024;

/// Characters common in both simplified and traditional Chinese prose.
///
/// GBK and Big5 overlap so much that the wrong one decodes most files without
/// a single error, into nonsense. Real text is full of these characters;
/// nonsense almost never is.
final _commonHan = Set<int>.of(
  ('的一是不了在人有我他这這个個们們中来來上大为為和国國地到以说說时時要就出'
          '会會可也你对對生能而子那得于於着著下自之年过過发發后後作里裡用道行所然'
          '家种種事成方多经經么麼去法学學如都同现現当當没沒动動面起看定天分还還进'
          '進好小部其些主样樣理心她本前开開但因只从從想实實日她们們把被让讓给給吧'
          '呢吗嗎啊')
      .runes,
);

/// Guesses the encoding of [bytes]. A byte-order mark decides outright;
/// otherwise zero bytes on one side mean UTF-16, valid UTF-8 is UTF-8, and
/// GBK, Big5 and UTF-16 that is mostly Chinese are told apart by which one
/// reads as Chinese prose.
TxtEncoding detectTxtEncoding(Uint8List bytes) {
  if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) return TxtEncoding.utf8;
  if (_startsWith(bytes, const [0xFF, 0xFE])) return TxtEncoding.utf16le;
  if (_startsWith(bytes, const [0xFE, 0xFF])) return TxtEncoding.utf16be;

  final sample = bytes.length > _detectionSampleBytes
      ? Uint8List.sublistView(bytes, 0, _detectionSampleBytes)
      : bytes;
  var evenZeros = 0, oddZeros = 0;
  for (var i = 0; i < sample.length; i++) {
    if (sample[i] != 0) continue;
    i.isEven ? evenZeros++ : oddZeros++;
  }
  // ASCII in UTF-16 is half zero bytes; GBK and Big5 have none.
  final half = sample.length ~/ 2;
  if (half > 0 && oddZeros > half * 0.2 && oddZeros > evenZeros * 4) {
    return TxtEncoding.utf16le;
  }
  if (half > 0 && evenZeros > half * 0.2 && evenZeros > oddZeros * 4) {
    return TxtEncoding.utf16be;
  }
  // After the zero-byte check: ASCII in UTF-16 is valid UTF-8 too.
  if (_isUtf8(sample, truncated: sample.length < bytes.length)) {
    return TxtEncoding.utf8;
  }

  final gbk = _proseScore(decodeTxt(sample, TxtEncoding.gbk));
  final big5 = _proseScore(decodeTxt(sample, TxtEncoding.big5));
  // GBK on a tie: it is what most Chinese TXT novels come in.
  var best = big5 > gbk ? TxtEncoding.big5 : TxtEncoding.gbk;
  var bestScore = big5 > gbk ? big5 : gbk;

  // UTF-16 with no byte-order mark that is mostly Chinese: only its ASCII has
  // zero bytes, too few for the check above. It has to beat GBK and Big5 at
  // reading as prose, and before that decode with nothing a text cannot hold.
  // An odd length cannot be UTF-16 at all.
  if (bytes.length.isEven) {
    final truncated = sample.length < bytes.length;
    for (final encoding in const [TxtEncoding.utf16le, TxtEncoding.utf16be]) {
      final score = _utf16ProseScore(
        sample,
        little: encoding == TxtEncoding.utf16le,
        truncated: truncated,
      );
      if (score != null && score > bestScore) {
        best = encoding;
        bestScore = score;
      }
    }
  }
  return best;
}

/// [_proseScore] of [bytes] read as UTF-16, or null when they cannot be text
/// in it: a surrogate without its pair, a control character other than tab
/// and line breaks, a noncharacter, or common Chinese characters making up
/// less than a twentieth of it.
///
/// GBK and Big5 read as UTF-16 land all over the code space: a novel's worth
/// of them always hits a lone surrogate or a control character, and where
/// they land on Chinese characters those are random, not the common ones
/// prose is made of.
int? _utf16ProseScore(
  Uint8List bytes, {
  required bool little,
  required bool truncated,
}) {
  final units = Uint16List(bytes.length ~/ 2);
  for (var i = 0; i < units.length; i++) {
    final a = bytes[i * 2], b = bytes[i * 2 + 1];
    units[i] = little ? a | (b << 8) : (a << 8) | b;
  }
  if (units.isEmpty) return null;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 == units.length) {
        // A sample may stop between the two halves of a character.
        if (!truncated) return null;
      } else if (units[i + 1] < 0xDC00 || units[i + 1] > 0xDFFF) {
        return null;
      } else {
        i++;
      }
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return null;
    } else if ((unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) ||
        (unit >= 0x7F && unit <= 0x9F) ||
        unit == 0xFFFE ||
        unit == 0xFFFF) {
      return null;
    }
  }
  final score = _proseScore(String.fromCharCodes(units));
  return score * 20 >= units.length ? score : null;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

/// Whether [bytes] is valid UTF-8. A [truncated] sample may end inside a
/// character, so up to three trailing bytes of an unfinished sequence pass.
bool _isUtf8(Uint8List bytes, {required bool truncated}) {
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    final int length;
    if (b < 0x80) {
      i++;
      continue;
    } else if (b >= 0xC2 && b <= 0xDF) {
      length = 2;
    } else if (b >= 0xE0 && b <= 0xEF) {
      length = 3;
    } else if (b >= 0xF0 && b <= 0xF4) {
      length = 4;
    } else {
      return false;
    }
    if (i + length > bytes.length) return truncated;
    for (var k = 1; k < length; k++) {
      if (bytes[i + k] & 0xC0 != 0x80) return false;
    }
    i += length;
  }
  return true;
}

int _proseScore(String text) {
  var score = 0;
  for (final rune in text.runes) {
    if (_commonHan.contains(rune)) {
      score++;
    } else if (rune == 0xFFFD) {
      score -= 5;
    }
  }
  return score;
}

/// Decodes [bytes] as [encoding], dropping a byte-order mark. Bytes that are
/// not valid in [encoding] become U+FFFD rather than failing the import: the
/// reader sees the preview and can pick another encoding.
String decodeTxt(Uint8List bytes, TxtEncoding encoding) {
  switch (encoding) {
    case TxtEncoding.utf8:
      final start = _startsWith(bytes, const [0xEF, 0xBB, 0xBF]) ? 3 : 0;
      return utf8.decode(
        Uint8List.sublistView(bytes, start),
        allowMalformed: true,
      );
    case TxtEncoding.utf16le:
    case TxtEncoding.utf16be:
      final little = encoding == TxtEncoding.utf16le;
      final bom = little ? const [0xFF, 0xFE] : const [0xFE, 0xFF];
      final start = _startsWith(bytes, bom) ? 2 : 0;
      final units = Uint16List((bytes.length - start) ~/ 2);
      for (var i = 0; i < units.length; i++) {
        final a = bytes[start + i * 2], b = bytes[start + i * 2 + 1];
        units[i] = little ? a | (b << 8) : (a << 8) | b;
      }
      return String.fromCharCodes(units);
    case TxtEncoding.gbk:
      return decodeGb18030(bytes);
    case TxtEncoding.big5:
      return const Big5Codec(allowInvalid: true).decode(bytes);
  }
}

// ---------------------------------------------------------------------------
// Chapters

const _numerals = '0-9０-９零〇一二两兩三四五六七八九十百千万萬';

/// Lines that are chapter headings in Chinese and English novels.
///
/// A heading is a line of its own and short; prose lines are whole
/// paragraphs. The lookahead keeps sentences that merely begin like one
/// ("第二回合…", "第一部分…", "第二节课…") in the text.
final _headingPatterns = [
  RegExp(
    '^[【\\[〔［(（]?\\s*第[\\s$_numerals]+[章回节節卷集部篇话話幕]'
    '(?![合分团團门門队隊课課])',
  ),
  RegExp(
    r'^(序章|序言|序幕|序|楔子|引子|引言|前言|尾声|尾聲|后记|後記|终章|終章|'
    r'番外|外传|外傳|完本感言)($|[\s:：·、—-])',
  ),
  RegExp(r'^chapter\s+([0-9]+|[ivxlcdm]+)\b', caseSensitive: false),
  RegExp(r'^(prologue|epilogue)$', caseSensitive: false),
];

/// The [_headingPatterns] that number chapters. A file with a few of these
/// already has its chapters, so [_numberedHeadingPatterns] are not looked
/// for: in such a file `一、` is a list or a section within a chapter.
final _countedHeadingPatterns = [_headingPatterns[0], _headingPatterns[2]];

const _maxHeadingLength = 40;

/// A heading names a chapter; it does not end the way a clause or a sentence
/// does. "第二节课开始了。" is prose that begins like a heading.
final _proseEnding = RegExp(r'[。，,；;]$');

/// Numbered lines that are chapter headings in some novels and list items
/// in others: `一、雨夜`, `1. The Storm`, `【01】`, `（一）`. Each captures
/// the number.
///
/// Unlike [_headingPatterns], a line matching one is a heading only when the
/// whole file numbers its chapters that way (see [_numberedLooksLikeChapters]).
final _numberedHeadingPatterns = [
  RegExp('^([零〇一二两兩三四五六七八九十百千]+)\\s*[、．.]'),
  RegExp('^([0-9０-９]{1,4})\\s*[、．.](?![0-9０-９])'),
  RegExp('^[【\\[〔［]\\s*([$_numerals]+)\\s*[】\\]〕］]'),
  RegExp('^[（(]\\s*([$_numerals]+)\\s*[）)]'),
];

/// Shorter than [_maxHeadingLength]: these have no `第…章` to vouch for them.
const _maxNumberedHeadingLength = 30;

/// How few numbered headings make a pattern, and how much text the chapters
/// between them hold at the median. A list has its items on adjacent lines,
/// or a line or two apart; chapters are pages apart.
const _minNumberedHeadings = 3;
const _minNumberedChapterCharacters = 200;

/// Whitespace a TXT line may be padded with, full-width included.
final _padding = RegExp(r'^[\s　]+|[\s　]+$');

String _trimPadding(String line) => line.replaceAll(_padding, '');

/// Whether [line] is a chapter heading wherever it appears, such as
/// `第一章` or `Chapter 12`.
bool isTxtHeading(String line) {
  final text = _trimPadding(line);
  if (text.isEmpty || text.length > _maxHeadingLength) return false;
  if (_proseEnding.hasMatch(text)) return false;
  return _headingPatterns.any((pattern) => pattern.hasMatch(text));
}

bool _isCountedHeading(String line) {
  final text = _trimPadding(line);
  return _countedHeadingPatterns.any((pattern) => pattern.hasMatch(text));
}

/// Which of [_numberedHeadingPatterns] [line] matches and the number it
/// carries, or null.
({int pattern, int number})? _numberedHeading(String line) {
  final text = _trimPadding(line);
  if (text.isEmpty || text.length > _maxNumberedHeadingLength) return null;
  if (_proseEnding.hasMatch(text)) return null;
  for (var p = 0; p < _numberedHeadingPatterns.length; p++) {
    final match = _numberedHeadingPatterns[p].firstMatch(text);
    if (match == null) continue;
    final number = _numberValue(match.group(1)!);
    if (number != null) return (pattern: p, number: number);
  }
  return null;
}

/// `12`, `１２` and `十二` → 12. Null for a mix of digits and Chinese
/// numerals, which no one numbers chapters with.
int? _numberValue(String text) {
  final chars = text.runes.map(String.fromCharCode).toList();
  if (chars.every((ch) => _asciiDigit(ch) != null)) {
    return chars.fold<int>(0, (n, ch) => n * 10 + _asciiDigit(ch)!);
  }
  if (chars.every(_isHanNumeral)) return _hanValue(chars);
  return null;
}

/// Whether numbered lines at [entries] (line index and number, in order)
/// are how [lines] numbers its chapters: at least [_minNumberedHeadings] of
/// them, counting up one at a time (starting over at one for a new volume
/// now and then), with a chapter's worth of text between them.
bool _numberedLooksLikeChapters(
  List<({int line, int number})> entries,
  List<String> lines,
) {
  if (entries.length < _minNumberedHeadings) return false;
  var steps = 0, restarts = 0;
  for (var k = 1; k < entries.length; k++) {
    final previous = entries[k - 1].number, number = entries[k].number;
    if (number == previous + 1) {
      steps++;
    } else if (number <= 1 && previous > number) {
      steps++;
      restarts++;
    }
  }
  final gaps = entries.length - 1;
  if (steps * 4 < gaps * 3 || restarts * 5 > entries.length) return false;

  final lengths = <int>[
    for (var k = 1; k < entries.length; k++)
      [
        for (var i = entries[k - 1].line + 1; i < entries[k].line; i++)
          _trimPadding(lines[i]).length,
      ].fold<int>(0, (n, length) => n + length),
  ]..sort();
  return lengths[lengths.length ~/ 2] >= _minNumberedChapterCharacters;
}

/// The indexes of [lines] that are chapter headings: every [isTxtHeading]
/// line, and, in a file that does not number its chapters `第…章`, the lines
/// of the numbered pattern its chapters follow, if any.
Set<int> _headingLines(List<String> lines) {
  final headings = <int>{};
  final numbered = [
    for (final _ in _numberedHeadingPatterns) <({int line, int number})>[],
  ];
  var counted = 0;
  for (var i = 0; i < lines.length; i++) {
    if (isTxtHeading(lines[i])) {
      headings.add(i);
      if (_isCountedHeading(lines[i])) counted++;
      continue;
    }
    final candidate = _numberedHeading(lines[i]);
    if (candidate != null) {
      numbered[candidate.pattern].add((line: i, number: candidate.number));
    }
  }
  if (counted >= _minNumberedHeadings) return headings;

  // One pattern at most: a file whose chapters are `一、` may well have
  // `1.` lists in them.
  List<({int line, int number})>? chosen;
  for (final entries in numbered) {
    if ((chosen == null || entries.length > chosen.length) &&
        _numberedLooksLikeChapters(entries, lines)) {
      chosen = entries;
    }
  }
  return {...headings, ...?chosen?.map((entry) => entry.line)};
}

/// A chapter of a TXT file: its heading (null for the text before the first
/// one) and its paragraphs, one per non-blank line.
class TxtChapter {
  final String? heading;
  final List<String> paragraphs;

  const TxtChapter(this.heading, this.paragraphs);
}

/// Splits [text] into chapters at heading lines. Text before the first
/// heading becomes a chapter without one; blank lines are dropped (they only
/// separate paragraphs, which the EPUB does with margins).
///
/// With [findChapters] off the whole text is one chapter without a heading,
/// which the EPUB cuts by length: the way out when headings were found
/// where there are none.
List<TxtChapter> splitTxtChapters(String text, {bool findChapters = true}) {
  // Leading full-width spaces are the novel's own paragraph indent; keep
  // them. Trailing ones are noise.
  final lines = [
    for (final rawLine in const LineSplitter().convert(text))
      if (_trimPadding(rawLine).isNotEmpty)
        rawLine.replaceFirst(RegExp(r'[\s　]+$'), ''),
  ];
  final headings = findChapters ? _headingLines(lines) : const <int>{};

  final chapters = <TxtChapter>[];
  String? heading;
  var paragraphs = <String>[];
  var hasChapter = false;

  void close() {
    if (heading != null || paragraphs.isNotEmpty) {
      chapters.add(TxtChapter(heading, paragraphs));
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (headings.contains(i)) {
      if (hasChapter || paragraphs.isNotEmpty) close();
      heading = _trimPadding(line);
      paragraphs = <String>[];
      hasChapter = true;
    } else {
      paragraphs.add(line.replaceFirst(RegExp(r'^[ \t]+'), ''));
    }
  }
  close();
  return chapters;
}

/// What the import sheet shows for one file.
class TxtFileAnalysis {
  final String fileName;
  final TxtEncoding encoding;

  /// The first few lines, so a wrong encoding shows as nonsense.
  final List<String> preview;

  /// Headings found; 0 means the file will be split by length.
  final int chapterCount;
  final int characterCount;

  /// From an `作者：` / `Author:` line near the top, if there is one.
  final String? author;

  const TxtFileAnalysis({
    required this.fileName,
    required this.encoding,
    required this.preview,
    required this.chapterCount,
    required this.characterCount,
    this.author,
  });

  /// Whether the decoded text has no visible characters at all.
  bool get isEmpty => characterCount == 0;
}

final _authorLine = RegExp(
  r'^(作者|author)\s*[:：]\s*(.+)$',
  caseSensitive: false,
);

/// Decodes [source] as [encoding] (detected when null) and reports what the
/// book would look like.
TxtFileAnalysis analyzeTxt(TxtSource source, {TxtEncoding? encoding}) {
  final used = encoding ?? detectTxtEncoding(source.bytes);
  final text = decodeTxt(source.bytes, used);
  final chapters = splitTxtChapters(text);
  final lines = <String>[];
  String? author;
  var characters = 0, seen = 0;
  for (final chapter in chapters) {
    for (final line in [
      if (chapter.heading != null) chapter.heading!,
      ...chapter.paragraphs,
    ]) {
      final trimmed = _trimPadding(line);
      characters += trimmed.length;
      if (lines.length < 3) lines.add(_clip(trimmed, 80));
      if (author == null && ++seen <= 20) {
        final match = _authorLine.firstMatch(trimmed);
        if (match != null) author = _clip(match.group(2)!.trim(), 60);
      }
    }
  }
  return TxtFileAnalysis(
    fileName: source.fileName,
    encoding: used,
    preview: lines,
    chapterCount: chapters.where((c) => c.heading != null).length,
    characterCount: characters,
    author: author,
  );
}

String _clip(String text, int length) =>
    text.length <= length ? text : '${text.substring(0, length)}…';

/// [analyzeTxt] off the UI isolate.
Future<TxtFileAnalysis> analyzeTxtInBackground(
  TxtSource source, {
  TxtEncoding? encoding,
}) => Isolate.run(() => analyzeTxt(source, encoding: encoding));

/// [buildTxtEpub] off the UI isolate.
Future<Uint8List> buildTxtEpubInBackground(TxtBookRequest request) =>
    Isolate.run(() => buildTxtEpub(request));

/// What the import sheet starts from: the picked files in reading order, what
/// each one decodes to, and a title and author guessed from them.
class TxtImportDraft {
  final List<TxtSource> sources;
  final List<TxtFileAnalysis> analyses;
  final String title;
  final String? author;

  const TxtImportDraft({
    required this.sources,
    required this.analyses,
    required this.title,
    this.author,
  });
}

// ---------------------------------------------------------------------------
// Ordering and naming

/// Orders file names the way a person numbers volumes: `卷二` before `卷十`,
/// `part2` before `part10`.
int naturalCompare(String a, String b) {
  final x = _sortTokens(a), y = _sortTokens(b);
  for (var i = 0; i < x.length && i < y.length; i++) {
    final p = x[i], q = y[i];
    final int order;
    if (p is int && q is int) {
      order = p.compareTo(q);
    } else if (p is int) {
      order = -1;
    } else if (q is int) {
      order = 1;
    } else {
      order = (p as String).compareTo(q as String);
    }
    if (order != 0) return order;
  }
  final byLength = x.length.compareTo(y.length);
  return byLength != 0 ? byLength : a.compareTo(b);
}

const _hanDigits = {
  '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '兩': 2, '三': 3, '四': 4, //
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
};
const _hanUnits = {'十': 10, '百': 100, '千': 1000};
const _hanMyriads = {'万': 10000, '萬': 10000};

List<Object> _sortTokens(String text) {
  final tokens = <Object>[];
  final runes = text.toLowerCase().runes.map(String.fromCharCode).toList();
  var i = 0;
  while (i < runes.length) {
    final ch = runes[i];
    if (_asciiDigit(ch) != null) {
      var value = 0;
      while (i < runes.length && _asciiDigit(runes[i]) != null) {
        value = value * 10 + _asciiDigit(runes[i])!;
        i++;
      }
      tokens.add(value);
    } else if (_isHanNumeral(ch)) {
      final start = i;
      while (i < runes.length && _isHanNumeral(runes[i])) {
        i++;
      }
      tokens.add(_hanValue(runes.sublist(start, i)));
    } else {
      tokens.add(ch);
      i++;
    }
  }
  return tokens;
}

int? _asciiDigit(String ch) {
  final code = ch.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0xFF10 && code <= 0xFF19) return code - 0xFF10; // full-width
  return null;
}

bool _isHanNumeral(String ch) =>
    _hanDigits.containsKey(ch) ||
    _hanUnits.containsKey(ch) ||
    _hanMyriads.containsKey(ch);

/// `十一` → 11, `二十` → 20, `一百零五` → 105, and the digit-by-digit
/// `一二` → 12.
int _hanValue(List<String> chars) {
  var total = 0, section = 0, number = 0;
  var lastWasDigit = false;
  for (final ch in chars) {
    final digit = _hanDigits[ch];
    if (digit != null) {
      number = lastWasDigit ? number * 10 + digit : digit;
      lastWasDigit = true;
      continue;
    }
    lastWasDigit = false;
    final unit = _hanUnits[ch];
    if (unit != null) {
      section += (number == 0 ? 1 : number) * unit;
      number = 0;
    } else {
      total += (section + number) * _hanMyriads[ch]!;
      section = 0;
      number = 0;
    }
  }
  return total + section + number;
}

/// Volume markers stripped from the end of a shared file-name prefix:
/// `斗破_卷一` and `斗破_卷二` share `斗破_卷`, which names the book `斗破`.
final _trailingVolumeMarker = RegExp(r'[\s_\-—.·(（\[【第卷部册冊集篇0-9０-９]+$');

/// A title for a book made of [fileNames]: the file name for one file, and
/// for several the part their names share.
String suggestTxtTitle(List<String> fileNames) {
  final stems = fileNames.map(txtStem).toList();
  if (stems.isEmpty) return '';
  if (stems.length == 1) return stems.single.trim();
  var prefix = stems.first;
  for (final stem in stems.skip(1)) {
    var n = 0;
    while (n < prefix.length && n < stem.length && prefix[n] == stem[n]) {
      n++;
    }
    prefix = prefix.substring(0, n);
  }
  final title = prefix.replaceFirst(_trailingVolumeMarker, '').trim();
  return title.isEmpty ? stems.first.trim() : title;
}

// ---------------------------------------------------------------------------
// EPUB

/// One file of the book, decoded as [encoding].
class TxtPart {
  final TxtSource source;
  final TxtEncoding encoding;

  const TxtPart(this.source, this.encoding);
}

/// What to build: [parts] in reading order become one book.
class TxtBookRequest {
  final String title;
  final String? author;
  final List<TxtPart> parts;

  /// Off when the reader saw chapters found where there are none: the text
  /// is then cut by length alone (see [splitTxtChapters]).
  final bool findChapters;

  const TxtBookRequest({
    required this.title,
    required this.parts,
    this.author,
    this.findChapters = true,
  });
}

/// Characters per XHTML file at most. epub.js loads one file at a time, and a
/// single multi-megabyte file (a novel with no headings found) takes long
/// enough to open on an e-reader to look like a hang.
const txtMaxSectionCharacters = 20000;

/// A fixed timestamp, so the same import builds the same bytes.
final _epoch = DateTime(2000);

class _Section {
  final String href;
  final String title;
  final String? heading;
  final List<String> paragraphs;

  _Section(this.href, this.title, this.heading, this.paragraphs);
}

class _NavEntry {
  final String title;
  final String href;
  final List<_NavEntry> children;

  _NavEntry(this.title, this.href, [this.children = const []]);
}

/// Builds the EPUB for [request].
///
/// The same request always gives the same bytes: no clock and no random
/// identifier goes in, so two people who import the same TXT with the same
/// app version end up with the same book hash and nothing has to be sent.
/// Throws a [FormatException] with a message for people when there is no
/// text to make a book of.
Uint8List buildTxtEpub(TxtBookRequest request) {
  final title = request.title.trim();
  if (title.isEmpty) throw const FormatException('The book needs a title.');
  if (request.parts.isEmpty) {
    throw const FormatException('Pick at least one TXT file.');
  }

  final sections = <_Section>[];
  final nav = <_NavEntry>[];
  final volumes = request.parts.length > 1;
  final languageSample = StringBuffer();

  for (final part in request.parts) {
    final text = decodeTxt(part.source.bytes, part.encoding);
    if (languageSample.length < 4000) {
      languageSample.write(text.substring(0, text.length.clamp(0, 4000)));
    }
    final chapters = splitTxtChapters(text, findChapters: request.findChapters);
    final untitled = volumes ? part.source.stem.trim() : title;
    final entries = <_NavEntry>[];
    final untitledEntries = <int>[];

    for (final chapter in chapters) {
      final pieces = _splitByLength(chapter.paragraphs);
      for (var p = 0; p < pieces.length; p++) {
        final href =
            'text/s${(sections.length + 1).toString().padLeft(4, '0')}.xhtml';
        final heading = p == 0 ? chapter.heading : null;
        final String label;
        if (chapter.heading != null) {
          label = chapter.heading!;
        } else {
          label = untitled;
          untitledEntries.add(entries.length);
        }
        sections.add(_Section(href, label, heading, pieces[p]));
        // Only a chapter's first piece is listed; the rest continue it,
        // except where there are no headings to list at all.
        if (p == 0 || chapter.heading == null) {
          entries.add(_NavEntry(label, href));
        }
      }
    }
    // Untitled pieces are told apart by number.
    if (untitledEntries.length > 1) {
      for (var n = 0; n < untitledEntries.length; n++) {
        final i = untitledEntries[n];
        entries[i] = _NavEntry('$untitled ${n + 1}', entries[i].href);
      }
    }
    if (entries.isEmpty) continue;
    if (volumes) {
      nav.add(_NavEntry(part.source.stem.trim(), entries.first.href, entries));
    } else {
      nav.addAll(entries);
    }
  }

  if (sections.every((s) => s.heading == null && s.paragraphs.isEmpty)) {
    throw const FormatException('These files have no text in them.');
  }

  final language = _guessLanguage(languageSample.toString());
  final identifier = _identifier(request, title);
  final author = request.author?.trim();
  final archive = Archive();

  void add(String name, String content, {bool store = false}) {
    final file = ArchiveFile.bytes(name, utf8.encode(content));
    if (store) file.compression = CompressionType.none;
    file.lastModTime = _epoch.millisecondsSinceEpoch ~/ 1000;
    archive.add(file);
  }

  // The mimetype must be the first entry, uncompressed.
  add('mimetype', 'application/epub+zip', store: true);
  add('META-INF/container.xml', _containerXml);
  add('OEBPS/style.css', _stylesheet);
  add(
    'OEBPS/content.opf',
    _contentOpf(
      identifier: identifier,
      title: title,
      author: (author == null || author.isEmpty) ? null : author,
      language: language,
      sections: sections,
    ),
  );
  add('OEBPS/nav.xhtml', _navXhtml(title, language, nav));
  add('OEBPS/toc.ncx', _tocNcx(identifier, title, nav));
  for (final section in sections) {
    add('OEBPS/${section.href}', _sectionXhtml(section, language));
  }

  // `modified` pins every entry's DOS time, which the encoder would otherwise
  // take from the device's time zone.
  return ZipEncoder().encodeBytes(archive, modified: _epoch);
}

/// Cuts [paragraphs] into pieces of at most [txtMaxSectionCharacters], at
/// paragraph boundaries. A paragraph longer than that is a piece of its own.
List<List<String>> _splitByLength(List<String> paragraphs) {
  final pieces = <List<String>>[[]];
  var length = 0;
  for (final paragraph in paragraphs) {
    if (length > 0 && length + paragraph.length > txtMaxSectionCharacters) {
      pieces.add([]);
      length = 0;
    }
    pieces.last.add(paragraph);
    length += paragraph.length;
  }
  return pieces;
}

String _guessLanguage(String sample) {
  var han = 0, kana = 0, letters = 0;
  for (final rune in sample.runes) {
    if (rune >= 0x3040 && rune <= 0x30FF) {
      kana++;
    } else if (rune >= 0x4E00 && rune <= 0x9FFF) {
      han++;
    } else if ((rune | 0x20) >= 0x61 && (rune | 0x20) <= 0x7A) {
      letters++;
    }
  }
  if (kana > 20 && kana * 10 > han) return 'ja';
  // A CJK character carries a word's worth of meaning; a letter does not.
  if (han * 4 > letters) return han > 0 ? 'zh' : 'en';
  return 'en';
}

String _identifier(TxtBookRequest request, String title) {
  final digest = sha256.convert([
    ...utf8.encode(title),
    0,
    ...utf8.encode(request.author?.trim() ?? ''),
    for (final part in request.parts) ...[
      0,
      ...utf8.encode(part.encoding.name),
      0,
      ...sha256.convert(part.source.bytes).bytes,
    ],
    // Only when off, so a book made with chapters keeps the identifier it
    // had before this choice existed.
    if (!request.findChapters) ...[0, ...utf8.encode('no-chapters')],
  ]);
  return 'urn:cotime-txt:$digest';
}

/// Escapes [text] for XML, dropping characters XML 1.0 cannot hold at all.
/// One stray control character in a TXT would otherwise make the whole
/// chapter fail to parse and show as a blank page.
String _xml(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    switch (rune) {
      case 0x26:
        out.write('&amp;');
      case 0x3C:
        out.write('&lt;');
      case 0x3E:
        out.write('&gt;');
      case 0x22:
        out.write('&quot;');
      default:
        final allowed =
            rune == 0x9 ||
            rune == 0xA ||
            rune == 0xD ||
            (rune >= 0x20 && rune <= 0xD7FF) ||
            (rune >= 0xE000 && rune <= 0xFFFD) ||
            (rune >= 0x10000 && rune <= 0x10FFFF);
        if (allowed) out.writeCharCode(rune);
    }
  }
  return out.toString();
}

const _containerXml =
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '  <rootfiles>\n'
    '    <rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/>\n'
    '  </rootfiles>\n'
    '</container>\n';

/// Margins only: the shared page sets the font and line height for every
/// reader (issue #20).
const _stylesheet =
    'p { margin: 0 0 0.6em 0; }\n'
    'h2 { font-size: 1.3em; font-weight: bold; margin: 0 0 1.2em 0; }\n';

String _contentOpf({
  required String identifier,
  required String title,
  required String? author,
  required String language,
  required List<_Section> sections,
}) {
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="utf-8"?>')
    ..writeln(
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="book-id">',
    )
    ..writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">')
    ..writeln(
      '    <dc:identifier id="book-id">${_xml(identifier)}</dc:identifier>',
    )
    ..writeln('    <dc:title>${_xml(title)}</dc:title>');
  if (author != null) {
    out.writeln('    <dc:creator>${_xml(author)}</dc:creator>');
  }
  out
    ..writeln('    <dc:language>$language</dc:language>')
    ..writeln(
      '    <meta property="dcterms:modified">2000-01-01T00:00:00Z</meta>',
    )
    ..writeln('  </metadata>')
    ..writeln('  <manifest>')
    ..writeln(
      '    <item id="nav" href="nav.xhtml" '
      'media-type="application/xhtml+xml" properties="nav"/>',
    )
    ..writeln(
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    )
    ..writeln('    <item id="style" href="style.css" media-type="text/css"/>');
  for (var i = 0; i < sections.length; i++) {
    out.writeln(
      '    <item id="s${i + 1}" href="${sections[i].href}" '
      'media-type="application/xhtml+xml"/>',
    );
  }
  out
    ..writeln('  </manifest>')
    ..writeln('  <spine toc="ncx">');
  for (var i = 0; i < sections.length; i++) {
    out.writeln('    <itemref idref="s${i + 1}"/>');
  }
  out
    ..writeln('  </spine>')
    ..writeln('</package>');
  return out.toString();
}

String _xhtmlHead(String title, String language, String stylesheet) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!DOCTYPE html>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops" '
    'lang="$language" xml:lang="$language">\n'
    '<head>\n'
    '<meta charset="utf-8"/>\n'
    '<title>${_xml(title)}</title>\n'
    '<link rel="stylesheet" type="text/css" href="$stylesheet"/>\n'
    '</head>\n';

String _sectionXhtml(_Section section, String language) {
  final out = StringBuffer(_xhtmlHead(section.title, language, '../style.css'))
    ..writeln('<body>');
  if (section.heading != null) {
    out.writeln('<h2>${_xml(section.heading!)}</h2>');
  }
  for (final paragraph in section.paragraphs) {
    out.writeln('<p>${_xml(paragraph)}</p>');
  }
  out
    ..writeln('</body>')
    ..writeln('</html>');
  return out.toString();
}

String _navXhtml(String title, String language, List<_NavEntry> nav) {
  final out = StringBuffer(_xhtmlHead(title, language, 'style.css'))
    ..writeln('<body>')
    ..writeln('<nav epub:type="toc" id="toc">')
    ..writeln('<h1>${_xml(title)}</h1>');
  void list(List<_NavEntry> entries) {
    out.writeln('<ol>');
    for (final entry in entries) {
      out.write('<li><a href="${entry.href}">${_xml(entry.title)}</a>');
      if (entry.children.isNotEmpty) {
        out.writeln();
        list(entry.children);
      }
      out.writeln('</li>');
    }
    out.writeln('</ol>');
  }

  list(nav);
  out
    ..writeln('</nav>')
    ..writeln('</body>')
    ..writeln('</html>');
  return out.toString();
}

/// EPUB 2's table of contents, for readers outside the app that predate the
/// EPUB 3 nav document.
String _tocNcx(String identifier, String title, List<_NavEntry> nav) {
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="utf-8"?>')
    ..writeln(
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">',
    )
    ..writeln('<head>')
    ..writeln('<meta name="dtb:uid" content="${_xml(identifier)}"/>')
    ..writeln('</head>')
    ..writeln('<docTitle><text>${_xml(title)}</text></docTitle>')
    ..writeln('<navMap>');
  var order = 0;
  void points(List<_NavEntry> entries) {
    for (final entry in entries) {
      order++;
      out
        ..writeln('<navPoint id="p$order" playOrder="$order">')
        ..writeln('<navLabel><text>${_xml(entry.title)}</text></navLabel>')
        ..writeln('<content src="${entry.href}"/>');
      points(entry.children);
      out.writeln('</navPoint>');
    }
  }

  points(nav);
  out
    ..writeln('</navMap>')
    ..writeln('</ncx>');
  return out.toString();
}
