import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/room_provider.dart';
import '../screens/home_screen.dart';
import '../screens/room_lobby_screen.dart';
import '../screens/reader_screen.dart';
import '../screens/room_removed.dart';
import '../screens/txt_convert_screen.dart';
import '../l10n/l10n.dart';

class AppRouter {
  static final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/convert',
        name: 'convert',
        builder: (context, state) => const TxtConvertScreen(),
      ),
      GoRoute(
        path: '/lobby/:roomCode',
        name: 'lobby',
        builder: (context, state) {
          final roomCode = state.pathParameters['roomCode']!.toUpperCase();
          if (!_isRoomCode(roomCode)) {
            return _invalidRoomCodeScreen(context);
          }
          // Lobby performs an asynchronous membership/session check and owns
          // cleanup while leaving. Keep it mounted until that cleanup finishes.
          return RoomLobbyScreen(roomCode: roomCode);
        },
      ),
      GoRoute(
        path: '/reader/:roomCode',
        name: 'reader',
        builder: (context, state) {
          final roomCode = state.pathParameters['roomCode']!.toUpperCase();
          if (!_isRoomCode(roomCode)) {
            return _invalidRoomCodeScreen(context);
          }
          return _ActiveRoomGuard(
            roomCode: roomCode,
            child: ReaderScreen(roomCode: roomCode),
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text(context.l10n.pageNotFound('${state.uri}'))),
    ),
  );

  static bool _isRoomCode(String value) {
    return RegExp(r'^[A-HJ-NP-Z2-9]{6}$').hasMatch(value);
  }

  static Widget _invalidRoomCodeScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.invalidRoomLink)),
      body: Center(
        child: ElevatedButton(
          onPressed: () => context.goNamed('home'),
          child: Text(context.l10n.returnHome),
        ),
      ),
    );
  }
}

class _ActiveRoomGuard extends ConsumerWidget {
  final String roomCode;
  final Widget child;

  const _ActiveRoomGuard({required this.roomCode, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Removed while reading (GH-36): go home and say why, rather than swap
    // the book for a page about joining from Home.
    ref.listen<RoomState>(roomProvider, (previous, next) {
      if (roomWasRemoved(roomCode, previous, next)) {
        returnHomeFromRemovedRoom(context, ref, next.error!);
      }
    });
    final activeRoom = ref.watch(roomProvider).currentRoom;
    if (activeRoom != null &&
        activeRoom.code.toUpperCase() == roomCode.toUpperCase()) {
      return child;
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.roomUnavailable)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.joinFromHomeFirst, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => context.goNamed('home'),
                child: Text(context.l10n.returnHome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
