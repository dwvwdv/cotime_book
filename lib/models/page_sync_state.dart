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
/// [seq] is what readers agree on; [cfi] is only where to display it. A CFI is
/// computed from the local pagination — screen size, font size, a resize — so
/// two readers on the same page routinely hold different strings for it. The
/// previous protocol compared those strings for equality and therefore
/// rejected nearly every turn between two different devices. A counter that
/// only ever moves when a turn commits means the same thing everywhere.
class SharedPosition {
  final int seq;

  /// Empty means "the start of the book": a room that has never turned a page
  /// has no CFI yet.
  final String cfi;

  const SharedPosition({required this.seq, required this.cfi});

  const SharedPosition.start() : seq = 0, cfi = '';

  /// Total order used to converge. Two commits for the same seq can only come
  /// from a race between overlapping quorums; picking the larger CFI is
  /// arbitrary, but every client picks the same one.
  bool isNewerThan(SharedPosition other) {
    if (seq != other.seq) return seq > other.seq;
    return cfi.compareTo(other.cfi) > 0;
  }

  SharedPosition advancedTo(String targetCfi) =>
      SharedPosition(seq: seq + 1, cfi: targetCfi);

  /// Reads the position a reader advertises in its Presence meta.
  static SharedPosition? fromPresence(Map<String, dynamic> user) {
    final seq = user['page_seq'];
    final cfi = user['page_cfi'];
    if (seq is! int || seq < 0 || cfi is! String) return null;
    return SharedPosition(seq: seq, cfi: cfi);
  }

  @override
  bool operator ==(Object other) =>
      other is SharedPosition && other.seq == seq && other.cfi == cfi;

  @override
  int get hashCode => Object.hash(seq, cfi);

  @override
  String toString() => 'SharedPosition($seq, $cfi)';
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
  final int fromSeq;
  final DateTime requestedAt;
  final Set<String> confirmedUserIds;
  final Set<String> requiredUserIds;

  const PageTurnRequest({
    required this.requestId,
    required this.requestedByUserId,
    required this.requestedByNickname,
    required this.direction,
    required this.fromSeq,
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
      fromSeq: fromSeq,
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
      'from_seq': fromSeq,
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
    final fromSeq = json['from_seq'];
    final rawRequestedAt = json['requested_at'];
    final requestedAt = rawRequestedAt is String
        ? DateTime.tryParse(rawRequestedAt)
        : null;
    if (requestId is! String ||
        requestId.isEmpty ||
        requestedByUserId is! String ||
        requestedByUserId.isEmpty ||
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
      fromSeq: fromSeq,
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

  const PageSyncState({
    this.status = SyncStatus.idle,
    this.currentRequest,
    this.errorMessage,
  });

  const PageSyncState.idle()
    : status = SyncStatus.idle,
      currentRequest = null,
      errorMessage = null;

  const PageSyncState.error(String message)
    : status = SyncStatus.idle,
      currentRequest = null,
      errorMessage = message;

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
    );
  }
}
