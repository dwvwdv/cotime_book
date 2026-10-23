import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../providers/book_provider.dart' show formatMegabytes;
import '../providers/txt_convert_provider.dart';
import '../widgets/paper.dart';
import '../widgets/txt_import_sheet.dart';
import 'book_preview_screen.dart';

typedef OpenConvertedBook =
    void Function(BuildContext context, ConvertedBook book);

void _openInPreview(BuildContext context, ConvertedBook book) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BookPreviewScreen(file: book.file, title: book.title),
    ),
  );
}

/// TXT to EPUB, on its own, away from any room.
///
/// The person converting reads the result first; only an EPUB they are happy
/// with is saved, and shared in a room from there with Share Book.
class TxtConvertScreen extends ConsumerWidget {
  final OpenConvertedBook openBook;

  const TxtConvertScreen({super.key, this.openBook = _openInPreview});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(txtConvertProvider);
    final notifier = ref.read(txtConvertProvider.notifier);
    final book = state.book;

    Future<void> pick() => notifier.pickAndConvert(
      confirm: (draft) async {
        if (!context.mounted) return null;
        return showTxtImportSheet(context: context, draft: draft);
      },
    );

    return Scaffold(
      appBar: AppBar(title: const Text('TXT to EPUB')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
              children: [
                const Text(
                  'Make an EPUB from TXT files and read it here to check '
                  'the text and chapters. Save it once it looks right, then '
                  'share the saved EPUB in a room.',
                  style: AppTheme.body,
                ),
                const SizedBox(height: 24),
                if (book == null)
                  ElevatedButton.icon(
                    onPressed: state.isBusy ? null : pick,
                    icon: const Icon(Icons.description_outlined),
                    label: Text(state.busy ?? 'Pick TXT Files'),
                  )
                else ...[
                  const SectionHeader(label: 'Converted'),
                  const SizedBox(height: 12),
                  Text(book.title, style: AppTheme.title),
                  if (book.author != null) ...[
                    const SizedBox(height: 4),
                    Text(book.author!, style: AppTheme.body),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '${book.fileName} · ${formatMegabytes(book.sizeBytes)}',
                    style: AppTheme.caption,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: state.isBusy
                        ? null
                        : () => openBook(context, book),
                    icon: const Icon(Icons.menu_book_outlined),
                    label: const Text('Read'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: state.isBusy ? null : notifier.saveBook,
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      state.busy == 'Saving...'
                          ? 'Saving...'
                          : state.isSaved
                          ? 'Save Again'
                          : 'Save EPUB',
                    ),
                  ),
                  if (state.isSaved) ...[
                    const SizedBox(height: 12),
                    const PaperNotice(
                      icon: Icons.check,
                      message:
                          'Saved. In a room, tap Share Book and pick this '
                          'file.',
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextButton(
                    // The book above stays until another one is made.
                    onPressed: state.isBusy ? null : pick,
                    child: Text(
                      state.isBusy && state.busy != 'Saving...'
                          ? state.busy!
                          : 'Convert Other Files',
                    ),
                  ),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: 20),
                  PaperNotice(
                    message: state.error!,
                    onDismiss: notifier.dismissError,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
