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

  BookState copyWith({
    BookMetadata? currentBook,
    File? bookFile,
    bool? isLoading,
    String? error,
  }) {
    return BookState(
      currentBook: currentBook ?? this.currentBook,
      bookFile: bookFile ?? this.bookFile,
      isLoading: isLoading ?? this.isLoading,
      error: error,
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

  BookNotifier({
    required this.ref,
    required EpubStorageService storageService,
    required LibraryService library,
  }) : _storageService = storageService,
       _library = library,
       super(const BookState());

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
              state = state.copyWith(error: error.toString());
            }
          }),
        );
      }
    });
  }

  Future<void> pickAndShareBook() async {
    final generation = _sessionGeneration;
    // Receiving (or serving) a book never blocks sharing a different one: the
    // new hash simply replaces what the transfer is working on. Refusing here
    // is what used to strand a room behind a stalled transfer.
    state = state.copyWith(isLoading: true, error: null);
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

      // Taken after the picker closes: choosing a file is the decision, so a
      // book shared while the picker was open does not cancel it.
      final shareGeneration = ++_shareGeneration;
      final file = result.files.first;
      final Uint8List bytes;

      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        throw Exception('Cannot read file');
      }

      await _shareBytes(
        bytes: bytes,
        title: file.name.replaceAll('.epub', ''),
        fileName: file.name,
        generation: generation,
        shareGeneration: shareGeneration,
      );
    } catch (e) {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
    }
  }

  /// Shares [book] from the public library with the room.
  ///
  /// The others download it from the library themselves, so nothing is pushed
  /// over Realtime; this device still serves anyone who asks for it.
  Future<void> shareLibraryBook(LibraryBook book) async {
    final generation = _sessionGeneration;
    final shareGeneration = ++_shareGeneration;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final bytes = await _library.download(book.path);
      if (!_isCurrent(generation)) return;
      await _shareBytes(
        bytes: bytes,
        title: book.title,
        fileName: book.fileName,
        libraryPath: book.path,
        generation: generation,
        shareGeneration: shareGeneration,
      );
    } catch (e) {
      if (_isCurrent(generation)) {
        state = state.copyWith(
          isLoading: false,
          error: 'Could not get "${book.title}" from the library: $e',
        );
      }
    }
  }

  Future<void> _shareBytes({
    required Uint8List bytes,
    required String title,
    required String fileName,
    required int generation,
    required int shareGeneration,
    String? libraryPath,
  }) async {
    if (shareGeneration != _shareGeneration) {
      // Another book was shared meanwhile and is the room's book now. Share
      // is disabled while loading, so that came from someone else.
      state = state.copyWith(isLoading: false);
      return;
    }
    if (bytes.isEmpty) throw Exception('The book file is empty');
    if (bytes.length > AppConstants.maxFileSize) {
      throw Exception(
        'This book is ${_megabytes(bytes.length)}. Books can be at most '
        '${_megabytes(AppConstants.maxFileSize)}.',
      );
    }

    final hash = await _storageService.computeHash(bytes);
    final savedFile = await _storageService.saveBook(hash, bytes);
    if (!_isCurrent(generation)) return;
    if (shareGeneration != _shareGeneration) {
      // Another book was shared meanwhile and is the room's book now. Share
      // is disabled while loading, so that came from someone else.
      state = state.copyWith(isLoading: false);
      return;
    }

    final metadata = BookMetadata(
      id: hash,
      title: title,
      author: 'Unknown',
      fileName: fileName,
      fileSizeBytes: bytes.length,
      fileHash: hash,
      libraryPath: libraryPath,
    );

    state = state.copyWith(
      currentBook: metadata,
      bookFile: savedFile,
      isLoading: false,
    );
    _loadedBookHash = hash;
    _expectedBookHash = hash;
    _expectedLibraryPath = libraryPath;
    _transferService?.holdBook(hash, bytes: bytes);

    // Update room with book info
    await ref
        .read(roomProvider.notifier)
        .updateBookShared(bookTitle: metadata.title, bookHash: hash);
    if (!_isCurrent(generation)) return;
    await ref
        .read(presenceProvider.notifier)
        .updateHasBook(true, bookHash: hash);
    if (!_isCurrent(generation)) return;

    // Broadcast book_shared event
    final realtimeService = ref.read(realtimeServiceProvider);
    await realtimeService.broadcast(
      event: 'book_shared',
      payload: metadata.toJson(),
    );
    if (!_isCurrent(generation)) return;

    // A library book is downloaded by each receiver; pushing 40MB through
    // Realtime as well would only race those downloads.
    if (libraryPath != null) return;
    // Push to everyone now; anyone who misses part of it asks for the rest.
    await _transferService?.shareBook(fileBytes: bytes, bookHash: hash);
  }

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

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
      state = state.copyWith(bookFile: bookFile, isLoading: false);
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

  Future<void> loadExistingBook(String bookHash) async {
    final generation = _sessionGeneration;
    final file = await _storageService.getBookFile(bookHash);
    if (!_isCurrent(generation)) return;
    if (file != null) {
      state = state.copyWith(bookFile: file, isLoading: false);
      _loadedBookHash = bookHash;
      _expectedBookHash = bookHash;
      _transferService?.holdBook(bookHash);
      await ref.read(roomProvider.notifier).updateReceiverBookStatus();
      if (!_isCurrent(generation)) return;
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
    } else {
      await prepareForSharedBook(bookHash);
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
    // The path arrives in a room broadcast; anything but a plain object name
    // in the library bucket is ignored. The download is hash-checked anyway.
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
