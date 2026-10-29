import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import '../config/theme.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

/// The book's table of contents, nested chapters indented under their part.
/// Where a TXT conversion that took prose for headings shows first.
class BookContents extends StatelessWidget {
  final List<EpubChapter> chapters;
  final ValueChanged<String> onOpen;

  const BookContents({super.key, required this.chapters, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final rows = <(EpubChapter, int)>[];
    void add(List<EpubChapter> items, int depth) {
      for (final chapter in items) {
        rows.add((chapter, depth));
        add(chapter.subitems, depth + 1);
      }
    }

    add(chapters, 0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          label: context.l10n.contents,
          trailing: Text(
            context.l10n.contentsEntries(rows.length),
            style: AppTheme.caption,
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(context.l10n.noContents, style: AppTheme.caption),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final (chapter, depth) = rows[index];
                final title = chapter.title.trim();
                return InkWell(
                  onTap: () => onOpen(chapter.href),
                  child: Container(
                    padding: EdgeInsets.fromLTRB(16.0 * depth, 12, 0, 12),
                    decoration: const BoxDecoration(
                      border: Border(bottom: AppTheme.rule),
                    ),
                    child: Text(
                      title.isEmpty ? context.l10n.untitled : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
