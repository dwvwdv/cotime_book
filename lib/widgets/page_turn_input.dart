import 'package:flutter/services.dart';
import '../models/page_sync_state.dart';

/// Share of the page width, from the leading edge, that turns back.
///
/// The Kindle/Kobo convention: a narrow strip on the left goes back and the
/// rest of the page goes forward, because forward is what readers do almost
/// every time. Swipes still work for phone users.
const double previousPageTapZone = 1 / 3;

PageTurnDirection pageTurnDirectionForTap({
  required double dx,
  required double width,
}) {
  if (width <= 0) return PageTurnDirection.next;
  return dx < width * previousPageTapZone
      ? PageTurnDirection.previous
      : PageTurnDirection.next;
}

/// Maps a key to a page turn.
///
/// E-readers expose their physical page buttons as Page Up/Down (Boox's
/// default) or as the volume keys; Bluetooth page turners and keyboards send
/// Page Up/Down or the arrows.
PageTurnDirection? pageTurnDirectionForKey(
  LogicalKeyboardKey key, {
  required bool volumeKeysTurnPages,
}) {
  if (key == LogicalKeyboardKey.pageDown ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.space) {
    return PageTurnDirection.next;
  }
  if (key == LogicalKeyboardKey.pageUp ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowUp) {
    return PageTurnDirection.previous;
  }
  if (volumeKeysTurnPages) {
    if (key == LogicalKeyboardKey.audioVolumeDown) {
      return PageTurnDirection.next;
    }
    if (key == LogicalKeyboardKey.audioVolumeUp) {
      return PageTurnDirection.previous;
    }
  }
  return null;
}
