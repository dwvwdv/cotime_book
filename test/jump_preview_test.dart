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
}
