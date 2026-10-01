enum PageTurnDirection { next, previous }

String pageTurnDirectionToWire(PageTurnDirection direction) {
  return direction == PageTurnDirection.next ? 'next' : 'previous';
}

PageTurnDirection? pageTurnDirectionFromWire(Object? value) {
  return switch (value) {
    'next' => PageTurnDirection.next,
    'previous' => PageTurnDirection.previous,
    _ => null,
  };
}

/// The page the whole room is on.
///
/// Readers agree on ([epoch], [seq]); [cfi] is only where to display it. A CFI
/// is computed from the local pagination — screen size, font size, a resize —
/// so two readers on the same page routinely hold different strings for it.
/// The previous protocol compared those strings for equality and therefore
/// rejected nearly every turn between two different devices.
///
/// [seq] counts commits, but only within one stretch of reading: a reader who
/// opens the book when nobody else is reading starts again from the database
/// at seq 0. [epoch] tells those stretches apart. It is minted (a wall-clock
/// timestamp) by the first commit of a stretch that started at epoch 0, so a
/// reader coming back from sleep with a high seq from an *older* stretch can
/// never drag the room back to its stale page.
class SharedPosition {
  final int epoch;
  final int seq;

  /// Empty means "the start of the book": a room that has never turned a page
  /// has no CFI yet.
  final String cfi;

  const SharedPosition({this.epoch = 0, required this.seq, required this.cfi});

  const SharedPosition.start() : epoch = 0, seq = 0, cfi = '';

  /// Total order used to converge. Two commits for the same (epoch, seq) can
  /// only come from a race between overlapping quorums; picking the larger CFI
  /// is arbitrary, but every client picks the same one.
  bool isNewerThan(SharedPosition other) {
    if (epoch != other.epoch) return epoch > other.epoch;
    if (seq != other.seq) return seq > other.seq;
    return cfi.compareTo(other.cfi) > 0;
  }

  /// Whether this page comes after the page ([fromEpoch], [fromSeq]) a request
  /// was made from — i.e. the request is stale.
  bool isPastPage(int fromEpoch, int fromSeq) {
    if (epoch != fromEpoch) return epoch > fromEpoch;
    return seq > fromSeq;
  }

  /// The page one commit after ([fromEpoch], [fromSeq]).
  static SharedPosition committed({
    required int fromEpoch,
    required int fromSeq,
    required String cfi,
    required int Function() mintEpoch,
  }) {
    return SharedPosition(
      epoch: fromEpoch == 0 ? mintEpoch() : fromEpoch,
      seq: fromSeq + 1,
      cfi: cfi,
    );
  }

  /// Reads a position from a broadcast payload (`epoch`, `seq`, `cfi`).
  static SharedPosition? fromWire(Map<String, dynamic> payload) {
    final epoch = payload['epoch'] ?? 0;
    final seq = payload['seq'];
    final cfi = payload['cfi'];
    if (epoch is! int ||
        epoch < 0 ||
        seq is! int ||
        seq < 0 ||
        cfi is! String) {
      return null;
    }
    return SharedPosition(epoch: epoch, seq: seq, cfi: cfi);
  }

  Map<String, dynamic> toWire() => {'epoch': epoch, 'seq': seq, 'cfi': cfi};

  @override
  bool operator ==(Object other) =>
      other is SharedPosition &&
      other.epoch == epoch &&
      other.seq == seq &&
      other.cfi == cfi;

  @override
  int get hashCode => Object.hash(epoch, seq, cfi);

  @override
  String toString() => 'SharedPosition($epoch:$seq, $cfi)';
}

enum SyncStatus {
  /// Nothing in flight.
  idle,

  /// This reader asked to turn and is collecting answers.
  requesting,

  /// Someone else asked; this reader has not answered yet.
  confirming,

  /// This reader agreed and is waiting for the rest.
  waiting,

  /// Everyone agreed; the requester is moving its page.
  turning,
}

class PageTurnRequest {
  final String requestId;
  final String requestedByUserId;
  final String requestedByNickname;
  final PageTurnDirection direction;

  /// The shared page the turn starts from. A request from an older page is
  /// stale by definition.
  final int fromEpoch;
  final int fromSeq;

  /// Where the requester's page is, so a follower that missed a commit can go
  /// there before answering. Display only, like every CFI.
  final String fromCfi;
  final DateTime requestedAt;
  final Set<String> confirmedUserIds;
  final Set<String> requiredUserIds;

  const PageTurnRequest({
    required this.requestId,
    required this.requestedByUserId,
    required this.requestedByNickname,
    required this.direction,
    this.fromEpoch = 0,
    required this.fromSeq,
    this.fromCfi = '',
    required this.requestedAt,
    required this.confirmedUserIds,
    required this.requiredUserIds,
  });

  bool get isConsensusReached =>
      requiredUserIds.isNotEmpty &&
      requiredUserIds.every(confirmedUserIds.contains);

  Set<String> get pendingUserIds =>
      requiredUserIds.difference(confirmedUserIds);

  int get validConfirmationCount =>
      confirmedUserIds.intersection(requiredUserIds).length;

  double get progress => requiredUserIds.isEmpty
      ? 0
      : validConfirmationCount / requiredUserIds.length;

  /// Concurrent requests are resolved by id, not arrival order, so every
  /// client that sees both picks the same one.
  bool winsOver(PageTurnRequest other) =>
      requestId.compareTo(other.requestId) < 0;

  PageTurnRequest copyWith({
    Set<String>? confirmedUserIds,
    Set<String>? requiredUserIds,
  }) {
    return PageTurnRequest(
      requestId: requestId,
      requestedByUserId: requestedByUserId,
      requestedByNickname: requestedByNickname,
      direction: direction,
      fromEpoch: fromEpoch,
      fromSeq: fromSeq,
      fromCfi: fromCfi,
      requestedAt: requestedAt,
      confirmedUserIds: confirmedUserIds ?? this.confirmedUserIds,
      requiredUserIds: requiredUserIds ?? this.requiredUserIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'request_id': requestId,
      'user_id': requestedByUserId,
      'nickname': requestedByNickname,
      'direction': pageTurnDirectionToWire(direction),
      'from_epoch': fromEpoch,
      'from_seq': fromSeq,
      'from_cfi': fromCfi,
      'requested_at': requestedAt.toUtc().toIso8601String(),
      'required_users': requiredUserIds.toList()..sort(),
    };
  }

  factory PageTurnRequest.fromJson(Map<String, dynamic> json) {
    final direction = pageTurnDirectionFromWire(json['direction']);
    if (direction == null) {
      throw const FormatException('Invalid page turn direction');
    }

    final requestId = json['request_id'];
    final requestedByUserId = json['user_id'];
    final fromEpoch = json['from_epoch'];
    final fromSeq = json['from_seq'];
    final rawRequestedAt = json['requested_at'];
    final requestedAt = rawRequestedAt is String
        ? DateTime.tryParse(rawRequestedAt)
        : null;
    if (requestId is! String ||
        requestId.isEmpty ||
        requestedByUserId is! String ||
        requestedByUserId.isEmpty ||
        fromEpoch is! int ||
        fromEpoch < 0 ||
        fromSeq is! int ||
        fromSeq < 0 ||
        requestedAt == null) {
      throw const FormatException('Invalid page turn request');
    }

    final rawRequiredUsers = json['required_users'];
    if (rawRequiredUsers is! List) {
      throw const FormatException('Invalid required users');
    }

    final requiredUserIds = rawRequiredUsers.whereType<String>().toSet();
    if (requiredUserIds.length != rawRequiredUsers.length ||
        !requiredUserIds.contains(requestedByUserId)) {
      throw const FormatException('Invalid required users');
    }

    return PageTurnRequest(
      requestId: requestId,
      requestedByUserId: requestedByUserId,
      requestedByNickname: json['nickname'] is String
          ? json['nickname'] as String
          : 'Unknown',
      direction: direction,
      fromEpoch: fromEpoch,
      fromSeq: fromSeq,
      fromCfi: json['from_cfi'] is String ? json['from_cfi'] as String : '',
      requestedAt: requestedAt,
      confirmedUserIds: {requestedByUserId},
      requiredUserIds: requiredUserIds,
    );
  }
}

/// Handed to the requester's reader once everyone agreed: move the viewer one
/// page and report where it landed through `completeTurn`.
class PageTurnCommand {
  final String requestId;
  final PageTurnDirection direction;

  const PageTurnCommand({required this.requestId, required this.direction});
}

class PageSyncState {
  final SyncStatus status;
  final PageTurnRequest? currentRequest;
  final String? errorMessage;

  /// Readers who dropped off mid-book and are within their reconnect grace.
  /// Nobody can turn while this is not empty.
  final List<String> readersReconnecting;

  const PageSyncState({
    this.status = SyncStatus.idle,
    this.currentRequest,
    this.errorMessage,
    this.readersReconnecting = const [],
  });

  const PageSyncState.idle()
    : status = SyncStatus.idle,
      currentRequest = null,
      errorMessage = null,
      readersReconnecting = const [];

  const PageSyncState.error(String message)
    : status = SyncStatus.idle,
      currentRequest = null,
      errorMessage = message,
      readersReconnecting = const [];

  PageSyncState withReadersReconnecting(List<String> names) {
    return PageSyncState(
      status: status,
      currentRequest: currentRequest,
      errorMessage: errorMessage,
      readersReconnecting: List.unmodifiable(names),
    );
  }

  int get validConfirmationCount => currentRequest?.validConfirmationCount ?? 0;

  PageSyncState copyWith({
    SyncStatus? status,
    PageTurnRequest? currentRequest,
    String? errorMessage,
    bool clearCurrentRequest = false,
    bool clearError = false,
  }) {
    return PageSyncState(
      status: status ?? this.status,
      currentRequest: clearCurrentRequest
          ? null
          : currentRequest ?? this.currentRequest,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      readersReconnecting: readersReconnecting,
    );
  }
}
