import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../config/app_constants.dart';
import '../models/transfer_state.dart';
import 'presence_merge.dart';
import 'realtime_service.dart';

/// The Realtime surface the transfer needs. Injectable for tests.
abstract interface class BookTransferTransport {
  Stream<Map<String, dynamic>> broadcastStream(String event);

  Stream<Map<String, dynamic>> get presenceStream;

  List<Map<String, dynamic>> getOnlineUsers();

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  });
}

class RealtimeBookTransferTransport implements BookTransferTransport {
  final RealtimeService _realtimeService;

  const RealtimeBookTransferTransport(this._realtimeService);

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
  }) => _realtimeService.broadcast(event: event, payload: payload);
}

/// Where received books are kept, and where a holder reads one to serve it.
abstract interface class BookBytesStore {
  Future<void> saveBook(String hash, Uint8List bytes);

  Future<Uint8List?> readBook(String hash);
}

/// Fetches the room's book from outside the room (the public library).
typedef BookDownload = Future<Uint8List> Function();

/// Moves the room's EPUB between devices over Realtime broadcast.
///
/// Broadcast is fire-and-forget: packets are dropped under rate limits, and
/// anyone who is not subscribed at that moment never sees them. The previous
/// design pushed the file once and hoped. One lost chunk, a member who joined
/// after the share, or a phone that slept through it, and the receiver sat on
/// "Receiving book..." forever with the Share button disabled.
///
/// Here the **receiver drives**:
///
/// * Anyone who holds the book (its hash is in their Presence) can serve it.
/// * A receiver that is missing chunks asks one holder for exactly those
///   chunks, and asks again — rotating holders — whenever progress stalls.
///   Nothing is terminal: a stalled, damaged or abandoned transfer simply
///   becomes the next request.
/// * A holder serves requests from one send queue, so several receivers asking
///   at once share the same broadcast instead of multiplying it.
/// * The initial share is still pushed to everyone; it is just the fast path.
/// * A library book is downloaded straight from Storage instead. The room is
///   only the fallback: if the download fails or takes too long, the receive
///   carries on as above.
class FileTransferService {
  static const chunkEvent = 'book_chunk';
  static const requestEvent = 'transfer_request';

  static const defaultFirstRequestDelay = Duration(seconds: 2);
  static const defaultStallTimeout = Duration(seconds: 6);

  /// How long a library download runs alone before the room is asked too.
  /// The download keeps going after this; whichever finishes first wins.
  static const defaultDirectDownloadGrace = Duration(seconds: 60);

  final BookTransferTransport _transport;
  final BookBytesStore _store;
  final String _currentUserId;
  final Duration _chunkDelay;
  final Duration _firstRequestDelay;
  final Duration _stallTimeout;
  final Duration _directDownloadGrace;

  final _stateController = StreamController<TransferState>.broadcast();
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  TransferState _state = const TransferState.idle();
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  // Receiving -----------------------------------------------------------------
  String? _wantedHash;
  final Map<int, Uint8List> _receivedChunks = {};
  int _expectedTotalChunks = 0;
  int _expectedTotalBytes = 0;
  int _receivedBytes = 0;
  int _requestAttempt = 0;
  bool _assembling = false;
  bool _waitingForHolder = false;
  bool _downloading = false;
  Timer? _repairTimer;

  /// Bumped whenever the wanted book changes, so an assembly or a timer from
  /// the previous one cannot land on the new one.
  int _receiveGeneration = 0;

  // Holding -------------------------------------------------------------------
  String? _heldHash;
  Uint8List? _heldBytes;
  final _sendQueue = <int>{};
  int _sendTotalChunks = 0;
  int _sentInBatch = 0;
  int _batchSize = 0;

  /// Cleared in the same synchronous step that sees the queue empty, so an
  /// enqueue can never land between "loop finished" and "loop marked idle".
  bool _sending = false;
  Completer<void>? _sendDone;

  FileTransferService({
    required BookTransferTransport transport,
    required BookBytesStore store,
    required String currentUserId,
    Duration chunkDelay = AppConstants.chunkDelay,
    Duration firstRequestDelay = defaultFirstRequestDelay,
    Duration stallTimeout = defaultStallTimeout,
    Duration directDownloadGrace = defaultDirectDownloadGrace,
  }) : _transport = transport,
       _store = store,
       _currentUserId = currentUserId,
       _chunkDelay = chunkDelay,
       _firstRequestDelay = firstRequestDelay,
       _stallTimeout = stallTimeout,
       _directDownloadGrace = directDownloadGrace;

  Stream<TransferState> get stateStream => _stateController.stream;
  TransferState get currentState => _state;
  int get subscriptionCount => _subscriptions.length;
  String? get wantedBookHash => _wantedHash;
  String? get heldBookHash => _heldHash;

  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;
    _subscriptions.addAll([
      _transport.broadcastStream(chunkEvent).listen(_onChunk),
      _transport.broadcastStream(requestEvent).listen(_onTransferRequest),
      _transport.presenceStream.listen(_onPresence),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Public API

  /// This device has [bookHash] and can serve it. [bytes] saves a disk read
  /// when the caller already has them.
  void holdBook(String bookHash, {Uint8List? bytes}) {
    if (_disposed) return;
    final hash = _normalizeHash(bookHash);
    if (_heldHash != hash) {
      _heldHash = hash;
      _heldBytes = null;
      _sendQueue.clear();
      _sentInBatch = 0;
      _batchSize = 0;
    }
    if (bytes != null) _heldBytes = bytes;
    // Holding a book means it is the room's book now. A receive of anything
    // else must stop here: left running, it would finish later and replace
    // the book this device just shared.
    if (_wantedHash != null) {
      _stopReceiving();
      if (!_state.isSending) _updateState(const TransferState.idle());
    }
  }

  /// Shares a book this device just added: hold it and push it to the room.
  /// Completes when the push has been handed to Realtime; receivers that miss
  /// part of it ask for the rest.
  Future<void> shareBook({
    required Uint8List fileBytes,
    required String bookHash,
  }) async {
    if (_disposed) throw StateError('FileTransferService is disposed');
    if (fileBytes.isEmpty) throw ArgumentError('Book file is empty');
    if (fileBytes.length > AppConstants.maxFileSize) {
      throw ArgumentError(
        'Book exceeds the ${AppConstants.maxFileSize} byte limit',
      );
    }
    final hash = _normalizeHash(bookHash);
    if (sha256.convert(fileBytes).toString() != hash) {
      throw ArgumentError('Book hash does not match file contents');
    }

    holdBook(hash, bytes: fileBytes);
    _enqueue(List.generate(_chunkCount(fileBytes.length), (index) => index));
    await _sendDone?.future;
  }

  /// The room's book is [bookHash] and this device does not have it.
  ///
  /// [download] fetches it without the room (a library book). The room is
  /// asked only when that fails or runs past [defaultDirectDownloadGrace].
  void expectBook(String bookHash, {BookDownload? download}) {
    if (_disposed) return;
    final hash = _normalizeHash(bookHash);
    if (_heldHash == hash) return;
    if (_wantedHash == hash) {
      // Lobby entry can expect the book before the share broadcast says where
      // to download it from.
      if (download != null && !_downloading && !_assembling) {
        _startDirectDownload(hash, download);
      }
      return;
    }

    _stopReceiving();
    _wantedHash = hash;
    if (download != null) {
      _startDirectDownload(hash, download);
      return;
    }
    _updateState(
      TransferState(
        status: TransferStatus.waiting,
        bookHash: hash,
        message: 'Waiting for the book...',
      ),
    );
    // Give the sharer's push a moment before asking for anything.
    _scheduleRepair(_firstRequestDelay);
  }

  /// Leaves the room: forget everything.
  void reset() {
    _stopReceiving();
    _heldHash = null;
    _heldBytes = null;
    _sendQueue.clear();
    _updateState(const TransferState.idle());
  }

  // ---------------------------------------------------------------------------
  // Receiving

  void _onChunk(Map<String, dynamic> payload) {
    final wanted = _wantedHash;
    if (_disposed || wanted == null || _assembling) return;

    final senderId = payload['sender_id'];
    final bookHash = payload['book_hash'];
    final chunkIndex = payload['chunk_index'];
    final totalChunks = payload['total_chunks'];
    final totalBytes = payload['total_bytes'];
    final encodedData = payload['data'];
    if (senderId is! String ||
        senderId == _currentUserId ||
        bookHash is! String ||
        bookHash.toLowerCase() != wanted ||
        chunkIndex is! int ||
        totalChunks is! int ||
        totalBytes is! int ||
        encodedData is! String) {
      return;
    }
    if (totalBytes <= 0 ||
        totalBytes > AppConstants.maxFileSize ||
        totalChunks != _chunkCount(totalBytes) ||
        chunkIndex < 0 ||
        chunkIndex >= totalChunks) {
      return;
    }
    const maxEncodedChunkLength = ((AppConstants.fileChunkSize + 2) ~/ 3) * 4;
    if (encodedData.length > maxEncodedChunkLength) return;
    // Every holder slices the same file the same way. A chunk that disagrees
    // about the shape cannot belong to this book; the hash check at the end
    // catches anything subtler.
    if (_expectedTotalChunks != 0 &&
        (_expectedTotalChunks != totalChunks ||
            _expectedTotalBytes != totalBytes)) {
      return;
    }
    if (_receivedChunks.containsKey(chunkIndex)) return;

    final Uint8List chunkBytes;
    try {
      chunkBytes = base64Decode(encodedData);
    } on FormatException {
      return;
    }
    final expectedLength = chunkIndex == totalChunks - 1
        ? totalBytes - chunkIndex * AppConstants.fileChunkSize
        : AppConstants.fileChunkSize;
    if (chunkBytes.length != expectedLength) return;

    _expectedTotalChunks = totalChunks;
    _expectedTotalBytes = totalBytes;
    _receivedChunks[chunkIndex] = chunkBytes;
    _receivedBytes += chunkBytes.length;
    _waitingForHolder = false;
    _updateState(
      TransferState(
        status: TransferStatus.transferring,
        bookHash: wanted,
        totalBytes: totalBytes,
        transferredBytes: _receivedBytes,
        totalChunks: totalChunks,
        receivedChunks: _receivedChunks.length,
      ),
    );

    if (_receivedChunks.length == _expectedTotalChunks) {
      _repairTimer?.cancel();
      _assembling = true;
      unawaited(_assembleAndSave(wanted, _receiveGeneration));
      return;
    }
    // Progress pushes the next repair back; only a real stall asks again.
    _scheduleRepair(_stallTimeout);
  }

  Future<void> _assembleAndSave(String hash, int generation) async {
    try {
      final builder = BytesBuilder(copy: false);
      for (var index = 0; index < _expectedTotalChunks; index++) {
        builder.add(_receivedChunks[index]!);
      }
      final bytes = builder.takeBytes();
      if (bytes.length != _expectedTotalBytes ||
          sha256.convert(bytes).toString() != hash) {
        throw const FormatException('The book arrived damaged');
      }
      await _store.saveBook(hash, bytes);
      if (_disposed || generation != _receiveGeneration) return;
      _completeReceive(hash, bytes);
    } catch (error) {
      if (_disposed || generation != _receiveGeneration) return;
      debugPrint('Book assembly failed, asking again: $error');
      // Start over from nothing rather than stopping: a corrupt chunk cannot
      // be identified, but a clean copy can always be asked for.
      _assembling = false;
      _clearChunks();
      _updateState(
        TransferState(
          status: TransferStatus.waiting,
          bookHash: hash,
          message: 'The book arrived damaged. Asking again...',
        ),
      );
      _scheduleRepair(Duration.zero);
    }
  }

  void _startDirectDownload(String hash, BookDownload download) {
    _downloading = true;
    if (_receivedChunks.isEmpty) {
      _updateState(
        TransferState(
          status: TransferStatus.waiting,
          bookHash: hash,
          message: 'Downloading the book from the library...',
        ),
      );
    }
    // Asking the room right away would have a holder broadcast the whole book
    // while it is also being downloaded.
    _scheduleRepair(_directDownloadGrace);
    unawaited(_downloadDirect(hash, download, _receiveGeneration));
  }

  Future<void> _downloadDirect(
    String hash,
    BookDownload download,
    int generation,
  ) async {
    Uint8List? bytes;
    try {
      bytes = await download();
      if (bytes.isEmpty ||
          bytes.length > AppConstants.maxFileSize ||
          sha256.convert(bytes).toString() != hash) {
        // The library file changed after it was shared, or the download was
        // cut short. Only the room can have the exact book now.
        throw const FormatException('The library copy is not the shared book');
      }
    } catch (error) {
      if (_disposed || generation != _receiveGeneration) return;
      _downloading = false;
      debugPrint('Library download failed, asking the room: $error');
      if (!_assembling) _scheduleRepair(Duration.zero);
      return;
    }
    if (_disposed || generation != _receiveGeneration) return;
    _downloading = false;
    // The room got there first and its copy is being saved.
    if (_assembling) return;
    _assembling = true;
    try {
      await _store.saveBook(hash, bytes);
    } catch (error) {
      if (_disposed || generation != _receiveGeneration) return;
      _assembling = false;
      debugPrint('Saving the library download failed, asking the room: $error');
      _scheduleRepair(Duration.zero);
      return;
    }
    if (_disposed || generation != _receiveGeneration) return;
    _completeReceive(hash, bytes);
  }

  void _completeReceive(String hash, Uint8List bytes) {
    _stopReceiving();
    _heldHash = hash;
    _heldBytes = bytes;
    _updateState(
      TransferState(
        status: TransferStatus.completed,
        bookHash: hash,
        totalBytes: bytes.length,
        transferredBytes: bytes.length,
        totalChunks: _chunkCount(bytes.length),
        receivedChunks: _chunkCount(bytes.length),
      ),
    );
    debugPrint('Book received and saved: $hash');
  }

  void _scheduleRepair(Duration delay) {
    _repairTimer?.cancel();
    final generation = _receiveGeneration;
    _repairTimer = Timer(delay, () {
      if (_disposed || generation != _receiveGeneration) return;
      unawaited(_requestMissing());
    });
  }

  Future<void> _requestMissing() async {
    final wanted = _wantedHash;
    if (_disposed || wanted == null || _assembling) return;
    final generation = _receiveGeneration;

    final holders = _holdersOf(wanted);
    if (holders.isEmpty) {
      _waitingForHolder = true;
      _updateState(
        _receivingState(
          wanted,
          message: 'Waiting for someone with the book to come online...',
        ),
      );
      // Presence wakes this early when a holder appears.
      _scheduleRepair(_stallTimeout);
      return;
    }
    _waitingForHolder = false;

    // Rotate so one unresponsive holder cannot stall the transfer.
    final holder = holders[_requestAttempt % holders.length];
    _requestAttempt++;
    final missing = _expectedTotalChunks == 0
        ? null
        : [
            for (var index = 0; index < _expectedTotalChunks; index++)
              if (!_receivedChunks.containsKey(index)) index,
          ];
    _updateState(
      _receivingState(
        wanted,
        message: _receivedChunks.isEmpty
            ? 'Asking ${_nickname(holder)} for the book...'
            : null,
      ),
    );

    try {
      await _transport.broadcast(
        event: requestEvent,
        payload: {
          'requester_id': _currentUserId,
          'sender_id': holder['user_id'],
          'book_hash': wanted,
          'missing': missing,
        },
      );
    } catch (error) {
      debugPrint('Book request failed, retrying: $error');
    }
    if (_disposed || generation != _receiveGeneration) return;
    // Back off a little on repeated stalls, but never stop asking.
    final backoff = _requestAttempt > 3 ? 3 : _requestAttempt;
    _scheduleRepair(_stallTimeout * backoff);
  }

  void _onPresence(Map<String, dynamic> _) {
    final wanted = _wantedHash;
    if (_disposed || wanted == null || !_waitingForHolder) return;
    if (_holdersOf(wanted).isNotEmpty) _scheduleRepair(Duration.zero);
  }

  List<Map<String, dynamic>> _holdersOf(String hash) {
    final holders = _transport.getOnlineUsers().where((user) {
      final userId = user['user_id'];
      return userId is String &&
          userId != _currentUserId &&
          presenceHoldsBook(user, hash);
    }).toList();
    // Every receiver starts from the same holder, so their requests collapse
    // into one send queue on that holder.
    holders.sort(
      (a, b) => (a['user_id'] as String).compareTo(b['user_id'] as String),
    );
    return holders;
  }

  TransferState _receivingState(String hash, {String? message}) {
    return TransferState(
      status: _receivedChunks.isEmpty
          ? TransferStatus.waiting
          : TransferStatus.transferring,
      bookHash: hash,
      totalBytes: _expectedTotalBytes,
      transferredBytes: _receivedBytes,
      totalChunks: _expectedTotalChunks,
      receivedChunks: _receivedChunks.length,
      message: message,
    );
  }

  void _stopReceiving() {
    ++_receiveGeneration;
    _repairTimer?.cancel();
    _repairTimer = null;
    _wantedHash = null;
    _assembling = false;
    _waitingForHolder = false;
    _downloading = false;
    _requestAttempt = 0;
    _clearChunks();
  }

  void _clearChunks() {
    _receivedChunks.clear();
    _expectedTotalChunks = 0;
    _expectedTotalBytes = 0;
    _receivedBytes = 0;
  }

  // ---------------------------------------------------------------------------
  // Holding

  void _onTransferRequest(Map<String, dynamic> payload) {
    final held = _heldHash;
    if (_disposed || held == null) return;
    if (payload['sender_id'] != _currentUserId ||
        payload['requester_id'] == _currentUserId ||
        payload['book_hash'] is! String ||
        (payload['book_hash'] as String).toLowerCase() != held) {
      return;
    }
    final missing = payload['missing'];
    unawaited(_serve(held, missing is List ? missing : null));
  }

  Future<void> _serve(String hash, List<dynamic>? missing) async {
    final bytes = await _loadHeldBytes(hash);
    if (bytes == null || _disposed || _heldHash != hash) return;
    final total = _chunkCount(bytes.length);
    _enqueue(
      missing == null
          ? List.generate(total, (index) => index)
          : missing.whereType<int>().where((i) => i >= 0 && i < total),
    );
  }

  Future<Uint8List?> _loadHeldBytes(String hash) async {
    final cached = _heldBytes;
    if (cached != null) return cached;
    try {
      final bytes = await _store.readBook(hash);
      if (bytes != null && _heldHash == hash) _heldBytes = bytes;
      return bytes;
    } catch (error) {
      debugPrint('Unable to read the held book: $error');
      return null;
    }
  }

  void _enqueue(Iterable<int> indices) {
    final before = _sendQueue.length;
    _sendQueue.addAll(indices);
    _batchSize += _sendQueue.length - before;
    if (_sending || _sendQueue.isEmpty) return;
    _sending = true;
    final done = _sendDone = Completer<void>();
    unawaited(_runSendLoop().whenComplete(done.complete));
  }

  Future<void> _runSendLoop() async {
    // Let the caller finish enqueueing before the first send.
    await Future<void>.delayed(Duration.zero);
    String? sentHash;
    while (true) {
      final hash = _heldHash;
      final bytes = _heldBytes;
      if (_disposed || _sendQueue.isEmpty || hash == null || bytes == null) {
        _sending = false;
        break;
      }
      sentHash = hash;
      final index = _sendQueue.first;
      _sendQueue.remove(index);
      _sendTotalChunks = _chunkCount(bytes.length);

      final start = index * AppConstants.fileChunkSize;
      final end = (start + AppConstants.fileChunkSize).clamp(0, bytes.length);
      try {
        await _transport.broadcast(
          event: chunkEvent,
          payload: {
            'sender_id': _currentUserId,
            'book_hash': hash,
            'chunk_index': index,
            'total_chunks': _sendTotalChunks,
            'total_bytes': bytes.length,
            'data': base64Encode(bytes.sublist(start, end)),
          },
        );
      } catch (error) {
        // Whoever needed this chunk asks for it again.
        debugPrint('Book chunk $index not sent: $error');
      }
      _sentInBatch++;
      if (_sendQueue.isNotEmpty) {
        _reportSending(hash);
        await Future<void>.delayed(_chunkDelay);
      }
    }
    _sentInBatch = 0;
    _batchSize = 0;
    // A receive in progress is what this reader cares about; serving others
    // happens quietly underneath it.
    if (!_disposed && sentHash != null && _wantedHash == null) {
      _updateState(
        TransferState(
          status: TransferStatus.completed,
          bookHash: sentHash,
          isSending: true,
        ),
      );
    }
  }

  void _reportSending(String hash) {
    if (_disposed || _wantedHash != null || _batchSize == 0) return;
    // Progress is counted in chunks: a batch can be any subset of the book.
    _updateState(
      TransferState(
        status: TransferStatus.transferring,
        bookHash: hash,
        totalBytes: _batchSize,
        transferredBytes: _sentInBatch.clamp(0, _batchSize),
        totalChunks: _sendTotalChunks,
        receivedChunks: _sentInBatch,
        isSending: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------

  String _nickname(Map<String, dynamic> user) {
    final nickname = user['nickname'];
    return nickname is String && nickname.trim().isNotEmpty
        ? nickname.trim()
        : 'another reader';
  }

  int _chunkCount(int totalBytes) =>
      (totalBytes / AppConstants.fileChunkSize).ceil();

  String _normalizeHash(String hash) {
    final normalized = hash.toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
      throw ArgumentError('Invalid book hash');
    }
    return normalized;
  }

  void _updateState(TransferState newState) {
    if (_disposed) return;
    _state = newState;
    if (!_stateController.isClosed) _stateController.add(newState);
  }

  Future<void> dispose() {
    return _disposeFuture ??= _disposeInternal();
  }

  Future<void> _disposeInternal() async {
    _stopReceiving();
    _disposed = true;
    _sendQueue.clear();
    await Future.wait<void>([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    _subscriptions.clear();
    await _stateController.close();
  }
}
