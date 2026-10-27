import 'dart:async';

import 'package:uuid/uuid.dart';

import '../config/ad_config.dart';
import '../config/app_constants.dart';
import '../models/page_info.dart';
import '../models/page_sync_state.dart';
import 'presence_merge.dart';
import 'realtime_service.dart';

/// The small Realtime surface used by page synchronization.
///
/// Keeping this transport injectable makes the consensus state machine testable
/// without a live Supabase channel.
abstract interface class PageSyncTransport {
  Stream<Map<String, dynamic>> broadcastStream(String event);

  Stream<Map<String, dynamic>> get presenceStream;

  List<Map<String, dynamic>> getOnlineUsers();

  /// Whether the room channel is up. Presence read while it is down is stale
  /// (or empty), and a quorum built from it is wrong.
  bool get isConnected;

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  });
}

class RealtimePageSyncTransport implements PageSyncTransport {
  final RealtimeService _realtimeService;

  const RealtimePageSyncTransport(this._realtimeService);

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
  bool get isConnected => _realtimeService.isConnected;

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) {
    return _realtimeService.broadcast(event: event, payload: payload);
  }
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
/// * **Readers agree on [SharedPosition]'s (epoch, seq), never on CFI
///   strings.** A CFI is a product of local pagination, so two devices on the
///   same page disagree about it. Equality on CFIs rejected almost every turn
///   between different screens and nothing ever brought them back together.
/// * **The requester is the only coordinator.** Followers vote and follow the
///   commit; they never cancel a request because *their* view of the room
///   differs from the requester's.
/// * **Positions travel by Broadcast, never Presence.** Supabase closes the
///   channel of a client that sends more than five Presence updates in 30
///   seconds, and a page per Presence update hit that within a few turns.
///   A reader that arrives or reconnects asks for positions; everyone
///   answers, and also repeats their position every
///   [defaultPositionAnnounceInterval]. A lost commit, a re-entry, a
///   reconnect: all converge on the newest position anyone in the reader
///   holds, without the database.
/// * **Liveness is explicit.** The requester re-broadcasts its request while it
///   waits; a follower that stops hearing it drops it. No request can outlive
///   its requester, and a lost vote is re-sent on the next nudge.
/// * **Only readers who are in the reader with the book loaded are asked.**
///   Someone in the lobby, or whose app is in the background, never blocks the
///   room; they catch up when they come back.
/// * **A reader who drops out mid-book holds the room for a while.** Turning on
///   without them would leave them on another page when they reconnect, so
///   for [defaultReconnectGrace] nobody turns and the bar says who it is
///   waiting for. Leaving on purpose (to the lobby, or the room) is
///   announced and never holds anyone up.
/// * **Ad breaks are the room's, not each device's.** Every
///   [AdConfig.pageTurnsPerAd]th shared page is an ad break for everyone on
///   it, so the ads come up together. A reader whose ad is up holds the room
///   (announced over Broadcast, with the same nudge and liveness as a
///   request), and until every ad is closed nobody turns and the new page
///   stays covered — also for a reader whose ad never loaded, who would
///   otherwise read on while the others watch theirs (GH-63).
/// * **A jump is a turn with a destination.** It is asked, agreed and
///   committed like any turn, so it holds the same guarantees: the requester
///   moves its viewer to the page it picked and commits where it landed as
///   the next seq. Only apps on [AppConstants.pageJumpProtocol] understand
///   one; a jump is not put to a room where someone could not answer it.
class PageSyncService {
  static const requestEvent = 'page_turn_request';
  static const voteEvent = 'page_turn_vote';
  static const commitEvent = 'page_turn_commit';
  static const cancelEvent = 'page_turn_cancel';
  static const positionQueryEvent = 'page_position_query';
  static const positionEvent = 'page_position';
  static const readerLeftEvent = 'reader_left';
  static const membershipEvent = 'membership_changed';
  static const adBreakEvent = 'ad_break';

  static const defaultPositionAnnounceInterval = Duration(seconds: 20);
  static const defaultReconnectGrace = Duration(minutes: 1);

  /// How long an announced departure outweighs Presence, which is rate
  /// limited and may still show the reader for a while.
  static const departureMemory = Duration(seconds: 45);

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

  /// Short: on the first or last page the viewer simply never relocates, and
  /// everyone waits this long to find out.
  static const defaultTurnTimeout = Duration(seconds: 4);

  /// Longer than a turn: the page may be in a chapter the viewer has not
  /// loaded, and an e-reader takes a while to lay one out.
  static const defaultJumpTimeout = Duration(seconds: 10);

  /// How long a reader that reached an ad break without an ad of its own
  /// keeps the page covered to hear whether anyone else has one. The others
  /// learn of the page from the commit, so theirs is announced a round trip
  /// after this reader got there.
  static const defaultAdBreakSettle = Duration(seconds: 2);

  /// The longest this reader holds the room for its own ad. An ad is closed
  /// in well under this; it only stops a show that never reports back from
  /// holding everyone forever.
  static const defaultAdBreakLimit = Duration(minutes: 2);

  static const _maxRememberedRequestIds = 200;

  final PageSyncTransport _transport;
  final String _currentUserId;
  final String _currentNickname;
  final Uuid _uuid;
  final Duration _requestTimeout;
  final Duration _nudgeInterval;
  final Duration _followerLiveness;
  final Duration _turnTimeout;
  final Duration _jumpTimeout;
  final Duration _errorAutoClearDelay;
  final int Function() _mintEpoch;
  final Duration _positionAnnounceInterval;
  final Duration _reconnectGrace;
  final DateTime Function() _clock;
  final int _adBreakEvery;
  final Duration _adBreakSettle;
  final Duration _adBreakLimit;

  /// Other readers last seen in the reader: user id → nickname.
  final Map<String, String> _knownReaders = {};

  /// Readers who vanished from Presence while reading: user id → when.
  final Map<String, DateTime> _awaySince = {};

  /// Readers who said they left: user id → when.
  final Map<String, DateTime> _departedAt = {};
  Timer? _awayTimer;
  Timer? _announceTimer;
  bool _wasSelfPresent = false;

  /// The last ad break this reader reached. A page gets one break, however
  /// many times its position arrives.
  int _adBreakEpoch = -1;
  int _adBreakSeq = -1;

  /// Until when the page stays covered while this reader listens for the
  /// others' ads.
  DateTime? _adBreakSettleUntil;

  /// This reader's own ad is coming up or on screen.
  bool _holdingForAd = false;
  Timer? _adHoldLimitTimer;
  Timer? _adHoldAnnounceTimer;
  Timer? _adBreakTimer;

  /// Other readers whose ad is up: user id → who, and when it was last
  /// announced.
  final Map<String, _AdHold> _othersInAd = {};

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
  bool _viewerReady = false;

  /// Requester only: move the viewer one page (or to a jump's target), then
  /// call [completeTurn].
  void Function(PageTurnCommand command)? onExecuteTurn;

  /// The room moved to a page this reader is not displaying.
  void Function(SharedPosition position)? onPositionChanged;

  /// A turn handed to [onExecuteTurn] will not be completed; the reader should
  /// go back to [position].
  void Function(String requestId)? onTurnAbandoned;

  /// This reader reached an ad break. Returns whether it shows an ad, and so
  /// holds the room until it calls [endAdBreak].
  bool Function(SharedPosition position)? onAdBreak;

  /// This reader's ad held the room for [defaultAdBreakLimit] and the room
  /// went on without it. An ad still on screen is now in the way of nobody:
  /// the reader should stop being asked to confirm, as when the app is in
  /// the background, and not show one that has not come up yet.
  void Function()? onAdHoldExpired;

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
    Duration jumpTimeout = defaultJumpTimeout,
    Duration errorAutoClearDelay = defaultErrorAutoClearDelay,
    int Function()? mintEpoch,
    Duration positionAnnounceInterval = defaultPositionAnnounceInterval,
    Duration reconnectGrace = defaultReconnectGrace,
    DateTime Function()? clock,
    int adBreakEvery = AdConfig.pageTurnsPerAd,
    Duration adBreakSettle = defaultAdBreakSettle,
    Duration adBreakLimit = defaultAdBreakLimit,
  }) : _transport = transport,
       _currentUserId = currentUserId,
       _currentNickname = currentNickname,
       _position = initialPosition,
       _uuid = uuid,
       _requestTimeout = requestTimeout,
       _nudgeInterval = nudgeInterval,
       _followerLiveness = followerLiveness,
       _turnTimeout = turnTimeout,
       _jumpTimeout = jumpTimeout,
       _errorAutoClearDelay = errorAutoClearDelay,
       _mintEpoch = mintEpoch ?? _wallClockEpoch,
       _positionAnnounceInterval = positionAnnounceInterval,
       _reconnectGrace = reconnectGrace,
       _clock = clock ?? DateTime.now,
       _adBreakEvery = adBreakEvery,
       _adBreakSettle = adBreakSettle,
       _adBreakLimit = adBreakLimit;

  static int _wallClockEpoch() => DateTime.now().millisecondsSinceEpoch;

  /// Whether [position] is a page the room stops on for ads, every [every]
  /// pages. Counted on the shared seq, so every reader stops on the same one.
  static bool isAdBreakPage(SharedPosition position, {required int every}) =>
      every > 0 && position.seq > 0 && position.seq % every == 0;

  Stream<PageSyncState> get stateStream => _stateController.stream;
  PageSyncState get currentState => _state;

  /// This reader's own ad is coming up or on screen, and holds the room.
  bool get isHoldingForAd => _holdingForAd;
  SharedPosition get position => _position;

  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;

    _subscriptions.addAll([
      _transport.broadcastStream(requestEvent).listen(_onRequest),
      _transport.broadcastStream(voteEvent).listen(_onVote),
      _transport.broadcastStream(commitEvent).listen(_onCommit),
      _transport.broadcastStream(cancelEvent).listen(_onCancel),
      _transport.broadcastStream(positionQueryEvent).listen(_onPositionQuery),
      _transport.broadcastStream(positionEvent).listen(_onPosition),
      _transport.broadcastStream(readerLeftEvent).listen(_onReaderLeft),
      _transport.broadcastStream(membershipEvent).listen(_onMembership),
      _transport.broadcastStream(adBreakEvent).listen(_onAdBreak),
      _transport.presenceStream.listen(_onPresence),
    ]);

    _observeReaders(_transport.getOnlineUsers());
    // A reader entering mid-session starts from the database, which may be a
    // page behind whoever is already reading.
    unawaited(_askForPositions());
    _announceTimer = Timer.periodic(_positionAnnounceInterval, (_) {
      if (_transport.isConnected) unawaited(_announcePosition());
    });
    _updateState(const PageSyncState.idle());
  }

  /// Whether this reader's viewer can take part right now: loaded and not in
  /// the middle of moving. It only gates what *this* client starts; it never
  /// cancels a request someone else is running.
  void setViewerReady(bool isReady) {
    if (_disposed) return;
    _viewerReady = isReady;
  }

  Future<bool> requestPageTurn({required PageTurnDirection direction}) {
    // A jump without a target is dropped by everyone it is put to, and the
    // room would wait out the timeout for it.
    if (direction == PageTurnDirection.jump) return Future.value(false);
    return _request(direction);
  }

  /// Asks the room to go to [targetCfi], a page start on the shared page
  /// (the jump preview's). [label] is how the bar names it to the others.
  Future<bool> requestJump({required String targetCfi, PageInfo? label}) {
    if (targetCfi.isEmpty) return Future.value(false);
    return _request(
      PageTurnDirection.jump,
      targetCfi: targetCfi,
      targetLabel: label,
    );
  }

  Future<bool> _request(
    PageTurnDirection direction, {
    String targetCfi = '',
    PageInfo? targetLabel,
  }) async {
    if (_disposed || !_initialized) return false;
    if (_state.status != SyncStatus.idle || _state.currentRequest != null) {
      return false;
    }
    if (!_viewerReady) {
      _setError('The book is still loading');
      return false;
    }

    if (!_transport.isConnected) {
      // The channel is being rebuilt. Presence read now is stale or empty:
      // an empty view would let this reader turn alone without asking anyone.
      _setError('Reconnecting to the room — try again in a moment');
      return false;
    }
    final users = _transport.getOnlineUsers();
    // Not a one-time flag: right after a reconnect the new channel's
    // Presence is empty until it syncs, and a quorum built from it would be
    // this reader alone.
    if (!_isSelfPresent(users)) {
      _setError('Still connecting to the room');
      return false;
    }
    final away = _readersAway();
    if (away.isNotEmpty) {
      // Turning now would leave them on another page when they come back.
      _setError('Waiting for ${_joinNames(away)} to reconnect');
      return false;
    }
    if (_isInAdBreak()) {
      final inAd = _adNames();
      _setError(
        inAd.isEmpty
            ? 'Waiting for the ad break to finish'
            : 'Waiting for ${inAd.join(', ')} to finish an ad',
      );
      return false;
    }

    final required = {..._readyReaderIds(users), _currentUserId};
    if (direction == PageTurnDirection.jump) {
      // An older app drops the request without a word, and the room would
      // wait out the whole timeout for an answer that never comes.
      final cannotJump = [
        for (final user in users)
          if (user['user_id'] is String &&
              user['user_id'] != _currentUserId &&
              required.contains(user['user_id']) &&
              !presenceSpeaksProtocol(user, AppConstants.pageJumpProtocol))
            user['user_id'] as String,
      ];
      if (cannotJump.isNotEmpty) {
        final names = cannotJump.toSet().toList();
        _setError(
          '${_joinNames(names)} ${names.length == 1 ? 'needs' : 'need'} to '
          'update the app to jump to a page',
        );
        return false;
      }
    }

    final request = PageTurnRequest(
      requestId: _uuid.v4(),
      requestedByUserId: _currentUserId,
      requestedByNickname: _currentNickname,
      direction: direction,
      fromEpoch: _position.epoch,
      fromSeq: _position.seq,
      fromCfi: _position.cfi,
      targetCfi: targetCfi,
      targetLabel: targetLabel,
      requestedAt: DateTime.now().toUtc(),
      confirmedUserIds: {_currentUserId},
      requiredUserIds: required,
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

    final next = SharedPosition.committed(
      fromEpoch: request.fromEpoch,
      fromSeq: request.fromSeq,
      cfi: targetCfi,
      mintEpoch: _mintEpoch,
    );
    _position = next;
    _finishRequest(request);
    unawaited(_broadcastCommit(request, next));
    _reachedPage(next);
    return next;
  }

  /// This reader's ad is closed (or never came up): it stops holding the room.
  void endAdBreak() {
    if (_disposed || !_holdingForAd) return;
    _stopAdHold();
    unawaited(_announceAdBreak(active: false));
    _refreshAdBreak();
  }

  /// Requester only: the viewer could not move (first or last page, a jump
  /// it could not show, or the viewer was rebuilt underneath the turn).
  void abandonTurn(String requestId, {String? reason}) {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestId != requestId ||
        _state.status != SyncStatus.turning) {
      return;
    }
    reason ??= request.isJump ? 'jump_failed' : 'turn_failed';
    _finishRequest(request, error: describeCancelReason(reason));
    unawaited(_broadcastCancelQuietly(request, reason));
    onTurnAbandoned?.call(requestId);
  }

  /// Leaves the reader. A request this client owns is withdrawn so nobody else
  /// waits for it, and the departure is announced so nobody waits for this
  /// reader to "reconnect" either.
  Future<void> leave() async {
    if (_disposed) return;
    if (_holdingForAd) {
      _stopAdHold();
      await _announceAdBreak(active: false);
    }
    final request = _state.currentRequest;
    if (request != null) {
      _finishRequest(request);
      if (request.requestedByUserId == _currentUserId) {
        await _broadcastCancelQuietly(request, 'requester_left');
      }
    }
    try {
      await _transport.broadcast(
        event: readerLeftEvent,
        payload: {'user_id': _currentUserId},
      );
    } catch (_) {
      // Presence shows the departure too, only later.
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
    if (incoming.fromCfi.isNotEmpty) {
      _adoptRemotePosition(
        SharedPosition(
          epoch: incoming.fromEpoch,
          seq: incoming.fromSeq,
          cfi: incoming.fromCfi,
        ),
      );
    }
    if (_position.isPastPage(incoming.fromEpoch, incoming.fromSeq)) {
      if (incoming.requiredUserIds.contains(_currentUserId)) {
        // Tell the requester it is behind, and where the room is.
        unawaited(
          _sendVoteQuietly(
            incoming,
            accept: false,
            reason: 'out_of_sync',
            position: _position,
          ),
        );
      }
      return;
    }
    // Not asked: this reader joined after the request and follows the commit.
    if (!incoming.requiredUserIds.contains(_currentUserId)) return;
    if (_isInAdBreak()) {
      // Nobody gets the next page while an ad is up — the requester's app may
      // be one that knows nothing of ad breaks. Not remembered as finished:
      // if this answer is lost, the requester's next nudge gets another, and
      // once the break is over it is answered like any other request.
      unawaited(_sendVoteQuietly(incoming, accept: false, reason: 'ad_break'));
      return;
    }

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
    // loses the tie-break should not then have to tap again. Two jumps want
    // the same thing only if they go to the same page.
    final sameIntent =
        current.sameIntentAs(incoming) &&
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
    final position = payload['position'];
    if (position is Map<String, dynamic>) {
      final ahead = SharedPosition.fromWire(position);
      if (ahead != null) _adoptRemotePosition(ahead);
    }
  }

  void _onCommit(Map<String, dynamic> payload) {
    if (_disposed) return;
    final epoch = payload['epoch'] ?? 0;
    final seq = payload['seq'];
    final cfi = payload['cfi'];
    final requestId = payload['request_id'];
    if (epoch is! int ||
        epoch < 0 ||
        seq is! int ||
        seq < 0 ||
        cfi is! String ||
        cfi.isEmpty) {
      return;
    }
    if (requestId is String) _rememberFinished(requestId);

    _adoptRemotePosition(
      SharedPosition(epoch: epoch, seq: seq, cfi: cfi),
      committed: true,
    );
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
    // An empty or partial view during a reconnect is not evidence that anyone
    // left. Pruning on it would let a requester turn alone.
    final selfPresent = _transport.isConnected && _isSelfPresent(users);
    if (selfPresent && !_wasSelfPresent) {
      // Back on the channel: whatever was committed meanwhile is news.
      unawaited(_askForPositions());
    }
    _wasSelfPresent = selfPresent;
    if (!selfPresent) return;
    _observeReaders(users);

    final request = _state.currentRequest;
    if (request == null) return;

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
    // Someone who dropped off the channel is not someone who stepped away:
    // the room waits for them rather than turning without them.
    final dropped = request.requiredUserIds
        .where((id) => _awaySince.containsKey(id))
        .toList();
    if (dropped.isNotEmpty) {
      _finishRequest(
        request,
        error: 'Waiting for ${_joinNames(dropped)} to reconnect',
      );
      unawaited(_broadcastCancelQuietly(request, 'reader_disconnected'));
      return;
    }
    final stillReading = request.requiredUserIds
        .where(
          (id) =>
              id == _currentUserId ||
              (_isReading(id, users) && !_hasDeparted(id)),
        )
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
    _turnTimer = Timer(request.isJump ? _jumpTimeout : _turnTimeout, () {
      abandonTurn(request.requestId);
    });
    handler(
      PageTurnCommand(
        requestId: request.requestId,
        direction: request.direction,
        targetCfi: request.targetCfi,
      ),
    );
  }

  /// Moves to [candidate] if it is newer than what this reader holds.
  ///
  /// Only a [committed] page — the commit of a turn, as it happens — can
  /// start an ad break. A page caught up on afterwards (an announcement, a
  /// request from it, a reconnect) is one the room may have finished its
  /// break on long ago: an ad there would cover the page everyone else is
  /// reading.
  bool _adoptRemotePosition(
    SharedPosition candidate, {
    bool committed = false,
  }) {
    if (!candidate.isNewerThan(_position)) return false;
    _position = candidate;

    final request = _state.currentRequest;
    if (request != null &&
        candidate.isPastPage(request.fromEpoch, request.fromSeq)) {
      final wasTurning =
          request.requestedByUserId == _currentUserId &&
          _state.status == SyncStatus.turning;
      if (request.requestedByUserId == _currentUserId) {
        unawaited(_broadcastCancelQuietly(request, 'superseded'));
      }
      _finishRequest(request);
      if (wasTurning) onTurnAbandoned?.call(request.requestId);
    }

    onPositionChanged?.call(candidate);
    if (committed) _reachedPage(candidate);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Ad breaks

  void _reachedPage(SharedPosition position) {
    if (_disposed || !isAdBreakPage(position, every: _adBreakEvery)) return;
    // The same page again (a tie-break between two commits for it) is not
    // another break.
    if (position.epoch == _adBreakEpoch && position.seq == _adBreakSeq) return;
    _adBreakEpoch = position.epoch;
    _adBreakSeq = position.seq;
    // Reading alone there is nobody to hear from.
    _adBreakSettleUntil = _knownReaders.isEmpty
        ? null
        : _clock().add(_adBreakSettle);
    final showsAd = onAdBreak?.call(position) ?? false;
    if (_disposed) return;
    if (showsAd && !_holdingForAd) {
      _holdingForAd = true;
      _adHoldLimitTimer = Timer(_adBreakLimit, () {
        if (!_holdingForAd) return;
        endAdBreak();
        onAdHoldExpired?.call();
      });
      _adHoldAnnounceTimer = Timer.periodic(_nudgeInterval, (_) {
        unawaited(_announceAdBreak(active: true));
      });
      unawaited(_announceAdBreak(active: true));
    }
    _refreshAdBreak();
  }

  void _stopAdHold() {
    _holdingForAd = false;
    _adHoldLimitTimer?.cancel();
    _adHoldLimitTimer = null;
    _adHoldAnnounceTimer?.cancel();
    _adHoldAnnounceTimer = null;
  }

  Future<void> _announceAdBreak({required bool active}) async {
    if (_disposed) return;
    try {
      await _transport.broadcast(
        event: adBreakEvent,
        payload: {
          'user_id': _currentUserId,
          'nickname': _currentNickname,
          'active': active,
          'epoch': _adBreakEpoch,
          'seq': _adBreakSeq,
        },
      );
    } catch (_) {
      // A hold is announced again every nudge, and expires where it is not;
      // a lost end lets the others go once it expires.
    }
  }

  void _onAdBreak(Map<String, dynamic> payload) {
    final userId = payload['user_id'];
    final active = payload['active'];
    if (_disposed ||
        userId is! String ||
        userId == _currentUserId ||
        active is! bool) {
      return;
    }
    if (active && !_hasDeparted(userId)) {
      final nickname = payload['nickname'];
      _othersInAd[userId] = _AdHold(
        nickname is String && nickname.trim().isNotEmpty
            ? nickname.trim()
            : _knownReaders[userId] ?? 'A reader',
        _clock(),
      );
    } else {
      _othersInAd.remove(userId);
    }
    _refreshAdBreak();
  }

  /// Other readers whose ad is up, by name. A hold that stopped being
  /// announced — its reader dropped off, or the end was lost — has expired.
  List<String> _adNames() {
    final now = _clock();
    _othersInAd.removeWhere(
      (_, hold) => now.difference(hold.lastHeard) >= _followerLiveness,
    );
    return [for (final hold in _othersInAd.values) hold.nickname]..sort();
  }

  bool _isInAdBreak() {
    // Cleared whatever else holds the break: a settle left past its time
    // would stay among the wake-ups of [_refreshAdBreak], already due.
    final settleUntil = _adBreakSettleUntil;
    if (settleUntil != null && !_clock().isBefore(settleUntil)) {
      _adBreakSettleUntil = null;
    }
    return _holdingForAd ||
        _adNames().isNotEmpty ||
        _adBreakSettleUntil != null;
  }

  /// Publishes the ad break as it stands, and wakes up when it next changes
  /// on its own: the settle runs out, or a hold expires.
  void _refreshAdBreak() {
    if (_disposed) return;
    _adBreakTimer?.cancel();
    _adBreakTimer = null;
    final names = _adNames();
    final inBreak = _isInAdBreak();
    final now = _clock();
    final deadlines = [
      if (_adBreakSettleUntil != null) _adBreakSettleUntil!,
      for (final hold in _othersInAd.values)
        hold.lastHeard.add(_followerLiveness),
    ];
    if (deadlines.isNotEmpty) {
      final next = deadlines.reduce((a, b) => a.isBefore(b) ? a : b);
      _adBreakTimer = Timer(
        next.difference(now) + const Duration(milliseconds: 1),
        _refreshAdBreak,
      );
    }
    if (inBreak != _state.adBreak || !_listEquals(names, _state.readersInAd)) {
      _updateState(_state);
    }
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
    SharedPosition? position,
  }) {
    return _transport.broadcast(
      event: voteEvent,
      payload: {
        'request_id': request.requestId,
        'user_id': _currentUserId,
        'accept': accept,
        if (reason != null) 'reason': reason,
        if (position != null) 'position': position.toWire(),
      },
    );
  }

  Future<void> _sendVoteQuietly(
    PageTurnRequest request, {
    required bool accept,
    String? reason,
    SharedPosition? position,
  }) async {
    try {
      await _sendVote(
        request,
        accept: accept,
        reason: reason,
        position: position,
      );
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
          'epoch': position.epoch,
          'seq': position.seq,
          'cfi': position.cfi,
        },
      );
    } catch (_) {
      // Presence carries the same position; the commit is only the fast path.
    }
  }

  Future<void> _askForPositions() async {
    if (_disposed) return;
    try {
      await _transport.broadcast(
        event: positionQueryEvent,
        payload: {'user_id': _currentUserId},
      );
    } catch (_) {
      // Asked again when this reader is back on the channel.
    }
  }

  Future<void> _announcePosition() async {
    if (_disposed) return;
    try {
      await _transport.broadcast(
        event: positionEvent,
        payload: {'user_id': _currentUserId, ..._position.toWire()},
      );
    } catch (_) {
      // The next announcement carries the same position.
    }
  }

  void _onPositionQuery(Map<String, dynamic> payload) {
    if (_disposed || payload['user_id'] == _currentUserId) return;
    // The asker may be from the lobby's past; it is also back, so it is no
    // longer away.
    final userId = payload['user_id'];
    if (userId is String) _departedAt.remove(userId);
    unawaited(_announcePosition());
  }

  void _onPosition(Map<String, dynamic> payload) {
    if (_disposed || payload['user_id'] == _currentUserId) return;
    final position = SharedPosition.fromWire(payload);
    if (position != null) _adoptRemotePosition(position);
  }

  void _onReaderLeft(Map<String, dynamic> payload) {
    final userId = payload['user_id'];
    if (_disposed || userId is! String || userId == _currentUserId) return;
    _markDeparted(userId);
  }

  void _onMembership(Map<String, dynamic> payload) {
    final userId = payload['user_id'];
    if (_disposed ||
        payload['action'] != 'leaving' ||
        userId is! String ||
        userId == _currentUserId) {
      return;
    }
    _markDeparted(userId);
  }

  void _markDeparted(String userId) {
    _departedAt[userId] = _clock();
    _knownReaders.remove(userId);
    if (_awaySince.remove(userId) != null) _refreshAway();
    if (_othersInAd.remove(userId) != null) _refreshAdBreak();
  }

  bool _hasDeparted(String userId) {
    final at = _departedAt[userId];
    if (at == null) return false;
    if (_clock().difference(at) < departureMemory) return true;
    _departedAt.remove(userId);
    return false;
  }

  /// Keeps track of who was reading, to tell a dropped connection (wait for
  /// them) from stepping away (do not).
  void _observeReaders(List<Map<String, dynamic>> users) {
    final now = _clock();
    final present = <String>{};
    for (final user in users) {
      final userId = user['user_id'];
      if (userId is! String || userId == _currentUserId) continue;
      present.add(userId);
      if (user['is_reading'] == true && !_hasDeparted(userId)) {
        final nickname = user['nickname'];
        _knownReaders[userId] = nickname is String && nickname.trim().isNotEmpty
            ? nickname.trim()
            : 'A reader';
      } else {
        // In the lobby, or the app went to the background: stepped away.
        _knownReaders.remove(userId);
        // Not looking at an ad in the room either.
        _othersInAd.remove(userId);
      }
      _awaySince.remove(userId);
    }
    for (final userId in _knownReaders.keys) {
      if (!present.contains(userId) && !_hasDeparted(userId)) {
        _awaySince.putIfAbsent(userId, () => now);
      }
    }
    _refreshAway();
    _refreshAdBreak();
  }

  /// Readers still inside their reconnect grace, oldest first.
  List<String> _readersAway() {
    final now = _clock();
    _awaySince.removeWhere((userId, since) {
      final expired = now.difference(since) >= _reconnectGrace;
      // Gone for good as far as this session is concerned.
      if (expired) _knownReaders.remove(userId);
      return expired;
    });
    return _awaySince.keys.toList();
  }

  void _refreshAway() {
    _awayTimer?.cancel();
    _awayTimer = null;
    final away = _readersAway();
    if (away.isNotEmpty) {
      final now = _clock();
      final next = _awaySince.values
          .map((since) => since.add(_reconnectGrace).difference(now))
          .reduce((a, b) => a < b ? a : b);
      _awayTimer = Timer(next + const Duration(milliseconds: 1), _refreshAway);
    }
    final names = _awayNames();
    if (!_listEquals(names, _state.readersReconnecting)) {
      _updateState(_state);
    }
  }

  List<String> _awayNames() {
    final names = [
      for (final userId in _readersAway()) _knownReaders[userId] ?? 'A reader',
    ]..sort();
    return names;
  }

  String _joinNames(List<String> userIdsOrNames) {
    final names = [
      for (final value in userIdsOrNames) _knownReaders[value] ?? value,
    ]..sort();
    return names.join(', ');
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
            user['reader_ready'] == true &&
            !_hasDeparted(user['user_id'] as String))
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
    final candidatePage = SharedPosition(
      epoch: candidate.fromEpoch,
      seq: candidate.fromSeq,
      cfi: '',
    );
    if (candidatePage.isPastPage(over.fromEpoch, over.fromSeq)) return true;
    final overPage = SharedPosition(
      epoch: over.fromEpoch,
      seq: over.fromSeq,
      cfi: '',
    );
    if (overPage.isPastPage(candidate.fromEpoch, candidate.fromSeq)) {
      return false;
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
    final names = <String>[];
    // A reader whose app speaks another protocol version never answers, and
    // "timed out" alone reads as a bad connection (GH-33).
    final behind = <String>[];
    final ahead = <String>[];
    for (final id in request.pendingUserIds) {
      for (final user in users) {
        if (user['user_id'] != id || user['nickname'] is! String) continue;
        final nickname = (user['nickname'] as String).trim();
        if (nickname.isEmpty) continue;
        names.add(nickname);
        switch (presenceProtocolCompatibility(user)) {
          case ProtocolCompatibility.older:
            behind.add(nickname);
          case ProtocolCompatibility.newer:
            ahead.add(nickname);
          case ProtocolCompatibility.compatible:
            break;
        }
        break;
      }
    }
    if (names.isEmpty) return describeCancelReason('timeout');
    names.sort();
    behind.sort();
    ahead.sort();
    return [
      'Page turn timed out waiting for ${names.join(', ')}',
      if (behind.isNotEmpty)
        '${behind.join(', ')} ${behind.length == 1 ? 'needs' : 'need'} to '
            'update the app to read together',
      if (ahead.isNotEmpty) 'Update the app to read with ${ahead.join(', ')}',
    ].join('. ');
  }

  void _setError(String message) {
    _updateState(PageSyncState.error(message));
  }

  void _updateState(PageSyncState newState) {
    if (_disposed) return;
    newState = newState.withRoomHolds(
      reconnecting: _awayNames(),
      inAd: _adNames(),
      adBreak: _isInAdBreak(),
    );
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
    _awayTimer?.cancel();
    _announceTimer?.cancel();
    _stopAdHold();
    _adBreakTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    onExecuteTurn = null;
    onPositionChanged = null;
    onTurnAbandoned = null;
    onAdBreak = null;
    onAdHoldExpired = null;
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
        'The page did not move — this may be the start or end of the book',
    'jump_failed': 'Could not go to that page — try again',
    'requester_busy': 'Page turn cancelled: the page was still loading',
    'reader_disconnected': 'Page turn paused: a reader is reconnecting',
    'ad_break': 'Page turn paused: the ad break is not over yet',
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

class _AdHold {
  final String nickname;
  final DateTime lastHeard;

  const _AdHold(this.nickname, this.lastHeard);
}
