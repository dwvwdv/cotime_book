import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../services/layout_report_service.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

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

/// Sends a report built by [buildLayoutReport] with the reader's note.
///
/// The report itself is not shown: a page of JSON meant nothing to the reader,
/// and a copy of it pasted somewhere was one device's half of the problem.
/// What became of it is in Report History on Home instead.
///
/// [onSend] gets the reader's note and returns the stored report's id.
class LayoutReportSheet extends StatefulWidget {
  final Future<String> Function(String note) onSend;

  const LayoutReportSheet({super.key, required this.onSend});

  @override
  State<LayoutReportSheet> createState() => _LayoutReportSheetState();
}

class _LayoutReportSheetState extends State<LayoutReportSheet> {
  final _note = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _sent) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(_note.text);
      if (mounted) setState(() => _sent = true);
    } on LayoutReportRateLimitedException {
      if (mounted) {
        showPaperMessage(context, context.l10n.reportRateLimited);
      }
    } catch (_) {
      if (mounted) {
        showPaperMessage(context, context.l10n.reportSendFailed);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The whole sheet scrolls: on a landscape phone or a small e-reader the
    // note field and the button do not fit at once with the keyboard up (the
    // dialog it is shown in stops above it).
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.pageLayoutReportTitle, style: AppTheme.title),
          const SizedBox(height: 8),
          Text(context.l10n.pageLayoutReportIntro, style: AppTheme.caption),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            enabled: !_sent && !_sending,
            maxLines: 2,
            maxLength: 500,
            decoration: InputDecoration(hintText: context.l10n.reportNoteHint),
          ),
          const SizedBox(height: 16),
          if (_sent) ...[
            // Shown, not flashed in a message: it says where to look later.
            Text(
              context.l10n.reportSentToHistory,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
          ] else ...[
            ElevatedButton.icon(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send),
              // Words, not a spinner: e-ink.
              label: Text(
                _sending ? context.l10n.sending : context.l10n.sendReport,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
