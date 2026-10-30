import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../models/layout_report_record.dart';
import '../providers/layout_report_history_provider.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

/// Opens Report History in a sheet.
Future<void> showLayoutReportHistory(BuildContext context) {
  return showPaperDialog<void>(
    context: context,
    builder: (sheetContext) => SizedBox(
      // A fixed height, so the sheet does not jump when the list comes back:
      // every resize is a refresh on e-ink.
      height: MediaQuery.of(sheetContext).size.height * 0.75,
      child: const LayoutReportHistoryList(),
    ),
  );
}

/// The reader's layout reports, newest first, with what became of each.
/// Reads them again when opened, and counts every answer it shows as seen.
class LayoutReportHistoryList extends ConsumerStatefulWidget {
  const LayoutReportHistoryList({super.key});

  @override
  ConsumerState<LayoutReportHistoryList> createState() =>
      _LayoutReportHistoryListState();
}

class _LayoutReportHistoryListState
    extends ConsumerState<LayoutReportHistoryList> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Not while the sheet is being built: reading changes the providers Home
    // is built from.
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final history = ref.read(layoutReportHistoryProvider.notifier);
    // What Home already has is on screen while the new list loads.
    await history.markAnswersSeen();
    await history.refresh();
    await history.markAnswersSeen();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(layoutReportHistoryProvider);
    final appVersion = ref.watch(appVersionProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.l10n.reportHistory, style: AppTheme.title),
        const SizedBox(height: 12),
        const Divider(thickness: AppTheme.heavyRuleWidth),
        Expanded(child: _buildBody(state, appVersion)),
      ],
    );
  }

  Widget _buildBody(LayoutReportHistoryState state, String? appVersion) {
    final reports = state.reports;
    if (reports == null || (reports.isEmpty && state.failed)) {
      if (state.failed && !_loading) {
        return ListView(
          padding: const EdgeInsets.only(top: 12),
          children: [
            PaperNotice(
              message: context.l10n.reportHistoryLoadFailed,
              icon: Icons.wifi_off,
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: Text(context.l10n.tryAgain)),
          ],
        );
      }
      // Text, not a spinner: e-ink.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(context.l10n.loading, style: AppTheme.body),
      );
    }
    if (reports.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(context.l10n.reportHistoryEmpty, style: AppTheme.body),
      );
    }
    return ListView.separated(
      itemCount: reports.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) =>
          _ReportEntry(report: reports[index], appVersion: appVersion),
    );
  }
}

class _ReportEntry extends StatelessWidget {
  final LayoutReportRecord report;
  final String? appVersion;

  const _ReportEntry({required this.report, required this.appVersion});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fixedIn = report.fixedIn;
    final appVersion = this.appVersion;
    final needsUpdate = appVersion != null && report.needsUpdate(appVersion);
    final status = switch (report.status) {
      LayoutReportStatus.open => l10n.reportStatusOpen,
      LayoutReportStatus.resolved => l10n.reportStatusResolved,
      LayoutReportStatus.declined => l10n.reportStatusDeclined,
    };
    final resolvedAt = report.resolvedAt;
    final note = report.note;
    final resolutionNote = report.resolutionNote;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  report.bookTitle ?? l10n.reportUnknownBook,
                  style: AppTheme.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              _StatusLabel(label: status, settled: report.isSettled),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.reportSentAt(reportTimeLabel(report.sentAt)),
            style: AppTheme.caption,
          ),
          if (resolvedAt != null)
            Text(
              l10n.reportHandledAt(reportTimeLabel(resolvedAt)),
              style: AppTheme.caption,
            ),
          if (fixedIn != null) ...[
            const SizedBox(height: 8),
            // The reader still on an older release is told what to do, not
            // that it is solved: the bug is still on their screen.
            Text(
              needsUpdate
                  ? l10n.reportUpdateForFix(fixedIn)
                  : l10n.reportFixedIn(fixedIn),
              style: AppTheme.body.copyWith(
                fontWeight: needsUpdate ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
          if (resolutionNote != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              resolutionNote,
              style: AppTheme.body.copyWith(height: 1.5),
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(l10n.reportYourNote(note), style: AppTheme.caption),
          ],
        ],
      ),
    );
  }
}

/// The status as words in a box: filled once answered, outlined while
/// pending. Not by colour (e-ink).
class _StatusLabel extends StatelessWidget {
  final String label;
  final bool settled;

  const _StatusLabel({required this.label, required this.settled});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: settled ? AppTheme.ink : null,
        border: Border.all(color: AppTheme.ink, width: 1.5),
      ),
      child: Text(
        label,
        style: AppTheme.caption.copyWith(
          color: settled ? AppTheme.paper : AppTheme.ink,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
