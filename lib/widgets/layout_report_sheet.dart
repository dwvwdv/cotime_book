import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/theme.dart';
import '../services/layout_report_service.dart';
import 'paper.dart';

/// The reader's page layout, for a bug report from a real device.
///
/// Cut-off pages and turns that skip ahead only ever showed up in an Android
/// WebView (GH-49), where nobody can attach a debugger. The report is sent to
/// the database (`cotime_book_private.layout_reports`), so its keys are what
/// maintainers query: rename one and the old reports no longer line up.
///
/// It is meant to be enough to rebuild the page without asking the reader
/// anything: which device and WebView ([device], [script]'s `userAgent`),
/// which book ([book]; a library book can be laid out again in
/// `tool/shared_page_check`), every reader's fit that made the room's page
/// ([room]), what this screen did with it, and how the viewer moved just
/// before ([recentMoves]). The room id that goes with it pairs the reports of
/// two readers of the same room. It never holds the book's text, nicknames
/// or user ids.
///
/// [script] is what the viewer's `cotimeSharedPage.diagnose()` returned, null
/// when it could not be asked.
Map<String, dynamic> buildLayoutReport({
  required String appVersion,
  required Map<String, dynamic> device,
  required Map<String, dynamic> book,
  required Map<String, dynamic> room,
  required Map<String, dynamic> reading,
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
  required List<Map<String, dynamic>> recentMoves,
  required Map<String, dynamic>? script,
  DateTime? at,
}) {
  return {
    'app': appVersion,
    'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
    'device': device,
    'book': book,
    'room': room,
    'reading': reading,
    'viewer': _size(viewer),
    'ownFit': ownFit?.toString(),
    'roomPage': roomPage?.toString(),
    'appliedPage': appliedPage?.toString(),
    'appliedViewer': _size(appliedViewer),
    'layoutRepairs': layoutRepairs,
    'lastLayoutProblems': lastLayoutProblems,
    'position': {'epoch': epoch, 'seq': seq, 'cfi': roomCfi},
    'localCfi': localCfi,
    'recentMoves': recentMoves,
    'script': script ?? 'unavailable',
  };
}

List<double>? _size(Size? s) => s == null ? null : [s.width, s.height];

/// The screen as Flutter sees it. The WebView's side of the same screen is in
/// the script's part of the report; a mismatch between the two is a lead.
Map<String, dynamic> layoutReportDevice(MediaQueryData media) {
  final padding = media.viewPadding;
  return {
    'platform': defaultTargetPlatform.name,
    'screen': _size(media.size),
    'devicePixelRatio': media.devicePixelRatio,
    'textScale': media.textScaler.scale(1),
    'viewPadding': [padding.left, padding.top, padding.right, padding.bottom],
    'orientation': media.orientation.name,
  };
}

/// Every reader's part in the room's page, without who they are. [self] marks
/// this device's own row.
///
/// [onlineUsers] are merged Presence rows (`mergePresenceUsers`): one per
/// person, with every device's protocol range in `protocols` and their fits
/// already combined, which is what the room's page was made from.
List<Map<String, dynamic>> layoutReportReaders(
  List<Map<String, dynamic>> onlineUsers, {
  required String? currentUserId,
  required String? hostUserId,
}) {
  return [
    for (final user in onlineUsers)
      {
        'self': user['user_id'] == currentUserId,
        'host': user['user_id'] == hostUserId,
        'reading': user['is_reading'],
        'ready': user['reader_ready'],
        'fit': user['page_fit'],
        'protocols': user['protocols'],
        'sessions': user['session_count'],
      },
  ];
}

String layoutReportText(Map<String, dynamic> report) =>
    const JsonEncoder.withIndent('  ').convert(report);

/// Shows [report] with a button that sends it and one that copies it.
///
/// [onSend] gets the reader's note and returns the stored report's id, which
/// the reader can quote in an issue.
class LayoutReportSheet extends StatefulWidget {
  final Map<String, dynamic> report;
  final Future<String> Function(String note)? onSend;

  const LayoutReportSheet({super.key, required this.report, this.onSend});

  @override
  State<LayoutReportSheet> createState() => _LayoutReportSheetState();
}

class _LayoutReportSheetState extends State<LayoutReportSheet> {
  final _note = TextEditingController();
  late final String _text = layoutReportText(widget.report);
  bool _sending = false;
  String? _sentId;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final onSend = widget.onSend;
    if (onSend == null || _sending || _sentId != null) return;
    setState(() => _sending = true);
    try {
      final id = await onSend(_note.text);
      if (mounted) setState(() => _sentId = id);
    } on LayoutReportRateLimitedException {
      if (mounted) {
        showPaperMessage(
          context,
          'Too many reports in the last hour. Copy this one instead.',
        );
      }
    } catch (_) {
      if (mounted) {
        showPaperMessage(
          context,
          "Couldn't send the report. Try again, or copy it instead.",
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sentId = _sentId;
    // The whole sheet scrolls, and stops above the keyboard: on a landscape
    // phone or a small e-reader the note field, the report and both buttons
    // do not fit at once, least of all with the keyboard up.
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Page layout report', style: AppTheme.title),
          const SizedBox(height: 8),
          const Text(
            'If pages are cut off or a turn skips ahead, send this right after '
            'it happens. It holds how this screen laid out the page and where '
            'you are in the book, never the book\'s text.',
            style: AppTheme.caption,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            enabled: sentId == null && !_sending,
            maxLines: 2,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: 'What went wrong? (optional)',
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: Container(
              decoration: BoxDecoration(border: Border.all(width: 1.5)),
              padding: const EdgeInsets.all(10),
              child: SingleChildScrollView(
                child: SelectableText(
                  _text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (sentId != null) ...[
            // The id is the reader's handle on the report, so it is shown, not
            // flashed in a message.
            SelectableText(
              'Sent. Report ID: ${sentId.split('-').first}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
          ] else if (widget.onSend != null) ...[
            ElevatedButton.icon(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send),
              // Words, not a spinner: e-ink.
              label: Text(_sending ? 'Sending...' : 'Send Report'),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _text));
              if (context.mounted) showPaperMessage(context, 'Report copied');
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy Report'),
          ),
        ],
      ),
    );
  }
}
