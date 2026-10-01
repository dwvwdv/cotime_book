import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/theme.dart';
import '../models/page_sync_state.dart';
import '../providers/auth_provider.dart';
import '../providers/book_provider.dart';
import '../providers/page_sync_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/reading_preferences_provider.dart';
import '../providers/room_provider.dart';
import '../services/room_service.dart';
import '../widgets/page_turn_input.dart';
import '../widgets/paper.dart';
import '../widgets/reader_members_sheet.dart';
import '../widgets/sync_status_bar.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final String roomCode;

  const ReaderScreen({super.key, required this.roomCode});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  /// Caps the authoritative-position recovery poll so a room whose revision
  /// never advances cannot leave the reader stuck behind its blocking overlay.
  static const _maxPositionRecoveryAttempts = 10;

  EpubController? _epubController;
  String? _currentCfi;
  bool _isReaderReady = false;
  bool _isStoppingPageSync = false;
  PageTurnCommand? _queuedTurnCommand;
  PageTurnCommand? _awaitingTurnRelocation;
  String? _awaitingTurnRoomId;
  String? _queuedTargetCfi;
  String? _displayingTargetCfi;
  bool _recoveringAuthoritativePosition = false;
  bool _pendingAuthoritativeCfiSync = false;
  bool _authoritativeCfiSyncInFlight = false;
  Timer? _authoritativeRetryTimer;
  int _positionRecoveryGeneration = 0;
  Future<void> _cfiWriteChain = Future<void>.value();

  // Track key so we can rebuild the viewer when theme changes.
  int _viewerKey = 0;

  @override
  void initState() {
    super.initState();
    _epubController = EpubController();
    // Seed from cached room state immediately so the first build has a CFI.
    // A fresh DB fetch happens inside _initReader(); if the CFI differs the
    // viewer is rebuilt via _viewerKey.
    _currentCfi = ref.read(roomProvider).currentRoom?.currentCfi;
    WidgetsBinding.instance.addPostFrameCallback((_) => _initReader());
  }

  Future<void> _initReader() async {
    final authState = ref.read(authProvider);
    final realtimeService = ref.read(realtimeServiceProvider);

    if (!authState.isAuthenticated) return;
    final roomState = ref.read(roomProvider);
    final readingSessionId = roomState.readingSessionId;
    final participantUserIds = roomState.readingParticipantUserIds;
    if (readingSessionId == null ||
        participantUserIds.isEmpty ||
        !participantUserIds.contains(authState.userId)) {
      if (mounted) {
        context.goNamed(
          'lobby',
          pathParameters: {'roomCode': widget.roomCode},
        );
      }
      return;
    }

    // Entering the route means "reading", but the client must remain outside
    // the page-turn quorum until the EPUB controller has loaded its chapters.
    final presence = ref.read(presenceProvider.notifier);
    await presence.updateReaderReady(false);
    if (!mounted || _isStoppingPageSync) return;
    await presence.updateIsReading(true);
    if (!mounted || _isStoppingPageSync) return;

    final pageSync = ref.read(pageSyncProvider.notifier);
    pageSync.onPageTurn = _handlePageTurn;
    pageSync.onPositionCommit = _handlePositionCommit;
    pageSync.onPositionRecovery = _handlePositionRecovery;
    await pageSync.initialize(
      realtimeService: realtimeService,
      currentUserId: authState.userId!,
      currentNickname: authState.nickname,
      readingSessionId: readingSessionId,
      expectedParticipantUserIds: participantUserIds,
      initialCfi: _currentCfi,
    );
    if (!mounted || _isStoppingPageSync) return;

    // Fetch the latest room CFI from DB (in case other users advanced the page
    // while this user was away).  If it differs from cached, force viewer reload.
    await ref.read(roomProvider.notifier).refreshRoom();
    if (!mounted || _isStoppingPageSync) return;
    final freshRoom = ref.read(roomProvider).currentRoom;
    final freshCfi = freshRoom?.currentCfi;
    if (freshCfi != null && freshCfi != _currentCfi && mounted) {
      _adoptAuthoritativeCfi(freshCfi);
    }
    // Deriving readiness here is what keeps a deferred authoritative sync from
    // being undone: _adoptAuthoritativeCfi may have just marked this reader
    // unready, and this used to overwrite that with a bare _isReaderReady.
    _publishReadiness();
  }

  @override
  void dispose() {
    _isStoppingPageSync = true;
    ++_positionRecoveryGeneration;
    _authoritativeRetryTimer?.cancel();
    _authoritativeRetryTimer = null;
    final pageSync = ref.read(pageSyncProvider.notifier);
    pageSync.updateReaderContext(isReady: false, currentCfi: _currentCfi);
    unawaited(() async {
      try {
        await pageSync.leaveReadingSession();
      } catch (_) {
        // Route disposal cannot surface an unhandled Realtime send failure.
      } finally {
        await pageSync.stop();
      }
    }());
    final presence = ref.read(presenceProvider.notifier);
    unawaited(() async {
      // Preserve track ordering during route disposal so a slower
      // reader_ready=false update cannot overwrite the final lobby state.
      await presence.updateReaderReady(false);
      await presence.updateIsReading(false);
    }());
    _epubController = null;
    super.dispose();
  }

  void _handlePageTurn(PageTurnCommand command) {
    if (!mounted || _isStoppingPageSync) return;
    if (!_isReaderReady || _epubController == null) {
      _queuedTurnCommand = command;
      return;
    }
    _executePageTurn(command);
  }

  void _executePageTurn(PageTurnCommand command) {
    final controller = _epubController;
    if (controller == null || !_isReaderReady) {
      _queuedTurnCommand = command;
      return;
    }

    _queuedTurnCommand = null;
    _awaitingTurnRelocation = command;
    _awaitingTurnRoomId = ref.read(roomProvider).currentRoom?.id;
    if (command.direction == PageTurnDirection.next) {
      controller.next();
    } else {
      controller.prev();
    }
  }

  void _handlePositionCommit(PagePositionCommit commit) {
    if (!mounted || _isStoppingPageSync) return;
    _queuedTurnCommand = null;
    _awaitingTurnRelocation = null;
    _awaitingTurnRoomId = null;
    ref.read(bookProvider.notifier).updateCfi(commit.targetCfi);

    if (!_isReaderReady || _epubController == null) {
      _queuedTargetCfi = commit.targetCfi;
      return;
    }
    _displayCommittedPosition(commit.targetCfi);
  }

  void _handlePositionRecovery(
    String targetCfi,
    bool positionWasCommitted,
  ) {
    if (!mounted || _isStoppingPageSync) return;
    _queuedTurnCommand = null;
    _awaitingTurnRelocation = null;
    _awaitingTurnRoomId = null;
    _displayingTargetCfi = null;

    if (!positionWasCommitted) {
      final roomId = ref.read(roomProvider).currentRoom?.id;
      if (roomId != null) {
        final recoveryGeneration = ++_positionRecoveryGeneration;
        setState(() => _recoveringAuthoritativePosition = true);
        _publishReadiness();
        unawaited(
          _recoverAuthoritativePosition(
            fallbackCfi: targetCfi,
            roomId: roomId,
            recoveryGeneration: recoveryGeneration,
          ),
        );
        return;
      }
    }

    ref.read(bookProvider.notifier).updateCfi(targetCfi);

    if (!_isReaderReady || _epubController == null) {
      _queuedTargetCfi = targetCfi;
      return;
    }
    _displayCommittedPosition(targetCfi);
  }

  Future<void> _recoverAuthoritativePosition({
    required String fallbackCfi,
    required String roomId,
    required int recoveryGeneration,
  }) async {
    String? authoritativeCfi;
    final roomNotifier = ref.read(roomProvider.notifier);

    // Bounded: a refresh that keeps returning the same revision would
    // otherwise spin forever with the reader frozen and no way out, because
    // the overlay that blocks gestures is only cleared after this loop.
    for (var attempt = 0; attempt < _maxPositionRecoveryAttempts; attempt++) {
      if (!mounted ||
          _isStoppingPageSync ||
          recoveryGeneration != _positionRecoveryGeneration ||
          ref.read(roomProvider).currentRoom?.id != roomId) {
        break;
      }
      final cachedCfi = ref.read(roomProvider).currentRoom?.currentCfi;
      // The requester already received the authoritative row from its
      // successful write even when the following Realtime commit failed.
      if (cachedCfi != null && cachedCfi != fallbackCfi) {
        authoritativeCfi = cachedCfi;
        break;
      }

      final refreshedRoom = await roomNotifier.refreshRoomAndGet();
      if (refreshedRoom != null) {
        authoritativeCfi = refreshedRoom.currentCfi ?? fallbackCfi;
        break;
      }
      if (attempt + 1 < _maxPositionRecoveryAttempts) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    if (!mounted ||
        _isStoppingPageSync ||
        recoveryGeneration != _positionRecoveryGeneration ||
        ref.read(roomProvider).currentRoom?.id != roomId) {
      return;
    }

    if (authoritativeCfi == null) {
      // The write may well have committed before the response was lost, so
      // fallbackCfi is the pre-turn page and might already be wrong. Release
      // the overlay — the reader must not stay frozen, and they need to be
      // able to leave — but stay out of the quorum: a turn taken from an
      // unconfirmed position revision-retries over whatever the database
      // actually holds. Keep asking until a snapshot answers.
      setState(() => _recoveringAuthoritativePosition = false);
      _setPendingAuthoritativeSync(true);
      _scheduleAuthoritativePositionRetry();
      return;
    }

    final targetCfi = authoritativeCfi;
    ref.read(bookProvider.notifier).updateCfi(targetCfi);
    setState(() => _recoveringAuthoritativePosition = false);
    // This recovery *is* an authoritative read, so it satisfies a sync that was
    // deferred earlier. Leaving that flag set left this reader permanently
    // unready — blocking the whole room's quorum — because the page-sync error
    // transition happened while recovery was still running, so the listener
    // skipped it and nothing else would schedule another read.
    //
    // Cleared after the display starts, never before: while _displayingTargetCfi
    // is set the derived readiness is false, so this cannot publish a ready at
    // the pre-recovery page. onRelocated reopens the gate.
    if (_currentCfi != targetCfi) {
      _displayCommittedPosition(targetCfi);
      _setPendingAuthoritativeSync(false);
      return;
    }

    _setPendingAuthoritativeSync(false);
    _publishReadiness(currentCfi: targetCfi);
  }

  /// True only when this reader's position is known to match the room's.
  ///
  /// While an authoritative read is outstanding the displayed page is a guess,
  /// and a turn taken from a guess revision-retries over whatever the database
  /// actually holds. Everything that advertises readiness goes through here.
  bool get _canAdvertiseReady =>
      !_pendingAuthoritativeCfiSync && !_recoveringAuthoritativePosition;

  /// Whether this reader may take part in a page turn right now.
  ///
  /// Derived from state in one place rather than decided at each call site.
  /// Readiness used to be pushed imperatively from nine different places, and
  /// every one of them had to remember the full set of conditions; each bug
  /// found here was another site that had forgotten one. Call sites now change
  /// state and call [_publishReadiness] — they never compute the value.
  bool get _isReadyForTurns =>
      _isReaderReady &&
      !_isStoppingPageSync &&
      _displayingTargetCfi == null &&
      _canAdvertiseReady;

  /// Tells the sync service and the rest of the room what this reader can do.
  ///
  /// Both must agree: the service decides which requests this client accepts,
  /// Presence decides whether the others put it in their quorum. Publishing
  /// only one of them is what lets a client reject the turns it authorized.
  void _publishReadiness({String? currentCfi}) {
    final isReady = _isReadyForTurns;
    ref
        .read(pageSyncProvider.notifier)
        .updateReaderContext(
          isReady: isReady,
          currentCfi: currentCfi ?? _currentCfi,
        );
    unawaited(
      ref
          .read(presenceProvider.notifier)
          .updateReaderReady(isReady)
          .catchError((Object _) {
            // The cached Presence intent remains authoritative locally and is
            // retried by the connection lifecycle after transport recovery.
          }),
    );
  }

  void _setPendingAuthoritativeSync(bool isPending) {
    if (_pendingAuthoritativeCfiSync == isPending) return;
    _pendingAuthoritativeCfiSync = isPending;
    if (mounted) setState(() {});
    _publishReadiness();
  }

  void _scheduleAuthoritativePositionRetry() {
    _authoritativeRetryTimer?.cancel();
    _authoritativeRetryTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _isStoppingPageSync || !_pendingAuthoritativeCfiSync) {
        return;
      }
      unawaited(_syncAuthoritativePosition());
    });
  }

  void _displayCommittedPosition(String targetCfi) {
    _queuedTargetCfi = null;
    if (_currentCfi == targetCfi) {
      unawaited(
        ref.read(pageSyncProvider.notifier).acknowledgePagePosition(targetCfi),
      );
      return;
    }
    _displayingTargetCfi = targetCfi;
    _publishReadiness();
    _epubController?.display(cfi: targetCfi);
  }

  /// Moves the viewer onto the database's position.
  ///
  /// A refused rebuild leaves the viewer on the old page, so keeping the fresh
  /// CFI would make this client advertise a page it is not on. Dropping it
  /// outright is no better: nothing else re-reads the room, so a later page
  /// turn would write a position derived from the stale one over the newer
  /// database value. The retry is therefore deferred until the request that
  /// blocked the rebuild settles.
  /// Returns whether the viewer actually started rebuilding.
  bool _adoptAuthoritativeCfi(String freshCfi) {
    final previousCfi = _currentCfi;
    _currentCfi = freshCfi;
    if (_rebuildViewer()) return true;
    _currentCfi = previousCfi;
    _setPendingAuthoritativeSync(true);
    return false;
  }

  Future<void> _syncAuthoritativePosition() async {
    if (_authoritativeCfiSyncInFlight) return;
    _authoritativeCfiSyncInFlight = true;
    try {
      // Re-read rather than replaying the CFI captured earlier: the request
      // that blocked the rebuild may itself have advanced the room.
      //
      // Only an authoritative read may move the viewer. refreshRoom() absorbs
      // network errors, and the cached room is not updated by a *follower*
      // completing a turn — only the requester writes it — so falling back to
      // the cache here would rebuild the viewer at a page older than the one
      // this reader has already displayed.
      final room = await ref.read(roomProvider.notifier).refreshRoomAndGet();
      if (!mounted || _isStoppingPageSync) return;
      if (room == null) {
        _setPendingAuthoritativeSync(true);
        _scheduleAuthoritativePositionRetry();
        return;
      }
      final freshCfi = room.currentCfi;
      if (freshCfi == null || freshCfi == _currentCfi) {
        // Confirmed on the page already displayed: rejoin the quorum now.
        _setPendingAuthoritativeSync(false);
        return;
      }
      // Rebuild first, then open the gate. Clearing it first would publish
      // readiness for the *old* viewer, and Presence updates are serialized —
      // peers could start a turn on that before the rebuild's not-ready
      // arrives. onChaptersLoaded reopens it once the new page is displayed.
      if (_adoptAuthoritativeCfi(freshCfi)) {
        _setPendingAuthoritativeSync(false);
      }
    } finally {
      _authoritativeCfiSyncInFlight = false;
    }
  }

  bool get _canRebuildViewer =>
      !_isStoppingPageSync &&
      ref.read(pageSyncProvider).currentRequest == null;

  /// Returns false when a rebuild is refused, leaving the viewer untouched.
  bool _rebuildViewer() {
    if (!_canRebuildViewer) return false;
    _isReaderReady = false;
    _publishReadiness();
    setState(() => _viewerKey++);
    return true;
  }

  Future<void> _commitRequesterPosition(
    PageTurnCommand command,
    String targetCfi,
    String roomId,
  ) async {
    if (!command.isRequester || _isStoppingPageSync) return;
    // The requester is the sole database writer. Do not publish the Realtime
    // commit until its CFI is durable; followers therefore never advance to a
    // position that a later join cannot load from the database.
    final roomNotifier = ref.read(roomProvider.notifier);
    _cfiWriteChain = _cfiWriteChain.then((_) async {
      while (mounted &&
          !_isStoppingPageSync &&
          ref.read(pageSyncProvider.notifier).isRequestActive(command.requestId)) {
        try {
          final pageSync = ref.read(pageSyncProvider.notifier);
          if (!await pageSync.beginPositionPersistence(command.requestId)) {
            return;
          }
          await roomNotifier.updateCfiForRoom(roomId: roomId, cfi: targetCfi);
          if (!mounted ||
              _isStoppingPageSync ||
              !ref
                  .read(pageSyncProvider.notifier)
                  .isRequestActive(command.requestId)) {
            return;
          }
          final committed = await pageSync.commitPagePosition(targetCfi);
          if (committed) {
            await pageSync.acknowledgePagePosition(targetCfi);
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        } on RoomSessionChangedException {
          if (!mounted ||
              _isStoppingPageSync ||
              ref.read(roomProvider).currentRoom?.id != roomId ||
              !ref
                  .read(pageSyncProvider.notifier)
                  .isRequestActive(command.requestId)) {
            return;
          }
          await roomNotifier.refreshRoom();
          await Future<void>.delayed(const Duration(seconds: 2));
        } catch (error) {
          ref
              .read(pageSyncProvider.notifier)
              .reportPositionPersistenceFailure(
                requestId: command.requestId,
                error: error,
              );
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    });
    await _cfiWriteChain;
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(pageSyncProvider);
    final presenceState = ref.watch(presenceProvider);
    final bookState = ref.watch(bookProvider);
    final prefs = ref.watch(readingPreferencesProvider);

    ref.listen<PageSyncState>(pageSyncProvider, (previous, next) {
      if (!_pendingAuthoritativeCfiSync ||
          next.currentRequest != null ||
          _isStoppingPageSync ||
          _recoveringAuthoritativePosition) {
        return;
      }
      // The gate stays shut until _syncAuthoritativePosition has a snapshot in
      // hand. Clearing it here would re-enable the controls for the duration of
      // the read, and a turn started in that window writes from the very CFI
      // the read exists to verify. Re-entry is held off by the in-flight flag.
      unawaited(_syncAuthoritativePosition());
    });

    if (bookState.bookFile == null) {
      // Without a way back this state is a dead end: the reader route has no
      // navigation stack to pop, so hardware back leaves the app instead.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _returnToLobby();
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Reader')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No book loaded'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _returnToLobby,
                  child: const Text('Back to Lobby'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Feature 2: intercept hardware back button in reader → go back to lobby.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveReader();
      },
      child: Scaffold(
        backgroundColor: prefs.backgroundColor,
        body: SafeArea(
          // Physical page buttons, Bluetooth page turners and keyboards. The
          // viewer absorbs pointers, so the WebView never takes focus from
          // this node.
          child: Focus(
            autofocus: true,
            onKeyEvent: (_, event) => _handleKeyEvent(event),
            child: Column(
              children: [
                // Sync status bar. Fixed height: see SyncStatusBar.height.
                SyncStatusBar(
                  syncState: syncState,
                  onlineUsers: presenceState.onlineUsers,
                  ink: prefs.textColor,
                  paper: prefs.backgroundColor,
                  onConfirm: () => unawaited(
                    ref.read(pageSyncProvider.notifier).confirmPageTurn(),
                  ),
                  onDecline: () => unawaited(
                    ref.read(pageSyncProvider.notifier).declinePageTurn(),
                  ),
                ),

                // EPUB reader with gesture overlay
                Expanded(
                  child: Stack(
                    children: [
                      // Layer 1: EPUB viewer
                      AbsorbPointer(
                        absorbing: true,
                        child: EpubViewer(
                          key: ValueKey(_viewerKey),
                          epubController: _epubController!,
                          epubSource: EpubSource.fromFile(bookState.bookFile!),
                          displaySettings: prefs.displaySettings,
                          initialCfi: _currentCfi,
                          onChaptersLoaded: (chapters) {
                            if (!mounted || _isStoppingPageSync) return;
                            setState(() => _isReaderReady = true);
                            // A viewer reload does not confirm the position, so
                            // loading a new viewer — a theme change, say — must
                            // not put this client back in the quorum while a
                            // recovery is still pending. _publishReadiness knows.
                            _publishReadiness();

                            final targetCfi = _queuedTargetCfi;
                            if (targetCfi != null) {
                              _displayCommittedPosition(targetCfi);
                              return;
                            }
                            final queuedTurn = _queuedTurnCommand;
                            if (queuedTurn != null) _executePageTurn(queuedTurn);
                          },
                          onRelocated: (location) {
                            if (!mounted || _isStoppingPageSync) return;
                            final committedTarget = _displayingTargetCfi;
                            final relocatedCfi =
                                committedTarget ?? location.startCfi;
                            _currentCfi = relocatedCfi;
                            if (committedTarget != null) {
                              setState(() => _displayingTargetCfi = null);
                            }
                            ref
                                .read(bookProvider.notifier)
                                .updateCfi(relocatedCfi);
                            _publishReadiness(currentCfi: relocatedCfi);

                            if (committedTarget != null) {
                              unawaited(
                                ref
                                    .read(pageSyncProvider.notifier)
                                    .acknowledgePagePosition(relocatedCfi),
                              );
                            }

                            final command = _awaitingTurnRelocation;
                            final roomId = _awaitingTurnRoomId;
                            if (command != null) {
                              _awaitingTurnRelocation = null;
                              _awaitingTurnRoomId = null;
                              if (roomId != null) {
                                unawaited(
                                  _commitRequesterPosition(
                                    command,
                                    relocatedCfi,
                                    roomId,
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),

                      // Layer 2: Gesture interceptor overlay
                      if (_isReaderReady)
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, constraints) => GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // Tap zones are how e-readers turn pages; a
                              // swipe on e-ink is slow to register and
                              // easily read as a tap anyway.
                              onTapUp: (details) => _requestTurnFromInput(
                                pageTurnDirectionForTap(
                                  dx: details.localPosition.dx,
                                  width: constraints.maxWidth,
                                ),
                              ),
                              onHorizontalDragEnd: (details) {
                                final velocity = details.primaryVelocity;
                                if (velocity == null) return;
                                if (velocity < -200) {
                                  _requestTurnFromInput(PageTurnDirection.next);
                                } else if (velocity > 200) {
                                  _requestTurnFromInput(
                                    PageTurnDirection.previous,
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Bottom navigation bar
                _buildBottomBar(syncState, prefs),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whether this reader may start a page turn of its own right now.
  bool _canRequestTurn(PageSyncState syncState) =>
      syncState.status == SyncStatus.idle &&
      _isReaderReady &&
      _canAdvertiseReady &&
      _displayingTargetCfi == null;

  /// One entry point for taps, swipes and keys.
  ///
  /// While someone else's request is waiting on this reader, turning the same
  /// way *is* agreeing to it: on an e-reader the page button is under the
  /// thumb and the Turn button is not. Turning the other way does nothing —
  /// declining stays an explicit choice.
  void _requestTurnFromInput(PageTurnDirection direction) {
    if (!mounted || _isStoppingPageSync) return;
    final syncState = ref.read(pageSyncProvider);
    final pageSync = ref.read(pageSyncProvider.notifier);
    final request = syncState.currentRequest;
    if (syncState.status == SyncStatus.confirming && request != null) {
      if (request.direction == direction) {
        unawaited(pageSync.confirmPageTurn());
      }
      return;
    }
    if (!_canRequestTurn(syncState)) return;
    unawaited(
      pageSync.requestPageTurn(direction: direction, fromCfi: _currentCfi),
    );
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final direction = pageTurnDirectionForKey(
      event.logicalKey,
      volumeKeysTurnPages: ref
          .read(readingPreferencesProvider)
          .volumeKeysTurnPages,
    );
    if (direction == null) return KeyEventResult.ignored;
    // Claim the repeat and the release too, so a held volume key does not
    // leak through to the system volume halfway through.
    if (event is KeyDownEvent) _requestTurnFromInput(direction);
    return KeyEventResult.handled;
  }

  Widget _buildBottomBar(PageSyncState syncState, ReadingPreferences prefs) {
    final canTurn = _canRequestTurn(syncState);
    final ink = prefs.textColor;
    final paper = prefs.backgroundColor;
    final disabledInk = ink.withValues(alpha: 0.35);
    final iconStyle = IconButton.styleFrom(
      foregroundColor: ink,
      disabledForegroundColor: disabledInk,
      minimumSize: const Size(52, 52),
    );
    final pageButtonStyle = OutlinedButton.styleFrom(
      foregroundColor: ink,
      disabledForegroundColor: disabledInk,
      backgroundColor: paper,
      minimumSize: const Size(64, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      side: BorderSide(
        color: canTurn ? ink : disabledInk,
        width: AppTheme.ruleWidth,
      ),
    );

    // Fixed height for the same reason as the status bar: the viewer must
    // never be resized by its own chrome.
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: paper,
        border: Border(top: BorderSide(color: ink, width: AppTheme.ruleWidth)),
      ),
      child: Row(
        children: [
          IconButton(
            style: iconStyle,
            icon: const Icon(Icons.arrow_back),
            onPressed: syncState.currentRequest == null ? _leaveReader : null,
            tooltip: 'Leave reading',
          ),
          const Spacer(),
          OutlinedButton(
            style: pageButtonStyle,
            onPressed: canTurn
                ? () => _requestTurnFromInput(PageTurnDirection.previous)
                : null,
            child: const Icon(Icons.chevron_left, size: 32),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            style: pageButtonStyle,
            onPressed: canTurn
                ? () => _requestTurnFromInput(PageTurnDirection.next)
                : null,
            child: const Icon(Icons.chevron_right, size: 32),
          ),
          const Spacer(),
          IconButton(
            style: iconStyle,
            icon: const Icon(Icons.text_fields),
            onPressed:
                syncState.status == SyncStatus.idle &&
                    syncState.currentRequest == null &&
                    _isReaderReady &&
                    _canAdvertiseReady &&
                    !_isStoppingPageSync
                ? _showReadingSettings
                : null,
            tooltip: 'Reading settings',
          ),
          IconButton(
            style: iconStyle,
            icon: const Icon(Icons.people_outline),
            onPressed: _showMembersDrawer,
            tooltip: 'Room members',
          ),
        ],
      ),
    );
  }

  /// Applies a preference that changes how the book is laid out.
  ///
  /// The viewer only reads its settings when it loads, so the preference and
  /// the rebuild must happen together or not at all. Changing the preference
  /// while the rebuild is refused would repaint the margins in the new theme
  /// around a page still in the old one.
  void _applyLayoutPreference(
    void Function(ReadingPreferencesNotifier notifier) change,
  ) {
    if (!_canRebuildViewer) return;
    change(ref.read(readingPreferencesProvider.notifier));
    _rebuildViewer();
  }

  // Feature 1: reading theme, type size and page-turn keys.
  void _showReadingSettings() {
    unawaited(
      showPaperSheet<void>(
        context: context,
        builder: (sheetContext) => Consumer(
          builder: (context, ref, _) {
            final prefs = ref.watch(readingPreferencesProvider);
            final canChangeLayout =
                ref.watch(pageSyncProvider).currentRequest == null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Reading Settings', style: AppTheme.title),
                const SizedBox(height: 20),
                const SectionHeader(label: 'Page'),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final theme in const [
                      ReadingTheme.day,
                      ReadingTheme.sepia,
                      ReadingTheme.night,
                    ])
                      _ThemeOption(
                        preview: ReadingPreferences(theme: theme),
                        isSelected: prefs.theme == theme,
                        onTap: canChangeLayout
                            ? () => _applyLayoutPreference(
                                (notifier) => notifier.setTheme(theme),
                              )
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                const SectionHeader(label: 'Text size'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed:
                          canChangeLayout &&
                              prefs.fontSize > ReadingPreferences.minFontSize
                          ? () => _applyLayoutPreference(
                              (notifier) => notifier.setFontSize(
                                prefs.fontSize -
                                    ReadingPreferences.fontSizeStep,
                              ),
                            )
                          : null,
                      child: const Text('A−', style: TextStyle(fontSize: 16)),
                    ),
                    Expanded(
                      child: Text(
                        '${prefs.fontSize.round()}',
                        textAlign: TextAlign.center,
                        style: AppTheme.title,
                      ),
                    ),
                    OutlinedButton(
                      onPressed:
                          canChangeLayout &&
                              prefs.fontSize < ReadingPreferences.maxFontSize
                          ? () => _applyLayoutPreference(
                              (notifier) => notifier.setFontSize(
                                prefs.fontSize +
                                    ReadingPreferences.fontSizeStep,
                              ),
                            )
                          : null,
                      child: const Text('A+', style: TextStyle(fontSize: 22)),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SectionHeader(label: 'Turning pages'),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Volume keys turn pages',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'For e-readers whose page buttons act as volume keys.',
                    style: AppTheme.caption,
                  ),
                  value: prefs.volumeKeysTurnPages,
                  onChanged: (enabled) => ref
                      .read(readingPreferencesProvider.notifier)
                      .setVolumeKeysTurnPages(enabled),
                ),
                const Text(
                  'Tap the left third of the page to go back, anywhere else '
                  'to go forward. Page Up/Down and arrow keys work too.',
                  style: AppTheme.caption,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // Feature 3: Members panel showing who's reading and who left.
  void _showMembersDrawer() {
    unawaited(
      showPaperSheet<void>(
        context: context,
        builder: (_) => const ReaderMembersSheet(),
      ),
    );
  }

  Future<void> _leaveReader() async {
    // Feature 3: Mark this user as no longer reading.
    if (_isStoppingPageSync) return;
    if (ref.read(pageSyncProvider).currentRequest != null) {
      _showSyncError('Wait for the current synchronized page turn to finish.');
      return;
    }
    _isStoppingPageSync = true;
    final pageSync = ref.read(pageSyncProvider.notifier);
    pageSync.updateReaderContext(isReady: false, currentCfi: _currentCfi);
    final presence = ref.read(presenceProvider.notifier);
    try {
      await pageSync.leaveReadingSession();
    } catch (_) {
      // Presence state still marks this reader as leaving below.
    }
    try {
      await pageSync.stop();
    } catch (_) {
      // Local navigation must not be held hostage by a stale subscription.
    }
    try {
      await presence.updateReaderReady(false);
      await presence.updateIsReading(false);
    } catch (_) {
      // Presence reconciliation/room cleanup handles disconnected exits.
    }
    if (mounted) {
      context.goNamed('lobby', pathParameters: {'roomCode': widget.roomCode});
    }
  }

  void _returnToLobby() {
    if (!mounted) return;
    context.goNamed('lobby', pathParameters: {'roomCode': widget.roomCode});
  }

  void _showSyncError(String message) {
    if (!mounted) return;
    showPaperMessage(context, message);
  }
}

/// A miniature page in the theme picker.
class _ThemeOption extends StatelessWidget {
  final ReadingPreferences preview;
  final bool isSelected;
  final VoidCallback? onTap;

  const _ThemeOption({
    required this.preview,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${preview.themeLabel} theme',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              Container(
                width: 68,
                height: 88,
                decoration: BoxDecoration(
                  color: preview.backgroundColor,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  // Selection is a heavy frame, not an accent colour.
                  border: Border.all(
                    color: AppTheme.ink,
                    width: isSelected ? 4 : AppTheme.ruleWidth,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Aa',
                  style: TextStyle(
                    fontFamily: AppTheme.serif,
                    color: preview.textColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 24,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isSelected ? '✓ ${preview.themeLabel}' : preview.themeLabel,
                style: TextStyle(
                  color: AppTheme.ink,
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
