enum TransferStatus {
  idle,

  /// This device needs the room's book and has not received any of it yet.
  waiting,

  /// Chunks are moving (in either direction; see [TransferState.isSending]).
  transferring,

  completed,
}

class TransferState {
  final TransferStatus status;
  final String? bookHash;
  final int totalBytes;
  final int transferredBytes;
  final int totalChunks;
  final int receivedChunks;

  /// What the transfer is doing right now, in words ("Asking Alice for the
  /// book..."). Never a terminal error: every receive keeps retrying.
  final String? message;
  final bool isSending;

  const TransferState({
    this.status = TransferStatus.idle,
    this.bookHash,
    this.totalBytes = 0,
    this.transferredBytes = 0,
    this.totalChunks = 0,
    this.receivedChunks = 0,
    this.message,
    this.isSending = false,
  });

  const TransferState.idle()
    : status = TransferStatus.idle,
      bookHash = null,
      totalBytes = 0,
      transferredBytes = 0,
      totalChunks = 0,
      receivedChunks = 0,
      message = null,
      isSending = false;

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0;

  bool get isActive =>
      status == TransferStatus.waiting || status == TransferStatus.transferring;

  bool get isReceiving => isActive && !isSending;

  TransferState copyWith({
    TransferStatus? status,
    String? bookHash,
    int? totalBytes,
    int? transferredBytes,
    int? totalChunks,
    int? receivedChunks,
    String? message,
    bool clearMessage = false,
    bool? isSending,
  }) {
    return TransferState(
      status: status ?? this.status,
      bookHash: bookHash ?? this.bookHash,
      totalBytes: totalBytes ?? this.totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalChunks: totalChunks ?? this.totalChunks,
      receivedChunks: receivedChunks ?? this.receivedChunks,
      message: clearMessage ? null : message ?? this.message,
      isSending: isSending ?? this.isSending,
    );
  }
}
