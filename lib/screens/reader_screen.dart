import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/theme.dart';
import '../models/page_sync_state.dart';
import '../models/shared_page.dart';
import '../providers/auth_provider.dart';
import '../providers/book_provider.dart';
import '../providers/page_sync_provider.dart';
import '../providers/presence_provider.dart';
import '../providers/reading_preferences_provider.dart';
import '../providers/room_provider.dart';
import '../services/shared_page_renderer.dart';
import '../widgets/page_turn_input.dart';
import '../widgets/paper.dart';
import '../widgets/reader_members_sheet.dart';
import '../widgets/sync_status_bar.dart';

/// The book, kept on the room's shared page.
///
/// The viewer never decides where the room is. [PageSyncService] owns the
/// shared position; this screen only (a) displays it, and (b) when this reader
/// is the one turning, moves one page and reports where it landed. Everything
/// the viewer reports on its own — a re-layout after a resize, a font change —
/// is local and never leaves this device.
///
/// The book is laid out on the room's [SharedPage], not on this screen, so a
/// page holds the same text for every reader (issue #20).
class ReaderScreen extends ConsumerStatefulWidget {
  final String roomCode;

  const ReaderScreen({super.key, required this.roomCode});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  /// A display that never reports back must not leave the reader unable to
  /// turn forever.
  static const _displayTimeout = Duration(seconds: 8);

  final EpubController _epubController = EpubController();
  int _viewerKey = 0;

  /// Where the current viewer instance opens. Fixed per instance.
  String? _viewerInitialCfi;

  /// The shared position is known and the viewer can be created.
  bool _positionKnown = false;

  /// The current viewer instance has the book.
  bool _chaptersLoaded = false;

  /// The area the viewer has on this screen, from the last layout.
  Size? _viewerSize;

  /// What this screen and text size need, as last published in Presence.
  PageFit? _ownFit;

  /// The page the room lays the book out on, from every reader's fit.
  SharedPage? _roomPage;

  /// The page the current viewer instance is laid out on. Null until the
  /// first layout lands.
  SharedPage? _appliedPage;

  /// A layout is being applied. Its relocations are re-layouts, not moves.
  bool _layoutInFlight = false;
  int _layoutGeneration = 0;
  bool _layoutSyncScheduled = false;

  /// The last layout did not reach the WebView; try it again.
  bool _layoutOwed = false;
  int _layoutAttempts = 0;
  Timer? _layoutRetryTimer;

  /// Loaded *and* on the room's page. Until the book is laid out like
  /// everyone else's, a CFI from this viewer would mean a different page.
  bool get _viewerLoaded =>
      _chaptersLoaded && _appliedPage != null && !_layoutInFlight;

  /// Last page start the viewer reported. Null until it has displayed once.
  String? _lastLocalCfi;

  /// `display(cfi)` calls that have not relocated yet. A count, not a flag:
  /// two commits can arrive while the first display is still rendering, and
  /// the first relocation must not open the gate for the second.
  int _displaysInFlight = 0;
  String? _displayingCfi;
  Timer? _displayTimer;

  bool get _isDisplaying => _displaysInFlight > 0;

  /// A position that arrived before the viewer could show it.
  String? _queuedCfi;

  /// This reader's own turn: the page it left, and which request it was.
  _PendingTurn? _pendingTurn;

  /// After an abandoned turn the viewer may still move late; if it does, put
  /// it back on the room's page.
  String? _snapBackFrom;

  bool _leaving = false;

  PageSyncNotifier get _pageSync => ref.read(pageSyncProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initReader());
  }

  Future<void> _initReader() async {
    final authState = ref.read(authProvider);
    if (!authState.isAuthenticated || authState.userId == null) {
      _returnToLobby();
      return;
    }

    final presence = ref.read(presenceProvider.notifier);
    try {
      // In the reader, but not in anyone's quorum until the book has loaded.
      await presence.updateReaderReady(false);
      await presence.updateIsReading(true);
    } catch (_) {
      // Re-sent with the next Presence update once the channel is back.
    }
    if (!mounted || _leaving) return;

    // The database is where an empty room left off. Presence, read inside
    // initialize(), moves that forward to whoever is already further along.
    final room =
        await ref.read(roomProvider.notifier).refreshRoomAndGet() ??
        ref.read(roomProvider).currentRoom;
    if (!mounted || _leaving) return;

    final pageSync = _pageSync;
    pageSync.onExecuteTurn = _handleExecuteTurn;
    pageSync.onPositionChanged = _handlePositionChanged;
    pageSync.onTurnAbandoned = _handleTurnAbandoned;
    await pageSync.initialize(
      realtimeService: ref.read(realtimeServiceProvider),
      currentUserId: authState.userId!,
      currentNickname: authState.nickname,
      initialPosition: SharedPosition(seq: 0, cfi: room?.currentCfi ?? ''),
    );
    if (!mounted || _leaving) return;

    final position = pageSync.position ?? const SharedPosition.start();
    setState(() {
      _viewerInitialCfi = position.cfi.isEmpty ? null : position.cfi;
      // The viewer is created on the position, so nothing is queued for it.
      _queuedCfi = null;
      _positionKnown = true;
    });
    _publishReadiness();
  }

  @override
  void dispose() {
    _displayTimer?.cancel();
    _layoutRetryTimer?.cancel();
    if (!_leaving) {
      // The route went away without _leaveReader (the room was revoked, say).
      _leaving = true;
      final pageSync = _pageSync;
      final presence = ref.read(presenceProvider.notifier);
      unawaited(() async {
        try {
          await pageSync.stop();
          await presence.updateReaderReady(false);
          await presence.updateIsReading(false);
        } catch (_) {
          // Route disposal cannot surface a Realtime failure.
        }
      }());
    }
    super.dispose();
  }

  /// Can this reader start or carry out a turn right now?
  bool get _viewerReadyForTurns =>
      !_leaving &&
      _viewerLoaded &&
      _lastLocalCfi != null &&
      !_isDisplaying &&
      _pendingTurn == null;

  /// Tells the sync service what this viewer can do, and the room whether this
  /// reader can be asked to confirm.
  void _publishReadiness() {
    if (!mounted) return;
    _pageSync.setViewerReady(_viewerReadyForTurns);
    final isLoaded = !_leaving && _viewerLoaded && _lastLocalCfi != null;
    unawaited(
      ref
          .read(presenceProvider.notifier)
          .updateReaderReady(isLoaded)
          .catchError((Object _) {
            // Re-sent with the next Presence update.
          }),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared position → viewer

  void _handlePositionChanged(SharedPosition position) {
    if (!mounted || _leaving) return;
    // A position that voids our turn arrives after onTurnAbandoned, which
    // already cleared it. One that does not (a tie-break on the page the turn
    // started from) is overtaken by the turn landing: displaying it now would
    // swallow the turn's relocation and orphan the turn.
    if (_pendingTurn != null) return;
    if (!_positionKnown || !_viewerLoaded) {
      _queuedCfi = position.cfi;
      return;
    }
    _display(position.cfi);
  }

  void _display(String cfi) {
    _queuedCfi = null;
    if (cfi.isEmpty || (_isDisplaying && _displayingCfi == cfi)) return;
    _displayingCfi = cfi;
    _displayTimer?.cancel();
    _displayTimer = Timer(_displayTimeout, () {
      if (!mounted || !_isDisplaying) return;
      _finishDisplays();
    });
    setState(() => _displaysInFlight++);
    _publishReadiness();
    try {
      _epubController.display(cfi: cfi);
    } catch (_) {
      _finishDisplays();
    }
  }

  void _finishDisplays() {
    _displayTimer?.cancel();
    _displayingCfi = null;
    setState(() => _displaysInFlight = 0);
    _publishReadiness();
  }

  // ---------------------------------------------------------------------------
  // This reader's own turn

  void _handleExecuteTurn(PageTurnCommand command) {
    if (!mounted || !_viewerReadyForTurns) {
      // Not "start or end of the book": the viewer was busy, and every reader
      // is shown this reason.
      _pageSync.abandonTurn(command.requestId, reason: 'requester_busy');
      return;
    }
    _snapBackFrom = null;
    _pendingTurn = _PendingTurn(
      requestId: command.requestId,
      fromLocalCfi: _lastLocalCfi,
    );
    _publishReadiness();
    try {
      if (command.direction == PageTurnDirection.next) {
        _epubController.next();
      } else {
        _epubController.prev();
      }
    } catch (_) {
      _pendingTurn = null;
      _pageSync.abandonTurn(command.requestId);
    }
  }

  void _handleTurnAbandoned(String requestId) {
    final turn = _pendingTurn;
    if (turn == null || turn.requestId != requestId) return;
    _pendingTurn = null;
    if (!mounted || _leaving) return;
    if (_lastLocalCfi != turn.fromLocalCfi) {
      // It moved after all: back to the room's page.
      final position = _pageSync.position;
      if (position != null) _display(position.cfi);
    } else {
      _snapBackFrom = turn.fromLocalCfi;
    }
    _publishReadiness();
  }

  void _onRelocated(EpubLocation location) {
    if (!mounted || _leaving) return;
    final cfi = location.startCfi;
    _lastLocalCfi = cfi;
    // The first render on this screen's own layout, or a re-layout onto the
    // room's page: nothing is waiting on it, and the page is shown once the
    // layout lands.
    if (!_viewerLoaded) return;

    final turn = _pendingTurn;
    if (turn != null) {
      // A re-layout of the page being left is not the turn landing.
      if (cfi == turn.fromLocalCfi) return;
      _pendingTurn = null;
      final position = _pageSync.completeTurn(turn.requestId, cfi);
      if (position != null) {
        unawaited(
          ref.read(roomProvider.notifier).saveReadingPosition(position.cfi),
        );
      }
      _publishReadiness();
      return;
    }

    if (_isDisplaying) {
      if (_displaysInFlight > 1) {
        setState(() => _displaysInFlight--);
      } else {
        _finishDisplays();
      }
      return;
    }

    final snapBackFrom = _snapBackFrom;
    if (snapBackFrom != null) {
      _snapBackFrom = null;
      final position = _pageSync.position;
      if (cfi != snapBackFrom && position != null) {
        _display(position.cfi);
        return;
      }
    }
    if (_flushQueuedPosition()) return;
    _publishReadiness();
  }

  void _onChaptersLoaded() {
    if (!mounted || _leaving) return;
    setState(() => _chaptersLoaded = true);
    _scheduleLayoutSync();
  }

  /// Shows a position that arrived while the viewer was still loading. Waits
  /// for both "chapters loaded" and the first relocation, whichever is last:
  /// the order between them is up to the WebView.
  bool _flushQueuedPosition() {
    final queued = _queuedCfi;
    if (queued == null || !_viewerLoaded || _lastLocalCfi == null) {
      return false;
    }
    _display(queued);
    return true;
  }

  bool get _canRebuildViewer =>
      !_leaving &&
      _pendingTurn == null &&
      ref.read(pageSyncProvider).currentRequest == null;

  /// Reloads the viewer on the shared page (theme and type size are only read
  /// when it loads). Returns false when a turn is in flight.
  bool _rebuildViewer() {
    if (!_canRebuildViewer) return false;
    final position = _pageSync.position ?? const SharedPosition.start();
    _displayTimer?.cancel();
    setState(() {
      _viewerKey++;
      _viewerInitialCfi = position.cfi.isEmpty ? null : position.cfi;
      _chaptersLoaded = false;
      // A new WebView starts on its own layout again.
      _appliedPage = null;
      _layoutInFlight = false;
      _layoutGeneration++;
      _layoutOwed = false;
      _layoutAttempts = 0;
      _layoutRetryTimer?.cancel();
      _lastLocalCfi = null;
      _displaysInFlight = 0;
      _displayingCfi = null;
      _queuedCfi = null;
      _snapBackFrom = null;
    });
    _publishReadiness();
    return true;
  }

  // ---------------------------------------------------------------------------
  // The shared page

  /// Called on every layout with the viewer's area. Publishes what this
  /// screen needs and works out which page the room is on.
  void _updateRoomPage(
    Size viewerSize,
    PresenceState presence,
    ReadingPreferences prefs,
  ) {
    _viewerSize = viewerSize;
    final own = PageFit.of(viewerSize, fontSize: prefs.fontSize);
    if (own != _ownFit) {
      _ownFit = own;
      final presenceNotifier = ref.read(presenceProvider.notifier);
      // Not from inside a layout: it notifies listeners.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _leaving || _ownFit != own) return;
        unawaited(
          presenceNotifier.updatePageFit(own).catchError((Object _) {
            // Re-sent with the next Presence update.
          }),
        );
      });
    }
    _roomPage = SharedPage.resolve(
      own: own,
      onlineUsers: presence.onlineUsers,
      presenceIsCurrent: presence.isConnected && presence.hasInitialSync,
      previous: _roomPage,
    );
    if (_roomPage != _appliedPage || _layoutOwed) _scheduleLayoutSync();
  }

  /// A new layout moves every page break, so it waits for a moment when
  /// nothing on this screen depends on the current ones.
  bool get _canApplyLayout =>
      mounted &&
      !_leaving &&
      _chaptersLoaded &&
      !_layoutInFlight &&
      !_isDisplaying &&
      _pendingTurn == null &&
      ref.read(pageSyncProvider).currentRequest == null;

  void _scheduleLayoutSync() {
    if (_layoutSyncScheduled) return;
    _layoutSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutSyncScheduled = false;
      unawaited(_syncPageLayout());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Lays the book out on the room's page, then shows the room's position on
  /// the new page breaks.
  Future<void> _syncPageLayout() async {
    final page = _roomPage;
    final viewerSize = _viewerSize;
    if (page == null ||
        viewerSize == null ||
        (page == _appliedPage && !_layoutOwed) ||
        !_canApplyLayout) {
      // A turn or a display in flight: the next build tries again.
      return;
    }
    final generation = ++_layoutGeneration;
    _layoutRetryTimer?.cancel();
    setState(() => _layoutInFlight = true);
    _publishReadiness();

    var applied = false;
    try {
      applied = await SharedPageRenderer.apply(
        _epubController,
        page,
        viewerSize,
      );
    } catch (_) {
      applied = false;
    }
    // A rebuilt viewer or a newer layout owns the screen now.
    if (!mounted || _leaving || generation != _layoutGeneration) return;

    // Reading goes on even if the script could not run: a reader stuck on
    // "loading" would leave the room without them. The page is retried.
    setState(() {
      _layoutInFlight = false;
      _appliedPage = page;
      _layoutOwed = false;
    });
    if (applied) {
      _layoutAttempts = 0;
    } else if (_layoutAttempts++ < 3) {
      _layoutRetryTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted || _appliedPage != page) return;
        _layoutOwed = true;
        _scheduleLayoutSync();
      });
    }

    // Every page break moved: back onto the room's page.
    final cfi = _queuedCfi ?? _pageSync.position?.cfi ?? '';
    if (cfi.isNotEmpty) {
      _display(cfi);
    } else {
      _queuedCfi = null;
      _publishReadiness();
    }
  }

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(pageSyncProvider);
    final presenceState = ref.watch(presenceProvider);
    final bookState = ref.watch(bookProvider);
    final prefs = ref.watch(readingPreferencesProvider);

    if (bookState.bookFile == null || !_positionKnown) {
      // Without a way back this state is a dead end: the reader route has no
      // navigation stack to pop, so hardware back leaves the app instead.
      final hasBook = bookState.bookFile != null;
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leaveReader();
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Reader')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Words, not a spinner: e-ink.
                Text(
                  hasBook ? 'Opening the book...' : 'No book loaded',
                  style: AppTheme.title,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _leaveReader,
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
                  isConnected: !presenceState.isReconnecting,
                  ink: prefs.textColor,
                  paper: prefs.backgroundColor,
                  onConfirm: () => unawaited(_pageSync.confirmPageTurn()),
                  onDecline: () => unawaited(_pageSync.declinePageTurn()),
                ),

                // EPUB reader with gesture overlay
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, viewerConstraints) {
                      _updateRoomPage(
                        viewerConstraints.biggest,
                        presenceState,
                        prefs,
                      );
                      return _buildViewer(bookState, prefs);
                    },
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

  Widget _buildViewer(BookState bookState, ReadingPreferences prefs) {
    return Stack(
      children: [
        // Layer 1: EPUB viewer
        AbsorbPointer(
          absorbing: true,
          child: EpubViewer(
            key: ValueKey(_viewerKey),
            epubController: _epubController,
            epubSource: EpubSource.fromFile(bookState.bookFile!),
            displaySettings: prefs.displaySettings,
            initialCfi: _viewerInitialCfi,
            onChaptersLoaded: (_) => _onChaptersLoaded(),
            onRelocated: _onRelocated,
          ),
        ),

        // Layer 2: Gesture interceptor overlay
        if (_viewerLoaded)
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
                    _requestTurnFromInput(PageTurnDirection.previous);
                  }
                },
              ),
            ),
          ),
      ],
    );
  }

  /// Whether this reader may start a page turn of its own right now.
  bool _canRequestTurn(PageSyncState syncState) =>
      syncState.status == SyncStatus.idle &&
      syncState.currentRequest == null &&
      _viewerReadyForTurns;

  /// One entry point for taps, swipes and keys.
  ///
  /// While someone else's request is waiting on this reader, turning the same
  /// way *is* agreeing to it: on an e-reader the page button is under the
  /// thumb and the Turn button is not. Turning the other way does nothing —
  /// declining stays an explicit choice.
  void _requestTurnFromInput(PageTurnDirection direction) {
    if (!mounted || _leaving) return;
    final syncState = ref.read(pageSyncProvider);
    final request = syncState.currentRequest;
    if (syncState.status == SyncStatus.confirming && request != null) {
      if (request.direction == direction) {
        unawaited(_pageSync.confirmPageTurn());
      }
      return;
    }
    if (!_canRequestTurn(syncState)) return;
    unawaited(_pageSync.requestPageTurn(direction: direction));
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
        border: Border(
          top: BorderSide(color: ink, width: AppTheme.ruleWidth),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            style: iconStyle,
            icon: const Icon(Icons.arrow_back),
            onPressed: _leaving ? null : _leaveReader,
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
                syncState.currentRequest == null && _viewerLoaded && !_leaving
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
                      // No reload: the new size goes out as this reader's
                      // fit, and the room's page follows once no turn is
                      // in flight.
                      onPressed: prefs.fontSize > ReadingPreferences.minFontSize
                          ? () => ref
                                .read(readingPreferencesProvider.notifier)
                                .setFontSize(
                                  prefs.fontSize -
                                      ReadingPreferences.fontSizeStep,
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
                      // No reload: the new size goes out as this reader's
                      // fit, and the room's page follows once no turn is
                      // in flight.
                      onPressed: prefs.fontSize < ReadingPreferences.maxFontSize
                          ? () => ref
                                .read(readingPreferencesProvider.notifier)
                                .setFontSize(
                                  prefs.fontSize +
                                      ReadingPreferences.fontSizeStep,
                                )
                          : null,
                      child: const Text('A+', style: TextStyle(fontSize: 22)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _textSizeNote(
                    ownFontSize: prefs.fontSize.round(),
                    othersFontSize: _largestFontSizeOfOthers(
                      ref.watch(presenceProvider).onlineUsers,
                    ),
                  ),
                  style: AppTheme.caption,
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

  int? _largestFontSizeOfOthers(List<Map<String, dynamic>> onlineUsers) {
    final currentUserId = ref.read(authProvider).userId;
    int? largest;
    for (final user in onlineUsers) {
      if (user['user_id'] == currentUserId || user['is_reading'] != true) {
        continue;
      }
      final fit = PageFit.fromWire(user['page_fit']);
      if (fit != null && (largest == null || fit.fontSize > largest)) {
        largest = fit.fontSize;
      }
    }
    return largest;
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

  /// Back to the lobby. Never blocked: a request this reader owns is
  /// withdrawn, and the others stop waiting for one it was asked about as soon
  /// as Presence shows it left.
  Future<void> _leaveReader() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    _displayTimer?.cancel();
    final pageSync = _pageSync;
    final presence = ref.read(presenceProvider.notifier);
    try {
      await pageSync.stop();
    } catch (_) {
      // Local navigation must not be held hostage by a stale subscription.
    }
    try {
      await presence.updateReaderReady(false);
      await presence.updateIsReading(false);
    } catch (_) {
      // Presence reconciliation handles disconnected exits.
    }
    _returnToLobby();
  }

  void _returnToLobby() {
    if (!mounted) return;
    context.goNamed('lobby', pathParameters: {'roomCode': widget.roomCode});
  }
}

class _PendingTurn {
  final String requestId;
  final String? fromLocalCfi;

  const _PendingTurn({required this.requestId, required this.fromLocalCfi});
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

/// Why the text may be larger than the size this reader picked.
String _textSizeNote({required int ownFontSize, required int? othersFontSize}) {
  const shared =
      'Everyone sees the same page: it fits the smallest screen in the '
      'room, at the largest text size anyone picked.';
  if (othersFontSize != null && othersFontSize > ownFontSize) {
    return 'Another reader picked $othersFontSize, so the room reads at '
        '$othersFontSize. $shared';
  }
  return shared;
}
