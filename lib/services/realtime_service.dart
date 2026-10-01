import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_constants.dart';
import 'presence_merge.dart';
import 'supabase_service.dart';

enum RealtimeConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

class RealtimeConnectionEvent {
  final RealtimeConnectionStatus status;
  final Object? error;

  const RealtimeConnectionEvent(this.status, {this.error});
}

/// Small adapter around Supabase's channel so room-session behavior can be
/// tested without opening a websocket.
abstract interface class RoomRealtimeChannel {
  void onPresenceSync(VoidCallback callback);
  void onPresenceJoin(ValueChanged<dynamic> callback);
  void onPresenceLeave(ValueChanged<dynamic> callback);
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback);
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  );
  Future<void> track(Map<String, dynamic> payload);
  Future<void> untrack();
  Future<void> sendBroadcast(String event, Map<String, dynamic> payload);
  List<Map<String, dynamic>> presencePayloads();

  /// Leaves the channel. [releaseSocket] also closes the shared WebSocket
  /// when nothing else uses it; a channel being replaced must keep it.
  Future<void> remove({bool releaseSocket = true});
}

typedef RoomRealtimeChannelFactory =
    RoomRealtimeChannel Function(String channelName, String presenceKey);

class _SupabaseRoomRealtimeChannel implements RoomRealtimeChannel {
  final SupabaseClient _client;
  final RealtimeChannel _channel;

  _SupabaseRoomRealtimeChannel(
    this._client,
    String channelName,
    String presenceKey,
  ) : _channel = _client.channel(
        channelName,
        opts: RealtimeChannelConfig(
          self: true,
          private: true,
          // A user can legitimately have more than one device. Keep the
          // individual connection metas distinct and merge them by user_id
          // at the provider boundary.
          key: '$presenceKey:${DateTime.now().microsecondsSinceEpoch}',
        ),
      );

  @override
  void onPresenceSync(VoidCallback callback) {
    _channel.onPresenceSync((_) => callback());
  }

  @override
  void onPresenceJoin(ValueChanged<dynamic> callback) {
    _channel.onPresenceJoin(callback);
  }

  @override
  void onPresenceLeave(ValueChanged<dynamic> callback) {
    _channel.onPresenceLeave(callback);
  }

  @override
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback) {
    _channel.onBroadcast(event: event, callback: callback);
  }

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) {
    _channel.subscribe((status, [error]) => callback(status, error));
  }

  @override
  Future<void> track(Map<String, dynamic> payload) async {
    await _channel.track(payload);
  }

  @override
  Future<void> untrack() async {
    await _channel.untrack();
  }

  @override
  Future<void> sendBroadcast(String event, Map<String, dynamic> payload) async {
    final response = await _channel.sendBroadcastMessage(
      event: event,
      payload: payload,
    );
    // Not an exception in the library: a failed REST fallback (the socket is
    // down) only shows up here, and callers retry on a throw.
    if (response != ChannelResponse.ok) {
      throw StateError('Broadcast "$event" was not delivered ($response)');
    }
  }

  @override
  List<Map<String, dynamic>> presencePayloads() {
    return [
      for (final state in _channel.presenceState())
        for (final presence in state.presences) presence.payload,
    ];
  }

  @override
  Future<void> remove({bool releaseSocket = true}) async {
    // Not removeChannel(): when this is the last channel it starts a socket
    // disconnect without awaiting it. A channel created right after then
    // finds the socket "disconnecting", skips connecting, and the finished
    // disconnect cancels the reconnect timer — the new channel's join is
    // never sent and it reports "unable to subscribe" forever.
    await _channel.unsubscribe().timeout(
      _leaveTimeout,
      onTimeout: () => 'timed out',
    );
    final realtime = _client.realtime;
    if (releaseSocket && realtime.getChannels().isEmpty) {
      await realtime.disconnect();
    }
  }

  static const _leaveTimeout = Duration(seconds: 3);
}

class RealtimeService {
  static const roomEvents = <String>[
    'page_turn_request',
    'page_turn_vote',
    'page_turn_commit',
    'page_turn_cancel',
    'book_shared',
    'book_chunk',
    'transfer_request',
    'start_reading',
    'membership_changed',
    'room_closed',
  ];

  final RoomRealtimeChannelFactory _channelFactory;
  RoomRealtimeChannel? _channel;
  String? _roomCode;
  String? _roomTopicId;
  String? _userId;
  Map<String, dynamic>? _presencePayload;
  RealtimeConnectionStatus _connectionStatus =
      RealtimeConnectionStatus.disconnected;
  int _generation = 0;
  Future<void> _operationTail = Future<void>.value();
  bool _isClosed = false;
  Future<void>? _closeFuture;

  final Future<void> Function()? _beforeReconnect;
  final Duration _recoveryDelay;
  final Duration _maxRecoveryDelay;
  final Duration _silentSubscribeTimeout;
  Timer? _recoveryTimer;
  int _recoveryAttempts = 0;

  final _presenceController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController =
      StreamController<RealtimeConnectionEvent>.broadcast();
  final _broadcastControllers =
      <String, StreamController<Map<String, dynamic>>>{};

  /// How long a broken channel gets to recover on its own before it is
  /// replaced. Doubles per failed attempt up to [maxRecoveryDelay].
  static const defaultRecoveryDelay = Duration(seconds: 4);
  static const defaultMaxRecoveryDelay = Duration(seconds: 30);

  /// A subscription that has reported nothing at all by now is rebuilt. Longer
  /// than the library's own 10s join timeout, which reports as trouble first.
  static const defaultSilentSubscribeTimeout = Duration(seconds: 15);

  RealtimeService({
    RoomRealtimeChannelFactory? channelFactory,
    Future<void> Function()? beforeReconnect,
    Duration recoveryDelay = defaultRecoveryDelay,
    Duration maxRecoveryDelay = defaultMaxRecoveryDelay,
    Duration silentSubscribeTimeout = defaultSilentSubscribeTimeout,
  }) : _channelFactory =
           channelFactory ??
           ((channelName, presenceKey) => _SupabaseRoomRealtimeChannel(
             SupabaseService.client,
             channelName,
             presenceKey,
           )),
       _beforeReconnect =
           beforeReconnect ??
           (channelFactory == null ? _refreshRealtimeAuth : null),
       _recoveryDelay = recoveryDelay,
       _maxRecoveryDelay = maxRecoveryDelay,
       _silentSubscribeTimeout = silentSubscribeTimeout;

  /// A channel rebuilt with an expired token is refused, so make sure the
  /// socket carries a current one first.
  static Future<void> _refreshRealtimeAuth() async {
    final client = SupabaseService.client;
    final session = client.auth.currentSession;
    if (session != null && session.isExpired) {
      await client.auth.refreshSession();
    }
    final token = client.auth.currentSession?.accessToken;
    if (token != null) await client.realtime.setAuth(token);
  }

  bool get isConnected =>
      _connectionStatus == RealtimeConnectionStatus.connected;
  String? get roomCode => _roomCode;
  int get generation => _generation;

  Stream<Map<String, dynamic>> get presenceStream => _presenceController.stream;
  Stream<RealtimeConnectionEvent> get connectionStream =>
      _connectionController.stream;

  Stream<Map<String, dynamic>> broadcastStream(String event) {
    _ensureOpen();
    _broadcastControllers[event] ??=
        StreamController<Map<String, dynamic>>.broadcast();
    return _broadcastControllers[event]!.stream;
  }

  Future<void> joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? roomTopicId,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
    int? pageEpoch,
    int? pageSeq,
    String? pageCfi,
  }) {
    final normalizedCode = roomCode.trim().toUpperCase();
    final normalizedTopicId = _normalizeTopicId(roomTopicId);
    final payload = _buildPresencePayload(
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex,
      hasBook: hasBook,
      bookHash: bookHash,
      isReading: isReading,
      readerReady: readerReady,
      pageEpoch: pageEpoch,
      pageSeq: pageSeq,
      pageCfi: pageCfi,
    );

    return _serialize(() async {
      _ensureOpen();

      final canReuseCurrentChannel =
          _connectionStatus == RealtimeConnectionStatus.connecting ||
          _connectionStatus == RealtimeConnectionStatus.connected ||
          _connectionStatus == RealtimeConnectionStatus.reconnecting;
      if (_roomCode == normalizedCode &&
          _roomTopicId == normalizedTopicId &&
          _userId == userId &&
          _channel != null &&
          canReuseCurrentChannel) {
        _presencePayload = payload;
        if (isConnected) {
          await _trackCurrentPresence(_channel!, _generation);
        }
        return;
      }

      await _leaveRoomInternal(emitDisconnected: _channel != null);
      _recoveryAttempts = 0;
      _openChannel(
        roomCode: normalizedCode,
        topicId: normalizedTopicId,
        userId: userId,
        payload: payload,
        initialStatus: RealtimeConnectionStatus.connecting,
      );
    });
  }

  /// Creates and subscribes the room channel. Shared by the first join and by
  /// every rebuild after the connection broke.
  void _openChannel({
    required String roomCode,
    required String? topicId,
    required String userId,
    required Map<String, dynamic> payload,
    required RealtimeConnectionStatus initialStatus,
  }) {
    final channelName = AppConstants.roomChannelName(topicId ?? roomCode);
    final generation = ++_generation;
    final channel = _channelFactory(channelName, userId);
    _channel = channel;
    _roomCode = roomCode;
    _roomTopicId = topicId;
    _userId = userId;
    _presencePayload = payload;
    _emitConnection(initialStatus);

    channel.onPresenceSync(() {
      if (!_isCurrent(channel, generation)) return;
      _presenceController.add({
        'event': 'sync',
        'state': mergePresenceUsers(channel.presencePayloads()),
        'generation': generation,
      });
    });

    channel.onPresenceJoin((presenceEvent) {
      if (!_isCurrent(channel, generation)) return;
      _presenceController.add({
        'event': 'join',
        'payload': presenceEvent,
        'generation': generation,
      });
    });

    channel.onPresenceLeave((presenceEvent) {
      if (!_isCurrent(channel, generation)) return;
      _presenceController.add({
        'event': 'leave',
        'payload': presenceEvent,
        'generation': generation,
      });
    });

    for (final event in roomEvents) {
      channel.onBroadcast(event, (payload) {
        if (!_isCurrent(channel, generation)) return;
        _broadcastControllers[event]?.add(payload);
      });
    }

    channel.subscribe((status, error) async {
      if (!_isCurrent(channel, generation)) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        try {
          await _trackCurrentPresence(channel, generation);
          if (_isCurrent(channel, generation)) {
            _recoveryTimer?.cancel();
            _recoveryTimer = null;
            _recoveryAttempts = 0;
            _emitConnection(RealtimeConnectionStatus.connected);
            debugPrint('Joined room channel: $channelName');
          }
        } catch (trackError) {
          if (_isCurrent(channel, generation)) {
            _channelInTrouble(generation, trackError);
          }
        }
        return;
      }
      // Our own leave bumps the generation before it unsubscribes, so a
      // close that reaches here came from the server or the library — e.g.
      // a rejoin that unsubscribed its own channel. The library never
      // rejoins a closed channel; only a rebuild brings it back.
      if (status == RealtimeSubscribeStatus.closed ||
          status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        _channelInTrouble(generation, error ?? status.name);
      }
    });

    // A subscription that never answers at all is trouble too.
    _scheduleRecovery(generation, delay: _silentSubscribeTimeout);
  }

  /// The channel stopped working. The library retries an errored channel on
  /// its own, so give it a moment; if it is still down then, rebuild it.
  void _channelInTrouble(int generation, Object? reason) {
    debugPrint('Room channel trouble: $reason');
    _emitConnection(RealtimeConnectionStatus.reconnecting);
    _scheduleRecovery(generation);
  }

  void _scheduleRecovery(int generation, {Duration? delay}) {
    if (_isClosed || _channel == null || generation != _generation) return;
    _recoveryTimer?.cancel();
    var backoff =
        delay ?? _recoveryDelay * (1 << _recoveryAttempts.clamp(0, 4));
    if (backoff > _maxRecoveryDelay) backoff = _maxRecoveryDelay;
    _recoveryTimer = Timer(backoff, () {
      _recoveryTimer = null;
      unawaited(_recover(generation));
    });
  }

  Future<void> _recover(int generation) {
    return _serialize(() async {
      final roomCode = _roomCode;
      final userId = _userId;
      final payload = _presencePayload;
      if (_isClosed ||
          _channel == null ||
          generation != _generation ||
          isConnected ||
          roomCode == null ||
          userId == null ||
          payload == null) {
        return;
      }
      final topicId = _roomTopicId;
      _recoveryAttempts++;
      debugPrint('Rebuilding room channel (attempt $_recoveryAttempts)');
      try {
        await _beforeReconnect?.call();
      } catch (error) {
        debugPrint('Refreshing realtime auth failed: $error');
      }
      try {
        // Untracking a dead channel only waits out a timeout; leaving the
        // channel removes its presence on the server anyway.
        await _leaveRoomInternal(
          emitDisconnected: false,
          untrack: false,
          releaseSocket: false,
        );
      } catch (error) {
        debugPrint('Dropping the broken room channel failed: $error');
      }
      if (_isClosed) return;
      _openChannel(
        roomCode: roomCode,
        topicId: topicId,
        userId: userId,
        payload: payload,
        initialStatus: RealtimeConnectionStatus.reconnecting,
      );
    });
  }

  /// Asks for a health check soon, e.g. when the app comes back to the
  /// foreground: the socket may have been closed while it was asleep.
  void checkConnection({Duration delay = const Duration(seconds: 2)}) {
    if (_channel == null || isConnected) return;
    _scheduleRecovery(_generation, delay: delay);
  }

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    final channel = _channel;
    if (channel == null || !isConnected) {
      throw StateError('Not connected to a room channel');
    }
    await channel.sendBroadcast(event, payload);
  }

  Future<void> updatePresence({
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
    int? pageEpoch,
    int? pageSeq,
    String? pageCfi,
  }) {
    final payload = _buildPresencePayload(
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex,
      hasBook: hasBook,
      bookHash: bookHash,
      isReading: isReading,
      readerReady: readerReady,
      pageEpoch: pageEpoch,
      pageSeq: pageSeq,
      pageCfi: pageCfi,
    );

    return _serialize(() async {
      _ensureOpen();
      _presencePayload = payload;
      final channel = _channel;
      if (channel != null && isConnected) {
        await _trackCurrentPresence(channel, _generation);
      }
    });
  }

  /// One row per logical user.
  ///
  /// Presence is keyed per connection, so a user with a second device — or one
  /// whose previous meta has not expired after a reconnect — appears more than
  /// once in the raw payloads. Merging here keeps the page-turn quorum and the
  /// lobby roster from disagreeing about who is online and ready.
  List<Map<String, dynamic>> getOnlineUsers() {
    final channel = _channel;
    if (channel == null) return const [];
    return mergePresenceUsers(channel.presencePayloads());
  }

  Future<void> leaveRoom() {
    return _serialize(() => _leaveRoomInternal(emitDisconnected: true));
  }

  Future<void> close() {
    return _closeFuture ??= _closeInternal();
  }

  Future<void> _closeInternal() async {
    // Fail new room operations immediately while the serialized leave waits
    // for work already queued ahead of it.
    _isClosed = true;
    try {
      await leaveRoom();
    } catch (error) {
      debugPrint('Realtime cleanup failed while closing: $error');
    }
    await _presenceController.close();
    await _connectionController.close();
    for (final controller in _broadcastControllers.values) {
      await controller.close();
    }
    _broadcastControllers.clear();
  }

  void dispose() {
    unawaited(close());
  }

  Future<void> _leaveRoomInternal({
    required bool emitDisconnected,
    bool untrack = true,
    bool releaseSocket = true,
  }) async {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    final channel = _channel;
    if (channel == null) {
      _roomCode = null;
      _roomTopicId = null;
      _userId = null;
      _presencePayload = null;
      if (emitDisconnected) {
        _emitConnection(RealtimeConnectionStatus.disconnected);
      }
      return;
    }

    ++_generation; // Invalidate callbacks before awaiting any network work.
    _channel = null;
    _roomCode = null;
    _roomTopicId = null;
    _userId = null;
    _presencePayload = null;

    Object? untrackError;
    if (untrack) {
      try {
        await channel.untrack();
      } catch (error) {
        untrackError = error;
      }
    }

    Object? removeError;
    try {
      await channel.remove(releaseSocket: releaseSocket);
    } catch (error) {
      removeError = error;
    } finally {
      if (emitDisconnected) {
        _emitConnection(RealtimeConnectionStatus.disconnected);
      }
    }

    if (removeError != null) throw removeError;
    if (untrackError != null) throw untrackError;
  }

  Future<void> _trackCurrentPresence(
    RoomRealtimeChannel channel,
    int generation,
  ) async {
    final payload = _presencePayload;
    if (payload == null || !_isCurrent(channel, generation)) return;
    await channel.track({
      ...payload,
      'online_at': DateTime.now().toIso8601String(),
    });
  }

  bool _isCurrent(RoomRealtimeChannel channel, int generation) {
    return !_isClosed &&
        identical(channel, _channel) &&
        generation == _generation;
  }

  Map<String, dynamic> _buildPresencePayload({
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    required String? bookHash,
    required bool isReading,
    required bool readerReady,
    required int? pageEpoch,
    required int? pageSeq,
    required String? pageCfi,
  }) {
    return {
      'user_id': userId,
      'nickname': nickname,
      'avatar_color': avatarColorIndex,
      'has_book': hasBook,
      'book_hash': hasBook ? bookHash : null,
      'is_reading': isReading,
      'reader_ready': readerReady,
      // Only a reader holds a shared position; see PageSyncService.
      if (isReading && pageSeq != null && pageCfi != null) ...{
        'page_epoch': pageEpoch ?? 0,
        'page_seq': pageSeq,
        'page_cfi': pageCfi,
      },
    };
  }

  String? _normalizeTopicId(String? roomTopicId) {
    final normalized = roomTopicId?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _emitConnection(RealtimeConnectionStatus status, {Object? error}) {
    _connectionStatus = status;
    if (!_connectionController.isClosed) {
      _connectionController.add(RealtimeConnectionEvent(status, error: error));
    }
  }

  void _ensureOpen() {
    if (_isClosed) throw StateError('RealtimeService is closed');
  }
}
