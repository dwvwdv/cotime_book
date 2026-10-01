import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/supabase_config.dart';
import '../config/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/book_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/room_provider.dart';
import '../widgets/paper.dart';
import '../widgets/room_code_input.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _nicknameController = TextEditingController();
  final _roomCodeController = TextEditingController();
  bool _isJoinMode = false;
  bool _isLeavingRoom = false;

  // Feature 2: track last back-press time for double-back-to-exit.
  DateTime? _lastBackPress;

  @override
  void dispose() {
    _nicknameController.dispose();
    _roomCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final roomState = ref.watch(roomProvider);

    // Feature 2: intercept hardware back on home screen → double-back to exit.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPress == null ||
            now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
          _lastBackPress = now;
          showPaperMessage(
            context,
            'Press back again to exit',
            duration: const Duration(seconds: 2),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            // E-readers are mostly 7-10" portrait panels; a full-width form
            // on those reads like a spreadsheet. Keep a book-page measure.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 48, 28, 28),
                children: [
                  const Icon(Icons.menu_book_outlined, size: 44),
                  const SizedBox(height: 20),
                  const Text('CoTime Book', style: AppTheme.display),
                  const SizedBox(height: 8),
                  const Text(
                    'Read together, anywhere',
                    style: TextStyle(
                      fontFamily: AppTheme.serif,
                      fontStyle: FontStyle.italic,
                      fontSize: 18,
                      color: AppTheme.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Divider(thickness: AppTheme.heavyRuleWidth),
                  const SizedBox(height: 28),

                  if (roomState.currentRoom != null) ...[
                    const SectionHeader(label: 'Active room'),
                    const SizedBox(height: 14),
                    Text(
                      roomState.currentRoom!.code,
                      style: AppTheme.title.copyWith(letterSpacing: 6),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _isLeavingRoom
                                ? null
                                : () => context.goNamed(
                                    'lobby',
                                    pathParameters: {
                                      'roomCode': roomState.currentRoom!.code,
                                    },
                                  ),
                            child: const Text('Continue'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _isLeavingRoom ? null : _leaveActiveRoom,
                            // Words, not a spinner: a spinning indicator
                            // keeps an e-ink panel refreshing until it stops.
                            child: Text(
                              _isLeavingRoom ? 'Leaving...' : 'Leave Room',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                  ],

                  if (!roomState.isInRoom) ...[
                    TextField(
                      controller: _nicknameController,
                      decoration: const InputDecoration(
                        labelText: 'Nickname',
                        hintText: 'What should others call you?',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      style: AppTheme.body,
                      maxLength: 20,
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                    ),
                    const SizedBox(height: 20),

                    if (_isJoinMode) ...[
                      RoomCodeInput(controller: _roomCodeController),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: roomState.isLoading
                                  ? null
                                  : () => setState(() => _isJoinMode = false),
                              child: const Text('Back'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: roomState.isLoading ? null : _joinRoom,
                              child: Text(
                                roomState.isLoading ? 'Joining...' : 'Join Room',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      ElevatedButton.icon(
                        onPressed: roomState.isLoading ? null : _createRoom,
                        icon: const Icon(Icons.add),
                        label: Text(
                          roomState.isLoading ? 'Creating...' : 'Create Room',
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: roomState.isLoading
                            ? null
                            : () => setState(() => _isJoinMode = true),
                        icon: const Icon(Icons.login),
                        label: const Text('Join Room'),
                      ),
                    ],
                  ],

                  if (roomState.error != null || authState.error != null) ...[
                    const SizedBox(height: 20),
                    PaperNotice(message: roomState.error ?? authState.error!),
                  ],

                  const SizedBox(height: 40),

                  // Auth status
                  if (!SupabaseConfig.isConfigured)
                    const Text(
                      'Supabase not configured.\n'
                      'Run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
                      style: TextStyle(color: AppTheme.inkMuted, fontSize: 12),
                      textAlign: TextAlign.center,
                    )
                  else if (authState.isAuthenticated)
                    const Text(
                      'Connected',
                      style: AppTheme.caption,
                      textAlign: TextAlign.center,
                    )
                  else
                    Center(
                      child: TextButton(
                        onPressed: authState.isLoading
                            ? null
                            : () async {
                                await ref
                                    .read(authProvider.notifier)
                                    .signInAnonymously();
                              },
                        child: Text(
                          authState.isLoading
                              ? 'Connecting...'
                              : 'Tap to connect',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ), // end Scaffold
    ); // end PopScope
  }

  String? _validateNickname() {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      _showError('Please enter a nickname');
      return null;
    }
    return nickname;
  }

  Future<void> _createRoom() async {
    if (ref.read(roomProvider).isInRoom) {
      _showError('Leave the active room before creating another one.');
      return;
    }
    final nickname = _validateNickname();
    if (nickname == null) return;

    // Ensure authenticated
    if (!ref.read(authProvider).isAuthenticated) {
      await ref.read(authProvider.notifier).signInAnonymously();
    }

    ref.read(authProvider.notifier).setNickname(nickname);
    final room = await ref.read(roomProvider.notifier).createRoom(nickname);
    if (room != null && mounted) {
      context.goNamed('lobby', pathParameters: {'roomCode': room.code});
    }
  }

  Future<void> _joinRoom() async {
    if (ref.read(roomProvider).isInRoom) {
      _showError('Leave the active room before joining another one.');
      return;
    }
    final nickname = _validateNickname();
    if (nickname == null) return;

    final code = _roomCodeController.text.trim();
    if (code.length != 6) {
      _showError('Please enter a valid 6-character room code');
      return;
    }

    // Ensure authenticated
    if (!ref.read(authProvider).isAuthenticated) {
      await ref.read(authProvider.notifier).signInAnonymously();
    }

    ref.read(authProvider.notifier).setNickname(nickname);
    final room = await ref.read(roomProvider.notifier).joinRoom(code, nickname);
    if (room != null && mounted) {
      context.goNamed('lobby', pathParameters: {'roomCode': room.code});
    }
  }

  void _showError(String message) => showPaperMessage(context, message);

  Future<void> _leaveActiveRoom() async {
    if (_isLeavingRoom) return;
    setState(() => _isLeavingRoom = true);
    final errors = <String>[];
    try {
      await ref.read(presenceProvider.notifier).announceLeaving();
    } catch (error) {
      debugPrint('Unable to announce room departure: $error');
    }
    try {
      await ref.read(roomProvider.notifier).leaveRoom();
    } catch (error) {
      errors.add('room membership: $error');
    }
    try {
      await ref.read(presenceProvider.notifier).leaveRoom();
    } catch (error) {
      errors.add('realtime presence: $error');
    }
    await ref.read(bookProvider.notifier).reset();
    if (!mounted) return;
    setState(() => _isLeavingRoom = false);
    if (errors.isNotEmpty) {
      _showError('Room cleanup needs attention: ${errors.join('; ')}');
    }
  }
}
