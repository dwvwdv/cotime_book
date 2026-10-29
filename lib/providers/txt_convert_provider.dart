import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_constants.dart';
import '../services/txt_book.dart';
import 'ads_provider.dart';
import 'book_provider.dart' show formatMegabytes, readPickedFile;
import '../l10n/l10n.dart';

/// Shows the reader the TXT files about to become a book; null backs out.
typedef TxtImportConfirm =
    Future<TxtBookRequest?> Function(TxtImportDraft draft);

/// Saves [bytes] where the reader chooses, named [fileName] by default.
/// Resolves with where it went, or null when the reader backed out.
typedef BookExporter =
    Future<String?> Function(String fileName, Uint8List bytes);

/// Where a converted book is kept while it is read and saved.
typedef ConvertedBooksDirectory = Future<Directory> Function();

/// Runs before every save and resolves when the save may go on: the
/// interstitial ad shown there.
typedef BeforeSave = Future<void> Function();

Future<void> _nothingBeforeSave() async {}

Future<String?> exportWithSaveDialog(String fileName, Uint8List bytes) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: appStrings.saveEpub,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ['epub'],
    bytes: bytes,
  );
  // The desktop dialogs only choose a path; on phones the plugin writes.
  if (path != null && !Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return path;
}

Future<Directory> _temporaryConvertedBooks() async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/converted');
  return dir.create(recursive: true);
}

/// A file name for [title] that every file system takes.
String epubFileNameFor(String title) {
  final safe = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  return '${safe.isEmpty ? 'book' : safe}.epub';
}

/// The EPUB a TXT conversion made, on this device only.
class ConvertedBook {
  final File file;
  final String title;
  final String? author;
  final String fileName;
  final int sizeBytes;

  const ConvertedBook({
    required this.file,
    required this.title,
    required this.fileName,
    required this.sizeBytes,
    this.author,
  });
}

class TxtConvertState {
  /// What is being done, for the button that is busy: null when idle.
  final String? busy;

  /// The busy step is saving [book]. A flag rather than a look at [busy]:
  /// that is display text, in the reader's language.
  final bool isSaving;
  final ConvertedBook? book;

  /// [book] has been saved where the reader chose.
  final bool isSaved;
  final String? error;

  const TxtConvertState({
    this.busy,
    this.isSaving = false,
    this.book,
    this.isSaved = false,
    this.error,
  });

  bool get isBusy => busy != null;
}

/// The TXT to EPUB tool on the home screen.
///
/// Converting is kept out of rooms: a book is read here first, by the one
/// person who made it, so a wrong encoding or chapter split costs nobody
/// else's time. What comes out is a plain EPUB file, shared in a room like
/// any other — rooms, transfer and the reader never see TXT.
class TxtConvertNotifier extends StateNotifier<TxtConvertState> {
  final BookExporter _export;
  final ConvertedBooksDirectory _directory;
  final BeforeSave _beforeSave;

  /// Bumped by every conversion, save and dismissal, so a slow one cannot
  /// land on top of what the reader did since.
  int _generation = 0;

  static const defaultErrorAutoClearDelay = Duration(seconds: 20);
  final Duration _errorAutoClearDelay;
  Timer? _errorAutoClearTimer;

  TxtConvertNotifier({
    BookExporter export = exportWithSaveDialog,
    ConvertedBooksDirectory directory = _temporaryConvertedBooks,
    BeforeSave beforeSave = _nothingBeforeSave,
    Duration errorAutoClearDelay = defaultErrorAutoClearDelay,
  }) : _export = export,
       _directory = directory,
       _beforeSave = beforeSave,
       _errorAutoClearDelay = errorAutoClearDelay,
       super(const TxtConvertState());

  /// Picks TXT files from this device and converts them (see [convert]).
  Future<void> pickAndConvert({required TxtImportConfirm confirm}) async {
    if (state.isBusy) return;
    final generation = ++_generation;
    _setBusy(appStrings.opening);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        allowMultiple: true,
        withData: true,
      );
      if (!_isCurrent(generation)) return;
      if (result == null || result.files.isEmpty) {
        _setIdle();
        return;
      }
      // Some file managers ignore the filter.
      if (!result.files.every((f) => f.name.toLowerCase().endsWith('.txt'))) {
        throw FormatException(appStrings.pickOnlyTxt);
      }
      final sources = [
        for (final file in result.files)
          TxtSource(fileName: file.name, bytes: await readPickedFile(file)),
      ];
      if (!_isCurrent(generation)) return;
      await _convert(sources, confirm, generation);
    } on FormatException catch (e) {
      _fail(generation, e.message);
    } catch (e) {
      _fail(generation, e.toString());
    }
  }

  /// Converts [sources] into one EPUB on this device.
  ///
  /// [confirm] gets the files in reading order with what each decodes to,
  /// and answers with the book to build, or null to back out.
  Future<void> convert(
    List<TxtSource> sources, {
    required TxtImportConfirm confirm,
  }) async {
    if (state.isBusy) return;
    final generation = ++_generation;
    try {
      await _convert(sources, confirm, generation);
    } on FormatException catch (e) {
      _fail(generation, e.message);
    } catch (e) {
      _fail(generation, e.toString());
    }
  }

  Future<void> _convert(
    List<TxtSource> sources,
    TxtImportConfirm confirm,
    int generation,
  ) async {
    _setBusy(appStrings.reading);
    final total = sources.fold<int>(0, (n, s) => n + s.bytes.length);
    if (total > AppConstants.maxFileSize) {
      throw FormatException(
        appStrings.txtSourcesTooLarge(
          sources.length,
          formatMegabytes(total),
          formatMegabytes(AppConstants.maxFileSize),
        ),
      );
    }
    final ordered = [...sources]
      ..sort((a, b) => naturalCompare(a.fileName, b.fileName));
    final analyses = await Future.wait(
      ordered.map((source) => analyzeTxtInBackground(source)),
    );
    if (!_isCurrent(generation)) return;

    final request = await confirm(
      TxtImportDraft(
        sources: ordered,
        analyses: analyses,
        title: suggestTxtTitle(ordered.map((s) => s.fileName).toList()),
        author: analyses
            .map((a) => a.author)
            .firstWhere((a) => a != null, orElse: () => null),
      ),
    );
    if (!_isCurrent(generation)) return;
    if (request == null) {
      _setIdle();
      return;
    }

    _setBusy(appStrings.converting);
    final bytes = await buildTxtEpubInBackground(request);
    if (!_isCurrent(generation)) return;
    if (bytes.length > AppConstants.maxFileSize) {
      throw FormatException(
        appStrings.convertedBookTooLarge(
          formatMegabytes(bytes.length),
          formatMegabytes(AppConstants.maxFileSize),
        ),
      );
    }

    // Named by content: the same book made twice is the same file.
    final dir = await _directory();
    final file = File('${dir.path}/${sha256.convert(bytes)}.epub');
    await file.writeAsBytes(bytes, flush: true);
    if (!_isCurrent(generation)) return;

    final previous = state.book?.file;
    final title = request.title.trim();
    final author = request.author?.trim();
    _errorAutoClearTimer?.cancel();
    state = TxtConvertState(
      book: ConvertedBook(
        file: file,
        title: title,
        author: author == null || author.isEmpty ? null : author,
        fileName: epubFileNameFor(title),
        sizeBytes: bytes.length,
      ),
    );
    if (previous != null && previous.path != file.path) {
      unawaited(_deleteQuietly(previous));
    }
  }

  /// Saves the converted book where the reader chooses, so it can be shared
  /// in a room from there. An ad comes first, every time.
  Future<void> saveBook() async {
    final book = state.book;
    if (book == null || state.isBusy) return;
    final generation = ++_generation;
    _setBusy(appStrings.saving, saving: true);
    try {
      await _beforeSave();
    } catch (_) {
      // An ad that goes wrong is no reason to keep the book unsaved.
    }
    if (!_isCurrent(generation)) return;
    try {
      final path = await _export(book.fileName, await book.file.readAsBytes());
      if (!_isCurrent(generation)) return;
      state = TxtConvertState(
        book: book,
        isSaved: state.isSaved || path != null,
      );
    } catch (e) {
      _fail(generation, appStrings.couldNotSaveEpub('$e'));
    }
  }

  /// Puts the tool back to the start, for another book.
  void clear() {
    _generation++;
    final previous = state.book?.file;
    _errorAutoClearTimer?.cancel();
    state = const TxtConvertState();
    if (previous != null) unawaited(_deleteQuietly(previous));
  }

  void dismissError() {
    _errorAutoClearTimer?.cancel();
    if (state.error != null) {
      state = TxtConvertState(
        busy: state.busy,
        book: state.book,
        isSaved: state.isSaved,
      );
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _setBusy(String what, {bool saving = false}) {
    state = TxtConvertState(
      busy: what,
      isSaving: saving,
      book: state.book,
      isSaved: state.isSaved,
    );
  }

  void _setIdle() {
    state = TxtConvertState(book: state.book, isSaved: state.isSaved);
  }

  /// Shows [error] until [_errorAutoClearDelay] passes or something replaces
  /// it. The book converted before, if any, stays: a failed second try does
  /// not take away the first.
  void _fail(int generation, String error) {
    if (!_isCurrent(generation)) return;
    state = TxtConvertState(
      book: state.book,
      isSaved: state.isSaved,
      error: error,
    );
    final shown = state.error;
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = Timer(_errorAutoClearDelay, () {
      if (!mounted || !identical(state.error, shown)) return;
      dismissError();
    });
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A temporary file; the system clears the directory eventually.
    }
  }

  @override
  void dispose() {
    _errorAutoClearTimer?.cancel();
    final book = state.book;
    if (book != null) unawaited(_deleteQuietly(book.file));
    super.dispose();
  }
}

/// Lives as long as the tool is open: leaving it lets go of the book, which
/// by then has been saved or was not wanted.
final txtConvertProvider =
    StateNotifierProvider.autoDispose<TxtConvertNotifier, TxtConvertState>(
      (ref) => TxtConvertNotifier(
        beforeSave: () => ref.read(txtSaveAdsProvider).show(),
      ),
    );
