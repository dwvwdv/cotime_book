import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/page_sync_state.dart';
import 'realtime_service.dart';

/// The small Realtime surface used by page synchronization.
///
/// Keeping this transport injectable makes the consensus state machine testable
/// without a live Supabase channel.
abstract interface class PageSyncTransport {
  Stream<Map<String, dynamic>> broadcastStream(String event);

  Stream<Map<String, dynamic>> get presenceStream;

  List<Map<String, dynamic>> getOnlineUsers();

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  });

  /// Advertises this reader's shared position in its Presence meta.
  Future<void> publishPosition(SharedPosition position);
}

class RealtimePageSyncTransport implements PageSyncTransport {
  final RealtimeService _realtimeService;
  final Future<void> Function(SharedPosition position) _publishPosition;

  const RealtimePageSyncTransport(
    this._realtimeService, {
    required Future<void> Function(SharedPosition position) publishPosition,
  }) : _publishPosition = publishPosition;

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) =>
      _realtimeService.broadcastStream(event);

  @override
  Stream<Map<String, dynamic>> get presenceStream =>
      _realtimeService.presenceStream;

  @override
  List<Map<String, dynamic>> getOnlineUsers() =>
      _realtimeService.getOnlineUsers();

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) {
    return _realtimeService.broadcast(event: event, payload: payload);
  }

  @override
  Future<void> publishPosition(SharedPosition position) =>
      _publishPosition(position);
}

/// Everyone-must-agree page turning.
///
/// ```
/// requester: request ──▶ (votes) ──▶ turn locally ──▶ commit(seq+1, cfi)
/// others:        confirm/decline ──────────────────────▶ display(cfi)
/// ```
///
/// Design rules, each one the answer to a way the previous protocol got stuck:
///
/// * **Readers agree on [SharedPosition.seq], never on CFI strings.** A CFI is
///   a product of local pagination, so two devices on the same page disagree
///   about it. Equality on CFIs rejected almost every turn between different
///   screens and nothing ever brought them back together.
/// * **The requester is the only coordinator.** Followers vote and follow the
///   commit; they never cancel a request because *their* view of the room
///   differs from the requester's.
/// * **Every reader advertises its position in Presence.** A lost commit, a
///   reader that re-enters, a reader that reconnects: all of them converge by
///   adopting the newest position anyone in the reader holds. Nothing has to
///   be retried against the database to recover.
/// * **Liveness is explicit.** The requester re-broadcasts its request while it
///   waits; a follower that stops hearing it drops it. No request can outlive
///   its requester, and a lost vote is re-sent on the next nudge.
/// * **Only readers who are in the reader with the book loaded are asked.**
///   Someone in the lobby, or whose app is in the background, never blocks the
///   room; they catch up from Presence when they come back.
class PageSyncService {
  static const requestEvent = 'page_turn_request';
  static const voteEvent = 'page_turn_vote';
  static const commitEvent = 'page_turn_commit';
  static const cancelEvent = 'page_turn_cancel';

  /// How long a failure stays on screen before the bar returns to idle.
  ///
  /// Every failure here is transient by construction: the protocol always
  /// lands back on [SyncStatus.idle], so a message that never clears reads as
  /// a permanently stuck reader even though page turns still work.
  static const defaultErrorAutoClearDelay = Duration(seconds: 6);

  /// Answering is a person finishing their page, so this is generous.
  static const defaultRequestTimeout = Duration(minutes: 2);
  static const defaultNudgeInterval = Duration(seconds: 8);
  static const defaultFollowerLiveness = Duration(seconds: 25);
  static const defaultTurnTimeout = Duration(seconds: 8);

  static const _maxRememberedRequestIds = 200;

  final PageSyncTransport _transport;
  final String _currentUserId;
  final String _currentNickname;
  final Uuid _uuid;
  final Duration _requestTimeout;
  final Duration _nudgeInterval;
  final Duration _followerLiveness;
  final Duration _turnTimeout;
  final Duration _errorAutoClearDelay;

  final _stateController = StreamController<PageSyncState>.broadcast();
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];

  /// Requests that are over for this client. A delayed copy or a nudge of one
  /// must not bring it back.
  final _finishedRequestIds = <String>{};

  /// Requests this reader agreed to, so a nudge can re-send a lost vote.
  final _acceptedRequestIds = <String>{};

  Timer? _requestTimeoutTimer;
  Timer? _nudgeTimer;
  Timer? _livenessTimer;
  Timer? _turnTimer;
  Timer? _errorAutoClearTimer;

  PageSyncState _state = const PageSyncState.idle();
  SharedPosition _position;
  bool _initialized = false;
  bool _disposed = false;
  bool _presenceSynchronized = false;
  bool _viewerReady = false;

  /// Requester only: move the viewer one page, then call [completeTurn].
  void Function(PageTurnCommand command)? onExecuteTurn;

  /// The room moved to a page this reader is not displaying.
  void Function(SharedPosition position)? onPositionChanged;

  /// A turn handed to [onExecuteTurn] will not be completed; the reader should
  /// go back to [position].
  void Function(String requestId)? onTurnAbandoned;

  PageSyncService({
    required PageSyncTransport transport,
    required String currentUserId,
    required String currentNickname,
    SharedPosition initialPosition = const SharedPosition.start(),
    Uuid uuid = const Uuid(),
    Duration requestTimeout = defaultRequestTimeout,
    Duration nudgeInterval = defaultNudgeInterval,
    Duration followerLiveness = defaultFollowerLiveness,
    Duration turnTimeout = defaultTurnTimeout,
    Duration errorAutoClearDelay = defaultErrorAutoClearDelay,
  }) : _transport = transport,
       _currentUserId = currentUserId,
       _currentNickname = currentNickname,
       _position = initialPosition,
       _uuid = uuid,
       _requestTimeout = requestTimeout,
       _nudgeInterval = nudgeInterval,
       _followerLiveness = followerLiveness,
       _turnTimeout = turnTimeout,
       _errorAutoClearDelay = errorAutoClearDelay;

  Stream<PageSyncState> get stateStream => _stateController.stream;
  PageSyncState get currentState => _state;
  SharedPosition get position => _position;
  bool get isPresenceSynchronized => _presenceSynchronized;

  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;

    _subscriptions.addAll([
      _transport.broadcastStream(requestEvent).listen(_onRequest),
      _transport.broadcastStream(voteEvent).listen(_onVote),
      _transport.broadcastStream(commitEvent).listen(_onCommit),
      _transport.broadcastStream(cancelEvent).listen(_onCancel),
      _transport.presenceStream.listen(_onPresence),
    ]);

    final users = _transport.getOnlineUsers();
    _presenceSynchronized = _isSelfPresent(users);
    // A reader entering mid-session starts from the database, which may be a
    // page behind whoever is already reading.
    _absorbPresencePositions(users);
    unawaited(_publishPosition());
    _updateState(const PageSyncState.idle());
  }

  /// Whether this reader's viewer can take part right now: loaded and not in
  /// the middle of moving. It only gates what *this* client starts; it never
  /// cancels a request someone else is running.
  void setViewerReady(bool isReady) {
    if (_disposed) return;
    _viewerReady = isReady;
  }

  Future<bool> requestPageTurn({required PageTurnDirection direction}) async {
    if (_disposed || !_initialized) return false;
    if (_state.status != SyncStatus.idle || _state.currentRequest != null) {
      return false;
    }
    if (!_viewerReady) {
      _setError('The book is still loading');
      return false;
    }

    final users = _transport.getOnlineUsers();
    if (!_presenceSynchronized && _isSelfPresent(users)) {
      _presenceSynchronized = true;
    }
    if (!_presenceSynchronized) {
      // Without a Presence view this client cannot know who else is reading,
      // and a turn taken now would skip their consent.
      _setError('Still connecting to the room');
      return false;
    }
    // Someone is already further on: go there instead of turning from a page
    // the room has left.
    if (_absorbPresencePositions(users)) return false;

    final request = PageTurnRequest(
      requestId: _uuid.v4(),
      requestedByUserId: _currentUserId,
      requestedByNickname: _currentNickname,
      direction: direction,
      fromSeq: _position.seq,
      requestedAt: DateTime.now().toUtc(),
      confirmedUserIds: {_currentUserId},
      requiredUserIds: {..._readyReaderIds(users), _currentUserId},
    );

    if (request.isConsensusReached) {
      // Reading alone: there is nobody to ask.
      _execute(request);
      return true;
    }

    _updateState(
      PageSyncState(status: SyncStatus.requesting, currentRequest: request),
    );
    _startRequesterTimers(request);

    try {
      await _transport.broadcast(
        event: requestEvent,
        payload: request.toJson(),
      );
    } catch (_) {
      if (_isCurrent(request)) {
        _finishRequest(request, error: 'Could not reach the other readers');
      }
      return false;
    }
    return _isCurrent(request);
  }

  Future<bool> confirmPageTurn() async {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        _state.status != SyncStatus.confirming ||
        !request.requiredUserIds.contains(_currentUserId)) {
      return false;
    }

    // Move to waiting before the send so a double tap cannot vote twice.
    _acceptedRequestIds.add(request.requestId);
    _updateState(
      PageSyncState(
        status: SyncStatus.waiting,
        currentRequest: request.copyWith(
          confirmedUserIds: {...request.confirmedUserIds, _currentUserId},
        ),
      ),
    );

    try {
      await _sendVote(request, accept: true);
      return true;
    } catch (_) {
      _acceptedRequestIds.remove(request.requestId);
      if (_isCurrent(request)) {
        // Keep the request: the reader can simply answer again.
        _updateState(
          PageSyncState(
            status: SyncStatus.confirming,
            currentRequest: request,
            errorMessage: 'Could not send your answer. Try again.',
          ),
        );
      }
      return false;
    }
  }

  Future<void> declinePageTurn() async {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestedByUserId == _currentUserId ||
        (_state.status != SyncStatus.confirming &&
            _state.status != SyncStatus.waiting)) {
      return;
    }
    _finishRequest(request);
    try {
      await _sendVote(
        request,
        accept: false,
        reason: 'declined_by_$_currentNickname',
      );
    } catch (_) {
      // The requester still times out, and stops nudging a reader who has
      // dropped the request locally.
    }
  }

  /// Requester only: the viewer landed on [targetCfi] after [onExecuteTurn].
  ///
  /// Returns the new shared position for the caller to persist, or null if the
  /// turn is no longer current.
  SharedPosition? completeTurn(String requestId, String targetCfi) {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestId != requestId ||
        _state.status != SyncStatus.turning ||
        targetCfi.isEmpty) {
      return null;
    }

    final next = SharedPosition(seq: request.fromSeq + 1, cfi: targetCfi);
    _position = next;
    _finishRequest(request);
    unawaited(_broadcastCommit(request, next));
    unawaited(_publishPosition());
    return next;
  }

  /// Requester only: the viewer could not move (first or last page, or the
  /// viewer was rebuilt underneath the turn).
  void abandonTurn(String requestId, {String reason = 'turn_failed'}) {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestId != requestId ||
        _state.status != SyncStatus.turning) {
      return;
    }
    _finishRequest(request, error: describeCancelReason(reason));
    unawaited(_broadcastCancelQuietly(request, reason));
    onTurnAbandoned?.call(requestId);
  }

  /// Leaves the reader. A request this client owns is withdrawn so nobody else
  /// waits for it; anything else is resolved by Presence.
  Future<void> leave() async {
    final request = _state.currentRequest;
    if (_disposed || request == null) return;
    _finishRequest(request);
    if (request.requestedByUserId == _currentUserId) {
      await _broadcastCancelQuietly(request, 'requester_left');
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming events

  void _onRequest(Map<String, dynamic> payload) {
    if (_disposed) return;

    final PageTurnRequest incoming;
    try {
      incoming = PageTurnRequest.fromJson(payload);
    } on FormatException {
      return;
    }
    // Realtime is configured with self: true.
    if (incoming.requestedByUserId == _currentUserId) return;
    if (_finishedRequestIds.contains(incoming.requestId)) return;

    final current = _state.currentRequest;
    if (current?.requestId == incoming.requestId) {
      // A nudge: the requester is still waiting.
      if (current!.requestedByUserId != _currentUserId) {
        _startLivenessTimer(current);
      }
      if (_acceptedRequestIds.contains(incoming.requestId)) {
        // The vote may have been lost; answering again is idempotent.
        unawaited(_sendVoteQuietly(incoming, accept: true));
      }
      return;
    }

    // The request may come from a page this reader has not reached yet.
    _absorbPresencePositions(_transport.getOnlineUsers());
    if (incoming.fromSeq < _position.seq) {
      if (incoming.requiredUserIds.contains(_currentUserId)) {
        // Tell the requester it is behind; it catches up from Presence.
        unawaited(
          _sendVoteQuietly(incoming, accept: false, reason: 'out_of_sync'),
        );
      }
      return;
    }
    // Not asked: this reader joined after the request and follows the commit.
    if (!incoming.requiredUserIds.contains(_currentUserId)) return;

    if (current == null) {
      _adoptIncoming(incoming);
      return;
    }
    // This reader's own turn is already moving; it makes the other stale.
    if (_state.status == SyncStatus.turning) return;

    if (!_wins(incoming, over: current)) {
      if (current.requestedByUserId == _currentUserId) {
        // Make sure the competing requester hears about the winner.
        unawaited(_broadcastRequestQuietly(current));
      }
      return;
    }

    // Two people pressing "next" at once want the same thing; the one that
    // loses the tie-break should not then have to tap again.
    final sameIntent =
        current.direction == incoming.direction &&
        (current.requestedByUserId == _currentUserId ||
            _acceptedRequestIds.contains(current.requestId));
    if (current.requestedByUserId == _currentUserId) {
      unawaited(_broadcastCancelQuietly(current, 'superseded'));
    }
    _finishRequest(current);
    _adoptIncoming(incoming, autoAccept: sameIntent);
  }

  void _onVote(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final userId = payload['user_id'];
    final accept = payload['accept'];
    if (requestId is! String || userId is! String || accept is! bool) return;

    final request = _state.currentRequest;
    if (request == null ||
        request.requestId != requestId ||
        !request.requiredUserIds.contains(userId)) {
      return;
    }

    if (accept) {
      final updated = request.copyWith(
        confirmedUserIds: {...request.confirmedUserIds, userId},
      );
      _updateState(_state.copyWith(currentRequest: updated));
      _checkConsensus(updated);
      return;
    }

    // Followers wait for the requester's cancel; only the coordinator decides.
    if (request.requestedByUserId != _currentUserId ||
        _state.status != SyncStatus.requesting) {
      return;
    }
    final reason = payload['reason'] is String
        ? payload['reason'] as String
        : 'declined';
    _finishRequest(request, error: describeCancelReason(reason));
    unawaited(_broadcastCancelQuietly(request, reason));
    if (reason == 'out_of_sync') {
      _absorbPresencePositions(_transport.getOnlineUsers());
    }
  }

  void _onCommit(Map<String, dynamic> payload) {
    if (_disposed) return;
    final seq = payload['seq'];
    final cfi = payload['cfi'];
    final requestId = payload['request_id'];
    if (seq is! int || seq < 0 || cfi is! String || cfi.isEmpty) return;
    if (requestId is String) _rememberFinished(requestId);

    _adoptRemotePosition(SharedPosition(seq: seq, cfi: cfi));
  }

  void _onCancel(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final userId = payload['user_id'];
    if (requestId is! String || userId is! String) return;

    final request = _state.currentRequest;
    if (request == null || request.requestId != requestId) {
      // Arrived before the request (or a nudge of it): never adopt it now.
      _rememberFinished(requestId);
      return;
    }
    if (userId != request.requestedByUserId || userId == _currentUserId) {
      return;
    }

    final reason = payload['reason'] is String
        ? payload['reason'] as String
        : 'cancelled';
    // Losing a tie-break is not news to the reader whose answer moved over to
    // the winner.
    _finishRequest(
      request,
      error: reason == 'superseded' ? null : describeCancelReason(reason),
    );
  }

  void _onPresence(Map<String, dynamic> _) {
    if (_disposed) return;
    final users = _transport.getOnlineUsers();
    final selfPresent = _isSelfPresent(users);
    if (selfPresent) _presenceSynchronized = true;

    _absorbPresencePositions(users);

    // An empty or partial view during a reconnect is not evidence that anyone
    // left. Pruning on it would let a requester turn alone.
    final request = _state.currentRequest;
    if (request == null || !selfPresent) return;

    if (request.requestedByUserId != _currentUserId) {
      if (!_isReading(request.requestedByUserId, users)) {
        _finishRequest(
          request,
          error: '${request.requestedByNickname} left the book',
        );
      }
      return;
    }

    if (_state.status != SyncStatus.requesting) return;
    final stillReading = request.requiredUserIds
        .where((id) => id == _currentUserId || _isReading(id, users))
        .toSet();
    if (stillReading.length == request.requiredUserIds.length) return;
    final updated = request.copyWith(requiredUserIds: stillReading);
    _updateState(_state.copyWith(currentRequest: updated));
    _checkConsensus(updated);
  }

  // ---------------------------------------------------------------------------
  // Transitions

  void _adoptIncoming(PageTurnRequest request, {bool autoAccept = false}) {
    _updateState(
      PageSyncState(status: SyncStatus.confirming, currentRequest: request),
    );
    _startLivenessTimer(request);
    if (autoAccept) unawaited(confirmPageTurn());
  }

  void _checkConsensus(PageTurnRequest request) {
    if (request.requestedByUserId != _currentUserId ||
        _state.status != SyncStatus.requesting ||
        !request.isConsensusReached) {
      return;
    }
    _execute(request);
  }

  void _execute(PageTurnRequest request) {
    _cancelRequestTimers();
    _updateState(
      PageSyncState(status: SyncStatus.turning, currentRequest: request),
    );
    final handler = onExecuteTurn;
    if (handler == null) {
      abandonTurn(request.requestId);
      return;
    }
    _turnTimer = Timer(_turnTimeout, () {
      abandonTurn(request.requestId);
    });
    handler(
      PageTurnCommand(
        requestId: request.requestId,
        direction: request.direction,
      ),
    );
  }

  /// Moves to [candidate] if it is newer than what this reader holds.
  bool _adoptRemotePosition(SharedPosition candidate) {
    if (!candidate.isNewerThan(_position)) return false;
    _position = candidate;

    final request = _state.currentRequest;
    if (request != null && request.fromSeq < candidate.seq) {
      final wasTurning =
          request.requestedByUserId == _currentUserId &&
          _state.status == SyncStatus.turning;
      if (request.requestedByUserId == _currentUserId) {
        unawaited(_broadcastCancelQuietly(request, 'superseded'));
      }
      _finishRequest(request);
      if (wasTurning) onTurnAbandoned?.call(request.requestId);
    }

    unawaited(_publishPosition());
    onPositionChanged?.call(candidate);
    return true;
  }

  bool _absorbPresencePositions(List<Map<String, dynamic>> users) {
    SharedPosition? newest;
    for (final user in users) {
      if (user['user_id'] == _currentUserId || user['is_reading'] != true) {
        continue;
      }
      final position = SharedPosition.fromPresence(user);
      if (position == null) continue;
      if (newest == null || position.isNewerThan(newest)) newest = position;
    }
    return newest != null && _adoptRemotePosition(newest);
  }

  /// Ends [request] locally, optionally leaving a message on the bar.
  void _finishRequest(PageTurnRequest request, {String? error}) {
    _rememberFinished(request.requestId);
    _acceptedRequestIds.remove(request.requestId);
    if (!_isCurrent(request)) return;
    _cancelRequestTimers();
    _updateState(
      error == null ? const PageSyncState.idle() : PageSyncState.error(error),
    );
  }

  // ---------------------------------------------------------------------------
  // Timers

  void _startRequesterTimers(PageTurnRequest request) {
    _cancelRequestTimers();
    _requestTimeoutTimer = Timer(_requestTimeout, () {
      final current = _state.currentRequest;
      if (_disposed || current?.requestId != request.requestId) return;
      _finishRequest(current!, error: _timeoutMessage(current));
      unawaited(_broadcastCancelQuietly(current, 'timeout'));
    });
    _nudgeTimer = Timer.periodic(_nudgeInterval, (_) {
      final current = _state.currentRequest;
      if (_disposed ||
          current?.requestId != request.requestId ||
          _state.status != SyncStatus.requesting) {
        return;
      }
      unawaited(_broadcastRequestQuietly(current!));
    });
  }

  void _startLivenessTimer(PageTurnRequest request) {
    _livenessTimer?.cancel();
    _livenessTimer = Timer(_followerLiveness, () {
      final current = _state.currentRequest;
      if (_disposed || current?.requestId != request.requestId) return;
      _finishRequest(current!, error: 'The page turn request expired');
    });
  }

  void _cancelRequestTimers() {
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = null;
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _turnTimer?.cancel();
    _turnTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Wire

  Future<void> _sendVote(
    PageTurnRequest request, {
    required bool accept,
    String? reason,
  }) {
    return _transport.broadcast(
      event: voteEvent,
      payload: {
        'request_id': request.requestId,
        'user_id': _currentUserId,
        'accept': accept,
        if (reason != null) 'reason': reason,
      },
    );
  }

  Future<void> _sendVoteQuietly(
    PageTurnRequest request, {
    required bool accept,
    String? reason,
  }) async {
    try {
      await _sendVote(request, accept: accept, reason: reason);
    } catch (_) {
      // The next nudge asks again.
    }
  }

  Future<void> _broadcastRequestQuietly(PageTurnRequest request) async {
    try {
      await _transport.broadcast(
        event: requestEvent,
        payload: request.toJson(),
      );
    } catch (_) {
      // The next nudge tries again; the timeout bounds the whole request.
    }
  }

  Future<void> _broadcastCancelQuietly(
    PageTurnRequest request,
    String reason,
  ) async {
    try {
      await _transport.broadcast(
        event: cancelEvent,
        payload: {
          'request_id': request.requestId,
          'user_id': _currentUserId,
          'reason': reason,
        },
      );
    } catch (_) {
      // Followers stop hearing nudges and drop the request on their own.
    }
  }

  Future<void> _broadcastCommit(
    PageTurnRequest request,
    SharedPosition position,
  ) async {
    try {
      await _transport.broadcast(
        event: commitEvent,
        payload: {
          'request_id': request.requestId,
          'user_id': _currentUserId,
          'seq': position.seq,
          'cfi': position.cfi,
        },
      );
    } catch (_) {
      // Presence carries the same position; the commit is only the fast path.
    }
  }

  Future<void> _publishPosition() async {
    if (_disposed) return;
    try {
      await _transport.publishPosition(_position);
    } catch (_) {
      // Re-sent with the next Presence update; the commit covers the gap.
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers

  /// Readers who are in the book with it loaded. Lobby members and readers
  /// whose app is in the background are not asked.
  Set<String> _readyReaderIds(List<Map<String, dynamic>> users) {
    return {
      for (final user in users)
        if (user['user_id'] is String &&
            user['user_id'] != _currentUserId &&
            user['is_reading'] == true &&
            user['reader_ready'] == true)
          user['user_id'] as String,
    };
  }

  bool _isReading(String userId, List<Map<String, dynamic>> users) {
    return users.any(
      (user) => user['user_id'] == userId && user['is_reading'] == true,
    );
  }

  bool _isSelfPresent(List<Map<String, dynamic>> users) {
    return users.any((user) => user['user_id'] == _currentUserId);
  }

  /// A request from a later page always wins; otherwise the lower id does.
  bool _wins(PageTurnRequest candidate, {required PageTurnRequest over}) {
    if (candidate.fromSeq != over.fromSeq) {
      return candidate.fromSeq > over.fromSeq;
    }
    return candidate.winsOver(over);
  }

  bool _isCurrent(PageTurnRequest request) =>
      !_disposed && _state.currentRequest?.requestId == request.requestId;

  void _rememberFinished(String requestId) {
    _finishedRequestIds.remove(requestId);
    _finishedRequestIds.add(requestId);
    while (_finishedRequestIds.length > _maxRememberedRequestIds) {
      _finishedRequestIds.remove(_finishedRequestIds.first);
    }
  }

  String _timeoutMessage(PageTurnRequest request) {
    final users = _transport.getOnlineUsers();
    final names =
        request.pendingUserIds
            .map((id) {
              for (final user in users) {
                if (user['user_id'] == id && user['nickname'] is String) {
                  final nickname = (user['nickname'] as String).trim();
                  if (nickname.isNotEmpty) return nickname;
                }
              }
              return null;
            })
            .whereType<String>()
            .toList()
          ..sort();
    if (names.isEmpty) return describeCancelReason('timeout');
    return 'Page turn timed out waiting for ${names.join(', ')}';
  }

  void _setError(String message) {
    _updateState(PageSyncState.error(message));
  }

  void _updateState(PageSyncState newState) {
    if (_disposed) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
    _scheduleErrorAutoClear(newState);
  }

  /// Clears a message so the bar stops reporting a finished failure as if the
  /// reader were still blocked on it. A request in flight keeps going.
  void _scheduleErrorAutoClear(PageSyncState newState) {
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = null;
    if (newState.errorMessage == null) return;
    _errorAutoClearTimer = Timer(_errorAutoClearDelay, () {
      _errorAutoClearTimer = null;
      if (_disposed || !identical(_state, newState)) return;
      _updateState(_state.copyWith(clearError: true));
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelRequestTimers();
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    onExecuteTurn = null;
    onPositionChanged = null;
    onTurnAbandoned = null;
    await _stateController.close();
  }
}

/// Turns a wire cancel reason into something a reader can act on.
///
/// The raw codes are protocol identifiers and stay on the wire.
String describeCancelReason(String reason) {
  const messages = <String, String>{
    'timeout': 'Page turn timed out waiting for the other readers',
    'out_of_sync': 'Readers were on different pages. Synced — try again',
    'requester_left': 'Page turn cancelled: the requester left',
    'superseded': 'Another page turn went first',
    'turn_failed':
        'The page did not move — this may be the start or end '
        'of the book',
  };

  final known = messages[reason];
  if (known != null) return known;

  const declinePrefix = 'declined_by_';
  if (reason.startsWith(declinePrefix)) {
    final nickname = reason.substring(declinePrefix.length).trim();
    return nickname.isEmpty
        ? 'A reader asked to wait on this page'
        : '$nickname asked to wait on this page';
  }
  return 'Page turn cancelled';
}
