enum TransferStatus { idle, offering, accepting, transferring, completed, failed }

class TransferState {
  final TransferStatus status;
  final String? bookHash;
  final int totalBytes;
  final int transferredBytes;
  final int totalChunks;
  final int receivedChunks;
  final String? errorMessage;
  final bool isSending;

  const TransferState({
    this.status = TransferStatus.idle,
    this.bookHash,
    this.totalBytes = 0,
    this.transferredBytes = 0,
    this.totalChunks = 0,
    this.receivedChunks = 0,
    this.errorMessage,
    this.isSending = false,
  });

  const TransferState.idle()
      : status = TransferStatus.idle,
        bookHash = null,
        totalBytes = 0,
        transferredBytes = 0,
        totalChunks = 0,
        receivedChunks = 0,
        errorMessage = null,
        isSending = false;

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0;

  bool get isActive =>
      status == TransferStatus.transferring ||
      status == TransferStatus.offering ||
      status == TransferStatus.accepting;

  TransferState copyWith({
    TransferStatus? status,
    String? bookHash,
    int? totalBytes,
    int? transferredBytes,
    int? totalChunks,
    int? receivedChunks,
    String? errorMessage,
    bool? isSending,
  }) {
    return TransferState(
      status: status ?? this.status,
      bookHash: bookHash ?? this.bookHash,
      totalBytes: totalBytes ?? this.totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalChunks: totalChunks ?? this.totalChunks,
      receivedChunks: receivedChunks ?? this.receivedChunks,
      errorMessage: errorMessage ?? this.errorMessage,
      isSending: isSending ?? this.isSending,
    );
  }
}
