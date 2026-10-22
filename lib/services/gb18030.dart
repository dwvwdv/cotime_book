import 'dart:typed_data';

import 'package:enough_convert/gbk.dart';

/// Decodes GB18030: GBK plus the four-byte sequences GBK has no room for.
///
/// GB18030 is what "GBK" files saved on Chinese Windows and phones really are.
/// Every character GBK can hold is encoded the same; the rest (rare names,
/// CJK Extension A and B, ḿ and the like) take four bytes that a GBK decoder
/// reads as two broken characters, so a novel with one rare name shows `�`
/// wherever that name appears. enough_convert only knows GBK, so the four-byte
/// sequences are decoded here and everything between them is left to it.
///
/// A four-byte sequence is invalid in GBK (its second byte is a digit, which
/// GBK never uses there), so decoding a GBK file this way changes nothing that
/// GBK read correctly.
String decodeGb18030(Uint8List bytes) {
  const gbk = GbkCodec(allowInvalid: true);
  final out = StringBuffer();
  var runStart = 0;
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x81 || b > 0xFE) {
      i++;
      continue;
    }
    if (i + 3 < bytes.length &&
        _isDigit(bytes[i + 1]) &&
        bytes[i + 2] >= 0x81 &&
        bytes[i + 2] <= 0xFE &&
        _isDigit(bytes[i + 3])) {
      if (runStart < i) {
        out.write(gbk.decode(Uint8List.sublistView(bytes, runStart, i)));
      }
      out.writeCharCode(
        _fourByteCodePoint(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]),
      );
      i += 4;
      runStart = i;
      continue;
    }
    // A two-byte character: step over its second byte, which may itself look
    // like the start of one.
    final next = i + 1 < bytes.length ? bytes[i + 1] : -1;
    i += (next >= 0x40 && next <= 0xFE && next != 0x7F) ? 2 : 1;
  }
  if (runStart < bytes.length) {
    out.write(gbk.decode(Uint8List.sublistView(bytes, runStart)));
  }
  return out.toString();
}

bool _isDigit(int byte) => byte >= 0x30 && byte <= 0x39;

/// The four-byte sequences count up from `81 30 81 30`; the n-th one is
/// [_bmpRanges]' code point for n below 39420 and U+10000 + (n − 189000)
/// from `90 30 81 30` on.
int _fourByteCodePoint(int b1, int b2, int b3, int b4) {
  final pointer =
      (((b1 - 0x81) * 10 + (b2 - 0x30)) * 126 + (b3 - 0x81)) * 10 + (b4 - 0x30);
  if (pointer >= 189000) {
    final codePoint = 0x10000 + pointer - 189000;
    return codePoint <= 0x10FFFF ? codePoint : 0xFFFD;
  }
  if (pointer > 39419) return 0xFFFD;
  // The last range starting at or before the pointer.
  var low = 0, high = _bmpRanges.length ~/ 2 - 1;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    if (_bmpRanges[mid * 2] <= pointer) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return _bmpRanges[low * 2 + 1] + pointer - _bmpRanges[low * 2];
}

// dart format off
/// Pairs of (pointer, code point): each starts a run where both count up
/// together, up to the next pair. Generated from Python's `gb18030` codec by
/// encoding every BMP code point and keeping the four-byte ones.
const _bmpRanges = <int>[
  0, 128, 36, 165, 38, 169, 45, 178, 50, 184, 81, 216, 89, 226, 95, 235, 96,
  238, 100, 244, 103, 248, 104, 251, 105, 253, 109, 258, 126, 276, 133, 284,
  148, 300, 172, 325, 175, 329, 179, 334, 208, 364, 306, 463, 307, 465, 308,
  467, 309, 469, 310, 471, 311, 473, 312, 475, 313, 477, 341, 506, 428, 594,
  443, 610, 544, 712, 545, 716, 558, 730, 741, 930, 742, 938, 749, 962, 750,
  970, 805, 1026, 819, 1104, 820, 1106, 7922, 8209, 7924, 8215, 7925, 8218,
  7927, 8222, 7934, 8231, 7943, 8241, 7944, 8244, 7945, 8246, 7950, 8252, 8062,
  8365, 8148, 8452, 8149, 8454, 8152, 8458, 8164, 8471, 8174, 8482, 8236, 8556,
  8240, 8570, 8262, 8596, 8264, 8602, 8374, 8713, 8380, 8720, 8381, 8722, 8384,
  8726, 8388, 8731, 8390, 8737, 8392, 8740, 8393, 8742, 8394, 8748, 8396, 8751,
  8401, 8760, 8406, 8766, 8416, 8777, 8419, 8781, 8424, 8787, 8437, 8802, 8439,
  8808, 8445, 8816, 8482, 8854, 8485, 8858, 8496, 8870, 8521, 8896, 8603, 8979,
  8936, 9322, 8946, 9372, 9046, 9548, 9050, 9588, 9063, 9616, 9066, 9622, 9076,
  9634, 9092, 9652, 9100, 9662, 9108, 9672, 9111, 9676, 9113, 9680, 9131, 9702,
  9162, 9735, 9164, 9738, 9218, 9793, 9219, 9795, 11329, 11906, 11331, 11909,
  11334, 11913, 11336, 11917, 11346, 11928, 11361, 11944, 11363, 11947, 11366,
  11951, 11370, 11956, 11372, 11960, 11375, 11964, 11389, 11979, 11682, 12284,
  11686, 12292, 11687, 12312, 11692, 12319, 11694, 12330, 11714, 12351, 11716,
  12436, 11723, 12447, 11725, 12535, 11730, 12543, 11736, 12586, 11982, 12842,
  11989, 12850, 12102, 12964, 12336, 13200, 12348, 13215, 12350, 13218, 12384,
  13253, 12393, 13263, 12395, 13267, 12397, 13270, 12510, 13384, 12553, 13428,
  12851, 13727, 12962, 13839, 12973, 13851, 13738, 14617, 13823, 14703, 13919,
  14801, 13933, 14816, 14080, 14964, 14298, 15183, 14585, 15471, 14698, 15585,
  15583, 16471, 15847, 16736, 16318, 17208, 16434, 17325, 16438, 17330, 16481,
  17374, 16729, 17623, 17102, 17997, 17122, 18018, 17315, 18212, 17320, 18218,
  17402, 18301, 17418, 18318, 17859, 18760, 17909, 18811, 17911, 18814, 17915,
  18820, 17916, 18823, 17936, 18844, 17939, 18848, 17961, 18872, 18664, 19576,
  18703, 19620, 18814, 19738, 18962, 19887, 19043, 40870, 33469, 59244, 33470,
  59336, 33471, 59367, 33484, 59413, 33485, 59417, 33490, 59423, 33497, 59431,
  33501, 59437, 33505, 59443, 33513, 59452, 33520, 59460, 33536, 59478, 33550,
  59493, 37845, 63789, 37921, 63866, 37948, 63894, 38029, 63976, 38038, 63986,
  38064, 64016, 38065, 64018, 38066, 64021, 38069, 64025, 38075, 64034, 38076,
  64037, 38078, 64042, 39108, 65074, 39109, 65093, 39113, 65107, 39114, 65112,
  39115, 65127, 39116, 65132, 39265, 65375, 39394, 65510,
];
// dart format on
