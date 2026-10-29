import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../services/txt_book.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

typedef TxtReanalyze =
    Future<TxtFileAnalysis> Function(TxtSource source, TxtEncoding encoding);

Future<TxtFileAnalysis> _reanalyzeInBackground(
  TxtSource source,
  TxtEncoding encoding,
) => analyzeTxtInBackground(source, encoding: encoding);

/// Shows the TXT files about to become one book. Resolves with the book to
/// build, or null when the reader backed out.
Future<TxtBookRequest?> showTxtImportSheet({
  required BuildContext context,
  required TxtImportDraft draft,
}) {
  return showPaperDialog<TxtBookRequest>(
    context: context,
    builder: (sheetContext) {
      // The dialog keeps it clear of the keyboard and caps its height.
      return TxtImportSheet(
        draft: draft,
        onConfirm: (request) => Navigator.of(sheetContext).pop(request),
        onCancel: () => Navigator.of(sheetContext).pop(),
      );
    },
  );
}

/// Title, author and the files in reading order, each with its encoding.
///
/// The encoding is the one thing detection can get wrong, and only a person
/// can tell: each file shows its first lines, and a wrong guess reads as
/// nonsense there. Changing it decodes the file again.
///
/// Chapter headings are found by rule, and a rule can take a line of prose
/// for one. The rules are not something to edit on an e-reader, so there is
/// one switch instead: off, the book is cut by length alone.
class TxtImportSheet extends StatefulWidget {
  final TxtImportDraft draft;
  final ValueChanged<TxtBookRequest> onConfirm;
  final VoidCallback onCancel;
  final TxtReanalyze reanalyze;

  const TxtImportSheet({
    super.key,
    required this.draft,
    required this.onConfirm,
    required this.onCancel,
    this.reanalyze = _reanalyzeInBackground,
  });

  @override
  State<TxtImportSheet> createState() => _TxtImportSheetState();
}

class _FileRow {
  final TxtSource source;
  TxtFileAnalysis analysis;

  /// Bumped per encoding change, so a slow decode of an encoding the reader
  /// has already moved away from cannot replace the newer one.
  int generation = 0;
  bool isReading = false;

  _FileRow(this.source, this.analysis);
}

class _TxtImportSheetState extends State<TxtImportSheet> {
  late final TextEditingController _title;
  late final TextEditingController _author;
  late final List<_FileRow> _rows;
  bool _findChapters = true;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.draft.title);
    _author = TextEditingController(text: widget.draft.author ?? '');
    _rows = [
      for (var i = 0; i < widget.draft.sources.length; i++)
        _FileRow(widget.draft.sources[i], widget.draft.analyses[i]),
    ];
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  Future<void> _setEncoding(_FileRow row, TxtEncoding encoding) async {
    if (encoding == row.analysis.encoding && !row.isReading) return;
    final generation = ++row.generation;
    setState(() => row.isReading = true);
    try {
      final analysis = await widget.reanalyze(row.source, encoding);
      if (!mounted || generation != row.generation) return;
      setState(() {
        row.analysis = analysis;
        row.isReading = false;
      });
    } catch (_) {
      if (!mounted || generation != row.generation) return;
      // The previous decoding still stands; the label shows which one.
      setState(() => row.isReading = false);
    }
  }

  void _move(int index, int by) {
    setState(() => _rows.insert(index + by, _rows.removeAt(index)));
  }

  bool get _canConvert =>
      _title.text.trim().isNotEmpty &&
      _rows.every((row) => !row.isReading) &&
      _rows.any((row) => !row.analysis.isEmpty);

  void _confirm() {
    widget.onConfirm(
      TxtBookRequest(
        title: _title.text.trim(),
        author: _author.text.trim().isEmpty ? null : _author.text.trim(),
        findChapters: _findChapters,
        parts: [
          for (final row in _rows)
            if (!row.analysis.isEmpty)
              TxtPart(row.source, row.analysis.encoding),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _rows.fold<int>(
      0,
      (n, row) => n + row.analysis.chapterCount,
    );
    final several = _rows.length > 1;
    final l10n = context.l10n;
    // All of it scrolls, the buttons included: with the keyboard up for the
    // title, a short screen has less room than the fields alone take.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(label: l10n.makeBookFromTxt),
          const SizedBox(height: 8),
          Text(
            several
                ? l10n.txtFilesBecomeOneEpub(_rows.length)
                : l10n.txtFileBecomesEpub,
            style: AppTheme.caption,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('txt-title'),
            controller: _title,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: l10n.title),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('txt-author'),
            controller: _author,
            decoration: InputDecoration(labelText: l10n.authorOptional),
          ),
          const SizedBox(height: 16),
          SectionHeader(
            label: several ? l10n.files : l10n.file,
            trailing: Text(
              !_findChapters
                  ? l10n.splitByLength
                  : chapters == 0
                  ? l10n.noChaptersFound
                  : l10n.chapterCount(chapters),
              style: AppTheme.caption,
            ),
          ),
          for (var index = 0; index < _rows.length; index++)
            _FileTile(
              key: ObjectKey(_rows[index]),
              index: index,
              row: _rows[index],
              showOrder: several,
              findChapters: _findChapters,
              onEncoding: (encoding) => _setEncoding(_rows[index], encoding),
              onUp: index > 0 ? () => _move(index, -1) : null,
              onDown: index < _rows.length - 1 ? () => _move(index, 1) : null,
            ),
          // Nothing to turn off in a book with no chapters found; still
          // there once off, so it can be turned back on.
          if (chapters > 0 || !_findChapters)
            SwitchListTile(
              key: const ValueKey('txt-find-chapters'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.splitIntoChapters,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                l10n.splitIntoChaptersHint,
                style: AppTheme.caption,
              ),
              value: _findChapters,
              onChanged: (value) => setState(() => _findChapters = value),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onCancel,
                  child: Text(l10n.cancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _canConvert ? _confirm : null,
                  child: Text(
                    _rows.any((row) => row.isReading)
                        ? l10n.reading
                        : l10n.makeEpub,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final int index;
  final _FileRow row;
  final bool showOrder;
  final bool findChapters;
  final ValueChanged<TxtEncoding> onEncoding;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  const _FileTile({
    super.key,
    required this.index,
    required this.row,
    required this.showOrder,
    required this.findChapters,
    required this.onEncoding,
    required this.onUp,
    required this.onDown,
  });

  String _summary(AppLocalizations l10n) {
    final analysis = row.analysis;
    if (row.isReading) return l10n.reading;
    if (analysis.isEmpty) return l10n.noTextInEncoding;
    final characters = l10n.characterCount(_grouped(analysis.characterCount));
    if (!findChapters) return l10n.splitByLengthWithCharacters(characters);
    return analysis.chapterCount == 0
        ? l10n.noChapterHeadingsWithCharacters(characters)
        : l10n.chaptersWithCharacters(
            l10n.chapterCount(analysis.chapterCount),
            characters,
          );
  }

  static String _grouped(int n) =>
      n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: AppTheme.rule)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showOrder)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${index + 1}.',
                style: AppTheme.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.source.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(_summary(context.l10n), style: AppTheme.caption),
                const SizedBox(height: 6),
                // Where a wrong encoding shows: as nonsense.
                Text(
                  row.analysis.preview.join(' / '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body.copyWith(fontSize: 14),
                ),
                const SizedBox(height: 6),
                PopupMenuButton<TxtEncoding>(
                  tooltip: context.l10n.textEncoding,
                  popUpAnimationStyle: AnimationStyle.noAnimation,
                  onSelected: onEncoding,
                  itemBuilder: (_) => [
                    for (final encoding in TxtEncoding.values)
                      PopupMenuItem(
                        value: encoding,
                        child: Text(
                          encoding.label,
                          style: encoding == row.analysis.encoding
                              ? const TextStyle(fontWeight: FontWeight.w700)
                              : null,
                        ),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: const BoxDecoration(
                      border: Border.fromBorderSide(AppTheme.rule),
                      borderRadius: BorderRadius.all(
                        Radius.circular(AppTheme.radius),
                      ),
                    ),
                    child: Text(
                      context.l10n.encodingLabel(row.analysis.encoding.label),
                      style: AppTheme.caption.copyWith(color: AppTheme.ink),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showOrder)
            Column(
              children: [
                IconButton(
                  tooltip: context.l10n.moveUp,
                  onPressed: onUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: context.l10n.moveDown,
                  onPressed: onDown,
                  icon: const Icon(Icons.arrow_downward),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
