import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/app_constants.dart';
import '../models/book_metadata.dart';
import '../models/library_book.dart';
import '../services/epub_storage_service.dart';
import '../models/transfer_state.dart';
import '../services/file_transfer_service.dart';
import '../services/library_service.dart';
import '../services/realtime_service.dart';
import 'presence_provider.dart';
import 'room_provider.dart';

final epubStorageProvider = Provider<EpubStorageService>((ref) {
  return EpubStorageService();
});

final libraryServiceProvider = Provider<LibraryService>((ref) {
  return const SupabaseLibraryService();
});

/// Only EPUB books are shared; see [BookNotifier.pickAndShareBook].
bool isEpubFileName(String name) => name.toLowerCase().endsWith('.epub');

const notEpubMessage =
    'Only EPUB books can be shared. Make a TXT file into one with '
    '"TXT to EPUB" on the home screen first.';

String formatMegabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// The bytes of a file the picker returned, whether it read them or not.
Future<Uint8List> readPickedFile(PlatformFile file) async {
  if (file.bytes != null) return file.bytes!;
  if (file.path != null) return File(file.path!).readAsBytes();
  throw Exception('Cannot read ${file.name}');
}

final bookProvider = StateNotifierProvider<BookNotifier, BookState>((ref) {
  return BookNotifier(
    ref: ref,
    storageService: ref.read(epubStorageProvider),
    library: ref.read(libraryServiceProvider),
  );
});

class BookState {
  final BookMetadata? currentBook;
  final File? bookFile;
  final bool isLoading;
  final String? error;

  const BookState({
    this.currentBook,
    this.bookFile,
    this.isLoading = false,
    this.error,
  });

  bool get hasBook => bookFile != null;

  /// Keeps [error] unless a new one is given or [clearError] is set (GH-30):
  /// a message must not disappear because some unrelated update ran.
  BookState copyWith({
    BookMetadata? currentBook,
    File? bookFile,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return BookState(
      currentBook: currentBook ?? this.currentBook,
      bookFile: bookFile ?? this.bookFile,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class BookNotifier extends StateNotifier<BookState> {
  final Ref ref;
  final EpubStorageService _storageService;
  final LibraryService _library;
  FileTransferService? _transferService;
  StreamSubscription<TransferState>? _transferStateSubscription;
  RealtimeService? _transferRealtimeService;
  String? _transferUserId;
  String? _transferRoomCode;
  String? _loadedBookHash;
  String? _expectedBookHash;

  /// Where [_expectedBookHash] is in the public library, if it came from there.
  String? _expectedLibraryPath;
  int _sessionGeneration = 0;

  /// Bumped whenever this device starts sharing a book and whenever the room
  /// moves to another book. A library download can take a minute; if someone
  /// shares a different book meanwhile, finishing it must not put the room
  /// back on the old one.
  int _shareGeneration = 0;
  int _transferGeneration = 0;
  Future<void> _transferOperationTail = Future<void>.value();
  bool _isDisposed = false;

  /// How long a book error stays up on its own (GH-44). Longer than a page
  /// sync error: the lobby is where people wait, often looking away, and the
  /// notice can be dismissed sooner. Retrying is always just another share.
  static const defaultErrorAutoClearDelay = Duration(seconds: 20);

  final Duration _errorAutoClearDelay;
  Timer? _errorAutoClearTimer;

  BookNotifier({
    required this.ref,
    required EpubStorageService storageService,
    required LibraryService library,
    Duration errorAutoClearDelay = defaultErrorAutoClearDelay,
  }) : _storageService = storageService,
       _library = library,
       _errorAutoClearDelay = errorAutoClearDelay,
       super(const BookState());

  /// Takes the error notice down (the reader closed it).
  void dismissError() {
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = null;
    if (state.error != null) state = state.copyWith(clearError: true);
  }

  /// Shows [error] for [_errorAutoClearDelay]. Only that error is cleared:
  /// unrelated updates in between keep it (GH-30), and a newer error gets its
  /// own full time.
  void _showError(String error, {bool? isLoading}) {
    state = state.copyWith(isLoading: isLoading, error: error);
    final shown = state.error;
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = Timer(_errorAutoClearDelay, () {
      _errorAutoClearTimer = null;
      if (_isDisposed || !identical(state.error, shown)) return;
      state = state.copyWith(clearError: true);
    });
  }

  Future<void> initTransferService({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String roomCode,
  }) {
    final normalizedRoomCode = roomCode.trim().toUpperCase();
    final sessionGeneration = _sessionGeneration;
    return _serializeTransferOperation(() async {
      if (!_isCurrent(sessionGeneration)) return;
      if (_transferService != null &&
          identical(_transferRealtimeService, realtimeService) &&
          _transferUserId == currentUserId &&
          _transferRoomCode == normalizedRoomCode) {
        return;
      }

      await _replaceTransferService(
        realtimeService: realtimeService,
        currentUserId: currentUserId,
        roomCode: normalizedRoomCode,
        sessionGeneration: sessionGeneration,
      );
    });
  }

  Future<void> _replaceTransferService({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String roomCode,
    required int sessionGeneration,
  }) async {
    await _disposeTransferServiceInternal();
    if (!_isCurrent(sessionGeneration)) return;
    _transferRealtimeService = realtimeService;
    _transferUserId = currentUserId;
    _transferRoomCode = roomCode;
    _transferService = FileTransferService(
      transport: RealtimeBookTransferTransport(realtimeService),
      store: _storageService,
      currentUserId: currentUserId,
    );
    _transferService!.initialize();
    final loadedBookHash = _loadedBookHash;
    if (loadedBookHash != null && state.bookFile != null) {
      _transferService!.holdBook(loadedBookHash);
    } else if (_expectedBookHash != null) {
      _transferService!.expectBook(
        _expectedBookHash!,
        download: _libraryDownload(_expectedLibraryPath),
      );
    }
    final transferGeneration = _transferGeneration;

    // Listen for transfer completion
    _transferStateSubscription = _transferService!.stateStream.listen((
      transferState,
    ) {
      if (transferState.status == TransferStatus.completed &&
          !transferState.isSending &&
          transferState.bookHash != null) {
        unawaited(
          _onBookReceived(
            transferState.bookHash!,
            sessionGeneration,
            transferGeneration,
          ).catchError((Object error) {
            if (_isCurrent(sessionGeneration) &&
                transferGeneration == _transferGeneration) {
              _showError(error.toString());
            }
          }),
        );
      }
    });
  }

  /// Picks an EPUB from this device and shares it.
  ///
  /// Only EPUB: a TXT file is made into one with the TXT to EPUB tool on the
  /// home screen, where it can be read and checked before anyone waits on it.
  Future<void> pickAndShareBook() async {
    final generation = _sessionGeneration;
    // Receiving (or serving) a book never blocks sharing a different one: the
    // new hash simply replaces what the transfer is working on. Refusing here
    // is what used to strand a room behind a stalled transfer.
    state = state.copyWith(isLoading: true, clearError: true);
    int? shareGeneration;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
        withData: true,
      );

      if (!_isCurrent(generation)) return;
      if (result == null || result.files.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }

      final file = result.files.single;
      // Some file managers ignore the filter.
      if (!isEpubFileName(file.name)) {
        _failShare(generation, null, notEpubMessage);
        return;
      }

      // Taken after the picker closes: choosing a file is the decision, so a
      // book shared while the picker was open does not cancel it.
      shareGeneration = ++_shareGeneration;
      final bytes = await readPickedFile(file);

      await _shareBytes(
        bytes: bytes,
        title: file.name.replaceAll('.epub', ''),
        fileName: file.name,
        generation: generation,
        shareGeneration: shareGeneration,
      );
    } catch (e) {
      _failShare(generation, shareGeneration, e.toString());
    }
  }

  /// Shares [book] from the public library with the room.
  ///
  /// The others download it from the library themselves, so nothing is pushed
  /// over Realtime; this device still serves anyone who asks for it.
  Future<void> shareLibraryBook(LibraryBook book) async {
    final generation = _sessionGeneration;
    final shareGeneration = ++_shareGeneration;
    state = state.copyWith(isLoading: true, clearError: true);
    final Uint8List bytes;
    try {
      bytes = await _library.download(book.path);
    } catch (e) {
      _failShare(
        generation,
        shareGeneration,
        'Could not get "${book.title}" from the library: $e',
      );
      return;
    }
    if (!_isCurrent(generation)) return;
    try {
      await _shareBytes(
        bytes: bytes,
        title: book.title,
        author: book.author,
        fileName: book.fileName,
        libraryPath: book.path,
        generation: generation,
        shareGeneration: shareGeneration,
      );
    } catch (e) {
      _failShare(generation, shareGeneration, e.toString());
    }
  }

  /// Reports a failed share, unless another book has replaced it: the error
  /// would then sit under a book that arrived fine, with nothing to clear it.
  void _failShare(int generation, int? shareGeneration, String error) {
    if (!_isCurrent(generation)) return;
    final superseded =
        shareGeneration != null && shareGeneration != _shareGeneration;
    if (superseded) {
      state = state.copyWith(isLoading: false);
    } else {
      _showError(error, isLoading: false);
    }
  }

  Future<void> _shareBytes({
    required Uint8List bytes,
    required String title,
    required String fileName,
    required int generation,
    required int shareGeneration,
    String? author,
    String? libraryPath,
  }) async {
    if (!_isCurrentShare(generation, shareGeneration)) return;
    if (bytes.isEmpty) throw Exception('The book file is empty');
    if (bytes.length > AppConstants.maxFileSize) {
      throw Exception(
        'This book is ${formatMegabytes(bytes.length)}. Books can be at most '
        '${formatMegabytes(AppConstants.maxFileSize)}.',
      );
    }

    final hash = await _storageService.computeHash(bytes);
    final savedFile = await _storageService.saveBook(hash, bytes);
    if (!_isCurrentShare(generation, shareGeneration)) return;

    final metadata = BookMetadata(
      id: hash,
      title: title,
      author: author ?? 'Unknown',
      fileName: fileName,
      fileSizeBytes: bytes.length,
      fileHash: hash,
      libraryPath: libraryPath,
    );

    final isRoomBook = await ref
        .read(roomProvider.notifier)
        .updateBookShared(
          bookTitle: metadata.title,
          bookHash: hash,
          libraryPath: libraryPath,
        );
    if (!_isCurrent(generation)) return;
    if (!isRoomBook) {
      // Someone else's book reached the room first. Follow it: its share
      // broadcast may have arrived already, or may never arrive.
      state = state.copyWith(isLoading: false);
      final room = ref.read(roomProvider).currentRoom;
      final roomBookHash = room?.currentBookHash;
      if (roomBookHash != null) {
        await prepareForSharedBook(
          roomBookHash,
          libraryPath: room?.currentBookLibraryPath,
        );
      }
      return;
    }
    if (!_isCurrentShare(generation, shareGeneration)) return;

    state = state.copyWith(
      currentBook: metadata,
      bookFile: savedFile,
      isLoading: false,
      clearError: true,
    );
    _loadedBookHash = hash;
    _expectedBookHash = hash;
    _expectedLibraryPath = libraryPath;
    _transferService?.holdBook(hash, bytes: bytes);

    await ref
        .read(presenceProvider.notifier)
        .updateHasBook(true, bookHash: hash);
    if (!_isCurrentShare(generation, shareGeneration)) return;

    // Broadcast book_shared event
    final realtimeService = ref.read(realtimeServiceProvider);
    await realtimeService.broadcast(
      event: 'book_shared',
      payload: metadata.toJson(),
    );
    // Pushing would also hold this book again and stop receiving the newer
    // one.
    if (!_isCurrentShare(generation, shareGeneration)) return;

    // A library book is downloaded by each receiver; pushing 40MB through
    // Realtime as well would only race those downloads.
    if (libraryPath != null) return;
    // Push to everyone now; anyone who misses part of it asks for the rest.
    await _transferService?.shareBook(fileBytes: bytes, bookHash: hash);
  }

  /// Whether a share is still the newest thing that happened to the room's
  /// book. Every await in [_shareBytes] is a window for another member's
  /// share to arrive; once one has, it is the room's book (it committed after
  /// this one, or this one would have lost the write) and announcing or
  /// serving this one would move the room back to a book the database no
  /// longer has.
  bool _isCurrentShare(int generation, int shareGeneration) {
    if (!_isCurrent(generation)) return false;
    if (shareGeneration == _shareGeneration) return true;
    // Share is disabled while loading, so the newer share is someone else's.
    state = state.copyWith(isLoading: false);
    return false;
  }

  /// A download of the room's book from the library, or null when it did not
  /// come from there.
  BookDownload? _libraryDownload(String? libraryPath) {
    if (libraryPath == null) return null;
    final library = _library;
    return () => library.download(libraryPath);
  }

  Future<void> _onBookReceived(
    String bookHash,
    int generation,
    int transferGeneration,
  ) async {
    // A receive that finishes after the room moved on to another book must not
    // replace it.
    if (bookHash != _expectedBookHash) return;
    final bookFile = await _storageService.getBookFile(bookHash);
    if (bookFile != null &&
        bookHash == _expectedBookHash &&
        _isCurrent(generation) &&
        transferGeneration == _transferGeneration) {
      // The room's book is here: whatever went wrong getting it is over.
      state = state.copyWith(
        bookFile: bookFile,
        isLoading: false,
        clearError: true,
      );
      _loadedBookHash = bookHash;
      _expectedBookHash = bookHash;

      // Update DB member status and presence
      await ref.read(roomProvider.notifier).updateReceiverBookStatus();
      if (!_isCurrent(generation) ||
          transferGeneration != _transferGeneration) {
        return;
      }
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
    }
  }

  /// Opens the room's book [bookHash] when entering the lobby: from this
  /// device if it is here, otherwise by receiving it. [libraryPath] is the
  /// room's record of where the book is in the public library, so a member
  /// who missed the share broadcast still downloads it directly (GH-28).
  Future<void> loadExistingBook(String bookHash, {String? libraryPath}) async {
    final generation = _sessionGeneration;
    final file = await _storageService.getBookFile(bookHash);
    if (!_isCurrent(generation)) return;
    if (file != null) {
      state = state.copyWith(
        bookFile: file,
        isLoading: false,
        clearError: true,
      );
      _loadedBookHash = bookHash;
      _expectedBookHash = bookHash;
      _transferService?.holdBook(bookHash);
      await ref.read(roomProvider.notifier).updateReceiverBookStatus();
      if (!_isCurrent(generation)) return;
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
    } else {
      await prepareForSharedBook(bookHash, libraryPath: libraryPath);
    }
  }

  bool hasBook(String bookHash) {
    return state.bookFile != null && _loadedBookHash == bookHash;
  }

  /// The room's book is now [bookHash]. [libraryPath] says where it is in the
  /// public library when the sharer took it from there.
  Future<void> prepareForSharedBook(
    String bookHash, {
    String? libraryPath,
  }) async {
    final generation = _sessionGeneration;
    if (bookHash != _expectedBookHash) {
      _expectedLibraryPath = null;
      ++_shareGeneration;
    }
    _expectedBookHash = bookHash;
    // The path comes from a room broadcast or the room row, both written by
    // other members; anything but a plain object name in the library bucket
    // is ignored. The download is hash-checked anyway.
    if (libraryPath != null && isPlainLibraryPath(libraryPath)) {
      _expectedLibraryPath = libraryPath;
    }
    if (hasBook(bookHash)) {
      _transferService?.holdBook(bookHash);
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
      return;
    }
    if (!_isCurrent(generation)) return;
    _transferService?.expectBook(
      bookHash,
      download: _libraryDownload(_expectedLibraryPath),
    );
    _loadedBookHash = null;
    // Not isLoading: that flag means "picking a file" and disables Share.
    // Receiving shows through the transfer state instead.
    state = const BookState();
    await ref.read(presenceProvider.notifier).updateHasBook(false);
  }

  FileTransferService? get transferService => _transferService;

  Future<void> reset() async {
    ++_sessionGeneration;
    _loadedBookHash = null;
    _expectedBookHash = null;
    _expectedLibraryPath = null;
    state = const BookState();
    await _serializeTransferOperation(_disposeTransferServiceInternal);
  }

  Future<void> _disposeTransferServiceInternal() async {
    ++_transferGeneration;
    await _transferStateSubscription?.cancel();
    _transferStateSubscription = null;
    await _transferService?.dispose();
    _transferService = null;
    _transferRealtimeService = null;
    _transferUserId = null;
    _transferRoomCode = null;
  }

  bool _isCurrent(int generation) {
    return !_isDisposed && generation == _sessionGeneration;
  }

  Future<void> _serializeTransferOperation(Future<void> Function() operation) {
    final completer = Completer<void>();
    _transferOperationTail = _transferOperationTail
        .catchError((Object _) {})
        .then((_) async {
          try {
            await operation();
            completer.complete();
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _errorAutoClearTimer?.cancel();
    ++_sessionGeneration;
    unawaited(_serializeTransferOperation(_disposeTransferServiceInternal));
    super.dispose();
  }
}

/// A library object name: no leading slash, no `..` segment, no backslash.
bool isPlainLibraryPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  return !path.split('/').any((segment) => segment.isEmpty || segment == '..');
}
