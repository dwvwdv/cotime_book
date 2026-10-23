import '../providers/reading_preferences_provider.dart';
import 'room.dart';

/// Who sets the room's text size, and so which size this reader asks the room
/// for in its page fit.
///
/// The room still reads at the largest size any reader asks for (issue #20);
/// the lock only changes what each reader asks for. Readers that disagree
/// about the lock for a moment (a re-read of the room still on its way, an
/// app from before the lock) therefore still lay the book out on the same
/// page, worked out from the same Presence: only the size is off until they
/// catch up.
class RoomTextSize {
  /// Only the host sets the size.
  final bool locked;
  final bool isHost;

  /// What the host set. Null until the host first opens the book locked.
  final int? roomSize;

  const RoomTextSize({
    required this.locked,
    required this.isHost,
    this.roomSize,
  });

  /// Outside a room there is nobody to defer to.
  factory RoomTextSize.of(Room? room, {required bool isHost}) => RoomTextSize(
    locked: room?.textSizeLocked ?? false,
    isHost: isHost,
    roomSize: room?.textSize,
  );

  /// Whether this reader's own buttons change the text size.
  bool get canChange => !locked || isHost;

  /// The host opened the book on a locked room that has no size yet: theirs
  /// becomes the room's.
  bool get needsRoomSize => locked && isHost && roomSize == null;

  /// The size this reader asks the room for, given the one it picked itself.
  double requested(double ownSize) {
    if (!locked) return ownSize;
    final size = roomSize;
    if (size != null) {
      return ReadingPreferences.clampFontSize(size.toDouble());
    }
    // The host is about to make theirs the room's (needsRoomSize); everyone
    // else stays out of the way at the default until it arrives.
    return isHost ? ownSize : ReadingPreferences.defaultFontSize;
  }

  @override
  bool operator ==(Object other) =>
      other is RoomTextSize &&
      other.locked == locked &&
      other.isHost == isHost &&
      other.roomSize == roomSize;

  @override
  int get hashCode => Object.hash(locked, isHost, roomSize);
}
