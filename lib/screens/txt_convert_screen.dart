import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../providers/book_provider.dart' show formatMegabytes;
import '../providers/txt_convert_provider.dart';
import '../widgets/ad_privacy_choices.dart';
import '../widgets/paper.dart';
import '../widgets/txt_import_sheet.dart';
import 'book_preview_screen.dart';
import '../l10n/l10n.dart';

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

    final isSaving = state.isSaving;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.txtToEpub)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
              children: [
                Text(context.l10n.txtConvertIntro, style: AppTheme.body),
                const SizedBox(height: 24),
                if (book == null)
                  ElevatedButton.icon(
                    onPressed: state.isBusy ? null : pick,
                    icon: const Icon(Icons.description_outlined),
                    label: Text(state.busy ?? context.l10n.pickTxtFiles),
                  )
                else ...[
                  SectionHeader(label: context.l10n.converted),
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
                    label: Text(context.l10n.read),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: state.isBusy ? null : notifier.saveBook,
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      isSaving
                          ? context.l10n.saving
                          : state.isSaved
                          ? context.l10n.saveAgain
                          : context.l10n.saveEpub,
                    ),
                  ),
                  if (state.isSaved) ...[
                    const SizedBox(height: 12),
                    PaperNotice(
                      icon: Icons.check,
                      message: context.l10n.savedShareInRoom,
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextButton(
                    // The book above stays until another one is made.
                    onPressed: state.isBusy ? null : pick,
                    child: Text(
                      state.isBusy && !isSaving
                          ? state.busy!
                          : context.l10n.convertOtherFiles,
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
                // Saving shows an ad: its consent is changeable here too,
                // not only in a room (GH-58).
                const AdPrivacyChoices(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
