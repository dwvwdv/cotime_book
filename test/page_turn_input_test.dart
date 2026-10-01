import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/widgets/page_turn_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the left third of the page goes back, the rest goes forward', () {
    expect(
      pageTurnDirectionForTap(dx: 10, width: 300),
      PageTurnDirection.previous,
    );
    expect(
      pageTurnDirectionForTap(dx: 99, width: 300),
      PageTurnDirection.previous,
    );
    expect(
      pageTurnDirectionForTap(dx: 150, width: 300),
      PageTurnDirection.next,
    );
    expect(
      pageTurnDirectionForTap(dx: 290, width: 300),
      PageTurnDirection.next,
    );
  });

  test('page buttons and page turners map to turns', () {
    PageTurnDirection? map(LogicalKeyboardKey key) =>
        pageTurnDirectionForKey(key, volumeKeysTurnPages: false);

    expect(map(LogicalKeyboardKey.pageDown), PageTurnDirection.next);
    expect(map(LogicalKeyboardKey.arrowRight), PageTurnDirection.next);
    expect(map(LogicalKeyboardKey.pageUp), PageTurnDirection.previous);
    expect(map(LogicalKeyboardKey.arrowLeft), PageTurnDirection.previous);
    expect(map(LogicalKeyboardKey.keyA), isNull);
  });

  test('volume keys stay the volume until the reader opts in', () {
    expect(
      pageTurnDirectionForKey(
        LogicalKeyboardKey.audioVolumeDown,
        volumeKeysTurnPages: false,
      ),
      isNull,
    );
    expect(
      pageTurnDirectionForKey(
        LogicalKeyboardKey.audioVolumeDown,
        volumeKeysTurnPages: true,
      ),
      PageTurnDirection.next,
    );
    expect(
      pageTurnDirectionForKey(
        LogicalKeyboardKey.audioVolumeUp,
        volumeKeysTurnPages: true,
      ),
      PageTurnDirection.previous,
    );
  });
}
