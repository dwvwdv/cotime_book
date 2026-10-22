import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/book_provider.dart';
import '../providers/room_provider.dart';
import '../widgets/paper.dart';

/// Whether [next] is the room screen for [roomCode] losing its room to a
/// revocation — membership gone, found out by the heartbeat or by Realtime
/// refusing the channel (GH-36) — as opposed to this device leaving it, which
/// clears the room without an error.
bool roomWasRemoved(String roomCode, RoomState? previous, RoomState next) {
  final previousCode = previous?.currentRoom?.code.toUpperCase();
  return previousCode == roomCode.toUpperCase() &&
      next.currentRoom == null &&
      next.error != null;
}

/// Takes a room screen whose room was removed back home and says why.
///
/// The message goes out once, as a message rather than a banner on Home: the
/// room is already gone, and a notice that stays until the next room action
/// reads as something still wrong.
void returnHomeFromRemovedRoom(
  BuildContext context,
  WidgetRef ref,
  String message,
) {
  final room = ref.read(roomProvider.notifier);
  final book = ref.read(bookProvider.notifier);
  showPaperMessage(context, message, duration: const Duration(seconds: 8));
  context.goNamed('home');
  // Not from inside the room listener that reported the removal.
  unawaited(
    Future<void>(() async {
      room.clearError();
      await book.reset();
    }),
  );
}
