import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/theme.dart';
import '../models/room_member.dart';
import '../models/transfer_state.dart';
import '../providers/auth_provider.dart';
import '../providers/book_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/room_provider.dart';
import '../widgets/member_list.dart';
import '../widgets/paper.dart';
import '../widgets/room_code_display.dart';
import '../widgets/transfer_progress_widget.dart';

class RoomLobbyScreen extends ConsumerStatefulWidget {
  /// How often the lobby re-reads the member list on its own.
  ///
  /// Every other refresh is triggered by a signal — a Presence change, a
  /// join or leave broadcast — and a signal can be missed: the lobby was not
  /// on screen, the broadcast was dropped, the read raced the leave RPC. This
  /// is what guarantees a departed member eventually disappears anyway.
  static const rosterRefreshInterval = Duration(seconds: 15);

  /// A leave is announced *before* the leave RPC (Realtime authorization
  /// needs the membership to still exist), so a single read can land before
  /// the commit. Read again until it must have landed.
  static const leaveRefreshDelays = [
    Duration(milliseconds: 300),
    Duration(milliseconds: 1500),
    Duration(seconds: 4),
  ];

  final String roomCode;

  const RoomLobbyScreen({super.key, required this.roomCode});

  @override
  ConsumerState<RoomLobbyScreen> createState() => _RoomLobbyScreenState();
}

class _RoomLobbyScreenState extends ConsumerState<RoomLobbyScreen> {
  Timer? _rosterRefreshTimer;
  StreamSubscription? _transferSub;
  StreamSubscription? _bookSharedSub;
  StreamSubscription? _startReadingSub;
  StreamSubscription? _membershipChangedSub;
  StreamSubscription? _roomClosedSub;
  TransferState _transferState = const TransferState.idle();
  bool _isInitializing = true;
  bool _isLeaving = false;
  bool _isNavigatingToReader = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initRoom());
  }

  Future<void> _initRoom() async {
    try {
      await _cancelScreenSubscriptions();
      final authState = await _waitForAuthentication();
      if (!mounted) return;

      final roomState = ref.read(roomProvider);
      final room = roomState.currentRoom;
      if (room == null) {
        throw StateError('This room is not available on this device.');
      }
      if (room.code.toUpperCase() != widget.roomCode.toUpperCase()) {
        throw StateError(
          'Room link ${widget.roomCode.toUpperCase()} does not match your '
          'active room ${room.code}.',
        );
      }

      final userId = authState.userId!;
      final nickname = authState.nickname;

      if (room.currentBookHash != null &&
          !ref.read(bookProvider.notifier).hasBook(room.currentBookHash!)) {
        await ref
            .read(bookProvider.notifier)
            .loadExistingBook(room.currentBookHash!);
      }

      final ownMember = roomState.members
          .where((member) => member.userId == userId)
          .firstOrNull;

      final realtimeService = ref.read(realtimeServiceProvider);
      await ref
          .read(bookProvider.notifier)
          .initTransferService(
            realtimeService: realtimeService,
            currentUserId: userId,
            roomCode: room.code,
          );

      final transferService = ref.read(bookProvider.notifier).transferService;
      _transferState =
          transferService?.currentState ?? const TransferState.idle();
      _transferSub = transferService?.stateStream.listen((state) {
        if (mounted) setState(() => _transferState = state);
      });

      // Listen for book_shared events
      _bookSharedSub = realtimeService.broadcastStream('book_shared').listen((
        payload,
      ) {
        final bookHash = payload['file_hash'] as String?;
        final bookTitle = payload['title'] as String?;
        if (bookHash != null) {
          unawaited(
            ref.read(bookProvider.notifier).prepareForSharedBook(bookHash),
          );
          final roomNotifier = ref.read(roomProvider.notifier);
          roomNotifier.onBookSharedReceived(
            bookTitle: bookTitle ?? 'Unknown',
            bookHash: bookHash,
          );
          // The broadcast carries display metadata, while the authoritative
          // revision comes from the database update that preceded it.
          unawaited(roomNotifier.refreshRoom());
        }
      });

      _roomClosedSub = realtimeService.broadcastStream('room_closed').listen((
        _,
      ) {
        if (mounted) _leaveRoom(reason: 'This room has been closed.');
      });

      _membershipChangedSub = realtimeService
          .broadcastStream('membership_changed')
          .listen((payload) {
            if (!mounted) return;
            if (payload['user_id'] == userId) return;
            unawaited(
              _refreshMembersAfterMembershipSignal(
                // A join is already committed when it is announced; only a
                // leave races its own broadcast against the leave RPC.
                waitForCommit: payload['action'] != 'joined',
              ),
            );
          });

      // The host pulls everyone in the lobby into the reader.
      _startReadingSub = realtimeService
          .broadcastStream('start_reading')
          .listen((payload) {
            if (!mounted || _isNavigatingToReader) return;
            final currentRoom = ref.read(roomProvider).currentRoom;
            if (currentRoom == null ||
                payload['initiated_by'] != currentRoom.hostUserId) {
              return;
            }
            _enterReader(fromHost: true);
          });

      // Install application listeners before channel subscription. A fast
      // sender can otherwise deliver the first file chunk between Presence
      // join and transfer initialization. Joining is idempotent when returning
      // from the reader and updates the current Presence payload in place.
      await ref
          .read(presenceProvider.notifier)
          .joinRoom(
            roomCode: room.code,
            userId: userId,
            nickname: nickname,
            avatarColorIndex: ownMember?.avatarColorIndex ?? 0,
            hasBook:
                room.currentBookHash != null &&
                ref.read(bookProvider.notifier).hasBook(room.currentBookHash!),
            bookHash: room.currentBookHash,
            isReading: false,
            readerReady: false,
          );

      // Presence tells the others a connection appeared; it does not tell them
      // the database roster grew. Without this the members already in the
      // lobby keep showing the roster from before this member joined.
      // Not awaited: the announcement waits for the channel to subscribe, and
      // the lobby must not sit on a spinner for that.
      unawaited(
        ref.read(presenceProvider.notifier).announceJoining().catchError((
          Object error,
        ) {
          debugPrint('Unable to announce room arrival: $error');
        }),
      );

      // Coming back from the reader (or from Home) the cached roster is
      // whatever it was when this screen last listened, and Presence will not
      // fire again just because the lobby reappeared.
      unawaited(_refreshRoster());
      _rosterRefreshTimer?.cancel();
      _rosterRefreshTimer = Timer.periodic(
        RoomLobbyScreen.rosterRefreshInterval,
        (_) => unawaited(_refreshRoster()),
      );

      if (mounted) setState(() => _isInitializing = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<AuthState> _waitForAuthentication() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final authState = ref.read(authProvider);
      if (authState.isAuthenticated) return authState;
      if (authState.error != null) throw StateError(authState.error!);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) throw StateError('Room initialization was cancelled.');
    }
    throw StateError('Authentication timed out. Please return home and retry.');
  }

  @override
  void dispose() {
    _rosterRefreshTimer?.cancel();
    unawaited(_cancelScreenSubscriptions());
    super.dispose();
  }

  Future<void> _cancelScreenSubscriptions() async {
    await Future.wait<void>([
      if (_transferSub != null) _transferSub!.cancel(),
      if (_bookSharedSub != null) _bookSharedSub!.cancel(),
      if (_startReadingSub != null) _startReadingSub!.cancel(),
      if (_membershipChangedSub != null) _membershipChangedSub!.cancel(),
      if (_roomClosedSub != null) _roomClosedSub!.cancel(),
    ]);
    _transferSub = null;
    _bookSharedSub = null;
    _startReadingSub = null;
    _membershipChangedSub = null;
    _roomClosedSub = null;
  }

  Future<void> _refreshMembersAfterMembershipSignal({
    bool waitForCommit = true,
  }) async {
    if (!waitForCommit) {
      await _refreshRoster();
      return;
    }
    var elapsed = Duration.zero;
    for (final delay in RoomLobbyScreen.leaveRefreshDelays) {
      await Future<void>.delayed(delay - elapsed);
      elapsed = delay;
      if (!mounted) return;
      await _refreshRoster();
    }
  }

  Future<void> _refreshRoster() async {
    if (!mounted) return;
    final roomNotifier = ref.read(roomProvider.notifier);
    await Future.wait<void>([
      roomNotifier.refreshMembers(
        presenceUsers: ref.read(presenceProvider).onlineUsers,
      ),
      roomNotifier.refreshRoom(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final roomState = ref.watch(roomProvider);
    final presenceState = ref.watch(presenceProvider);
    final bookState = ref.watch(bookProvider);
    final authState = ref.watch(authProvider);
    final room = roomState.currentRoom;

    // Keep member online/hasBook status in sync with presence on every update
    ref.listen<PresenceState>(presenceProvider, (previous, next) {
      final notifier = ref.read(roomProvider.notifier);
      notifier.updateMembersFromPresence(next.onlineUsers);
      final previousIds = (previous?.onlineUserIds ?? const <String>[]).toSet();
      final nextIds = next.onlineUserIds.toSet();
      if (!const SetEquality<String>().equals(previousIds, nextIds)) {
        unawaited(
          notifier.refreshMembers(presenceUsers: next.onlineUsers),
        );
        unawaited(notifier.refreshRoom());
      }
    });

    if (_isInitializing) {
      // A static line rather than a spinner: on e-ink a spinner is a panel
      // refresh every frame for as long as the room takes to join.
      return const Scaffold(
        body: Center(
          child: Text('Opening the room...', style: AppTheme.title),
        ),
      );
    }

    final routeMatchesRoom =
        room != null &&
        room.code.toUpperCase() == widget.roomCode.toUpperCase();
    if (_initError != null || !routeMatchesRoom) {
      return _buildRouteError(
        _initError ?? 'This room is no longer available.',
      );
    }
    final activeRoom = room;
    final hasCurrentBook =
        activeRoom.currentBookHash != null &&
        ref.read(bookProvider.notifier).hasBook(activeRoom.currentBookHash!);

    final isHost = roomState.isHost;
    final lobby = LobbyReadiness.from(
      members: roomState.members,
      onlineUsers: presenceState.onlineUsers,
      currentUserId: authState.userId,
      currentBookHash: activeRoom.currentBookHash,
      hasLocalBook: hasCurrentBook,
      isHost: isHost,
      isConnected: presenceState.isConnected,
    );

    // Feature 2: hardware back → leave room properly.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveRoom();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Room Lobby'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _isLeaving ? null : () => _leaveRoom(),
            tooltip: 'Leave room',
          ),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'ROOM CODE',
                      style: AppTheme.overline,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Center(child: RoomCodeDisplay(code: activeRoom.code)),
                    const SizedBox(height: 24),

                    SectionHeader(
                      label: 'Members',
                      trailing: Text(
                        '${presenceState.onlineCount} online',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    Expanded(
                      child: MemberList(
                        members: roomState.members,
                        currentUserId: authState.userId,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Transfer progress
                    TransferProgressWidget(transferState: _transferState),

                    // Book info
                    if (activeRoom.currentBookTitle != null) ...[
                      _BookCard(
                        title: activeRoom.currentBookTitle!,
                        isReady: hasCurrentBook,
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                _isLeaving || bookState.isLoading
                                ? null
                                : _shareBook,
                            icon: const Icon(Icons.upload_file),
                            label: Text(
                              bookState.isLoading ? 'Loading...' : 'Share Book',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isLeaving || !lobby.canOpenReader
                                ? null
                                : lobby.isHostStart
                                ? _startReading
                                : () => _enterReader(fromHost: false),
                            icon: const Icon(Icons.auto_stories_outlined),
                            label: Text(
                              lobby.isHostStart
                                  ? 'Start Reading'
                                  : 'Join Reading',
                            ),
                          ),
                        ),
                      ],
                    ),
                    // A disabled button with no reason reads as broken.
                    if (lobby.hint != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        lobby.hint!,
                        style: AppTheme.caption,
                        textAlign: TextAlign.center,
                      ),
                    ],

                    if (bookState.error != null) ...[
                      const SizedBox(height: 12),
                      PaperNotice(message: bookState.error!),
                    ],
                    if (presenceState.error != null) ...[
                      const SizedBox(height: 8),
                      PaperNotice(
                        message: presenceState.error!,
                        icon: Icons.wifi_off,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _shareBook() async {
    await ref.read(bookProvider.notifier).pickAndShareBook();
  }

  Future<void> _startReading() async {
    final realtimeService = ref.read(realtimeServiceProvider);
    final currentRoom = ref.read(roomProvider).currentRoom;
    final currentUserId = ref.read(authProvider).userId;
    if (currentRoom == null || currentRoom.hostUserId != currentUserId) {
      _showError('Only the room host can start reading.');
      return;
    }
    try {
      await realtimeService.broadcast(
        event: 'start_reading',
        payload: {'room_code': widget.roomCode, 'initiated_by': currentUserId},
      );
      // Broadcast is configured with self=true; the listener navigates the
      // host too, so there is one path into the reader.
    } catch (error) {
      if (mounted) _showError('Unable to start reading: $error');
    }
  }

  /// Opens the reader on this device. Anyone with the book can go in at any
  /// time: the page they land on comes from whoever is already reading.
  void _enterReader({required bool fromHost}) {
    if (!mounted || _isNavigatingToReader || _isLeaving) return;
    final room = ref.read(roomProvider).currentRoom;
    final bookHash = room?.currentBookHash;
    if (room == null ||
        bookHash == null ||
        !ref.read(bookProvider.notifier).hasBook(bookHash)) {
      _showError(
        fromHost
            ? 'Reading has started. You can join as soon as the book arrives.'
            : 'The book is not on this device yet.',
      );
      return;
    }
    _isNavigatingToReader = true;
    context.goNamed('reader', pathParameters: {'roomCode': room.code});
  }

  Widget _buildRouteError(String message) {
    return Scaffold(
      appBar: AppBar(title: const Text('Room unavailable')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.meeting_room_outlined, size: 56),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppTheme.body,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.goNamed('home'),
                child: const Text('Return Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leaveRoom({String? reason}) async {
    if (_isLeaving) return;
    if (mounted) setState(() => _isLeaving = true);

    final errors = <String>[];
    try {
      await ref.read(presenceProvider.notifier).announceLeaving();
    } catch (error) {
      // The database leave remains authoritative. Presence sync and the stale
      // membership cleanup job provide eventual convergence if this hint fails.
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

    if (mounted) {
      final message = [
        if (reason != null) reason,
        if (errors.isNotEmpty)
          'Room cleanup needs attention: ${errors.join('; ')}',
      ].join('\n');
      if (message.isNotEmpty) _showError(message);
      context.goNamed('home');
    }
  }

  void _showError(String message) => showPaperMessage(context, message);
}

class _BookCard extends StatelessWidget {
  final String title;
  final bool isReady;

  const _BookCard({required this.title, required this.isReady});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.ink, width: AppTheme.ruleWidth),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        children: [
          // A book spine: a tall narrow block reads as "book" at a glance
          // without needing a cover image or a colour.
          Container(
            width: 34,
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.ink,
              borderRadius: BorderRadius.circular(2),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.menu_book_outlined,
              color: AppTheme.paper,
              size: 18,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: AppTheme.serif,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: AppTheme.ink,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  isReady ? 'Ready to read' : 'Receiving book...',
                  style: AppTheme.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the lobby's reading button does, and why it is disabled when it is.
///
/// The old rule required every database member to be online with the book
/// before the host could start. A member whose app had crashed stays in the
/// database until the server evicts them, and one whose transfer stalled never
/// got the book, so either one locked the whole room out of reading. Now
/// nobody else can hold this reader back: the host starts when the host has
/// the book, anyone with the book can join a session already running, and the
/// hint names who is still missing it.
class LobbyReadiness {
  final bool canOpenReader;

  /// The button starts a session for the room (host) rather than joining one.
  final bool isHostStart;
  final String? hint;

  const LobbyReadiness({
    required this.canOpenReader,
    required this.isHostStart,
    required this.hint,
  });

  factory LobbyReadiness.from({
    required List<RoomMember> members,
    required List<Map<String, dynamic>> onlineUsers,
    required String? currentUserId,
    required String? currentBookHash,
    required bool hasLocalBook,
    required bool isHost,
    required bool isConnected,
  }) {
    final someoneReading = onlineUsers.any(
      (user) =>
          user['user_id'] != currentUserId && user['is_reading'] == true,
    );
    final isHostStart = isHost;

    if (currentBookHash == null) {
      return LobbyReadiness(
        canOpenReader: false,
        isHostStart: isHostStart,
        hint: isHost
            ? 'Share a book to start reading.'
            : 'Waiting for someone to share a book.',
      );
    }
    if (!hasLocalBook) {
      return LobbyReadiness(
        canOpenReader: false,
        isHostStart: isHostStart,
        hint: 'The book is on its way to this device.',
      );
    }
    if (!isConnected) {
      return LobbyReadiness(
        canOpenReader: false,
        isHostStart: isHostStart,
        hint: 'Connecting to the room...',
      );
    }
    if (!isHost && !someoneReading) {
      return const LobbyReadiness(
        canOpenReader: false,
        isHostStart: false,
        hint: 'The host starts the reading session.',
      );
    }

    final onlineById = {
      for (final user in onlineUsers)
        if (user['user_id'] is String) user['user_id'] as String: user,
    };
    final stillReceiving = members
        .where((member) => member.userId != currentUserId)
        .where((member) {
          final presence = onlineById[member.userId];
          if (presence == null) return false;
          final hashes = presence['ready_book_hashes'];
          return !(hashes is List && hashes.contains(currentBookHash));
        })
        .map((member) => member.nickname)
        .toList()
      ..sort();

    return LobbyReadiness(
      canOpenReader: true,
      isHostStart: isHostStart,
      hint: stillReceiving.isEmpty
          ? null
          : '${stillReceiving.join(', ')} '
                '${stillReceiving.length == 1 ? 'is' : 'are'} still receiving '
                'the book and can join when it arrives.',
    );
  }
}
