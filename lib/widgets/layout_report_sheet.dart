import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/theme.dart';
import 'paper.dart';

/// The reader's page layout as text, for a bug report from a real device.
///
/// Cut-off pages and turns that skip ahead only ever showed up in an Android
/// WebView (GH-49), where nobody can attach a debugger: the reader copies this
/// and pastes it into the issue instead. [script] is what the viewer's
/// `cotimeSharedPage.diagnose()` returned, null when it could not be asked.
String buildLayoutReport({
  required Size? viewer,
  required Object? ownFit,
  required Object? roomPage,
  required Object? appliedPage,
  required Size? appliedViewer,
  required int layoutRepairs,
  required List<String> lastLayoutProblems,
  required int? epoch,
  required int? seq,
  required String? roomCfi,
  required String? localCfi,
  required Map<String, dynamic>? script,
}) {
  List<double>? size(Size? s) => s == null ? null : [s.width, s.height];
  return const JsonEncoder.withIndent('  ').convert({
    'viewer': size(viewer),
    'ownFit': ownFit?.toString(),
    'roomPage': roomPage?.toString(),
    'appliedPage': appliedPage?.toString(),
    'appliedViewer': size(appliedViewer),
    'layoutRepairs': layoutRepairs,
    'lastLayoutProblems': lastLayoutProblems,
    'position': {'epoch': epoch, 'seq': seq, 'cfi': roomCfi},
    'localCfi': localCfi,
    'script': script ?? 'unavailable',
  });
}

/// Shows [report] with a button that copies it.
class LayoutReportSheet extends StatelessWidget {
  final String report;

  const LayoutReportSheet({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Page layout report', style: AppTheme.title),
        const SizedBox(height: 8),
        const Text(
          'If pages are cut off or a turn skips ahead, copy this right after '
          'it happens and paste it into the bug report.',
          style: AppTheme.caption,
        ),
        const SizedBox(height: 12),
        Flexible(
          child: Container(
            decoration: BoxDecoration(border: Border.all(width: 1.5)),
            padding: const EdgeInsets.all(10),
            child: SingleChildScrollView(
              child: SelectableText(
                report,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (context.mounted) showPaperMessage(context, 'Report copied');
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy Report'),
        ),
      ],
    );
  }
}
