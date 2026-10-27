import 'package:cotime_book/models/page_info.dart';
import 'package:cotime_book/widgets/jump_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a typed page lands inside the chapter', () {
    expect(parseJumpPage('5', pages: 12), 5);
    expect(parseJumpPage(' 7 ', pages: 12), 7);
    // Past the end goes to the last page rather than nowhere.
    expect(parseJumpPage('999', pages: 12), 12);
    expect(parseJumpPage('0', pages: 12), 1);
  });

  test('nothing usable typed goes nowhere', () {
    expect(parseJumpPage('', pages: 12), isNull);
    expect(parseJumpPage('abc', pages: 12), isNull);
    expect(parseJumpPage('3', pages: 0), isNull);
  });

  test('a page typed and not gone to is not the page on screen', () {
    // Go then shows the typed page first instead of asking the room for the
    // page that was on screen.
    const shown = PageInfo(page: 3, pages: 12);
    expect(isTypedPagePending('7', shown), isTrue);
    expect(isTypedPagePending('99', shown), isTrue);
    expect(isTypedPagePending('3', shown), isFalse);
    expect(isTypedPagePending('', shown), isFalse);
    expect(isTypedPagePending('7', null), isFalse);
    // 99 clamps to the last page: on it, nothing is pending.
    expect(
      isTypedPagePending('99', const PageInfo(page: 12, pages: 12)),
      isFalse,
    );
  });
}
