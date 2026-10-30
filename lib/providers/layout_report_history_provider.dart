import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/layout_report_record.dart';
import '../services/layout_report_service.dart';
import '../services/local_store.dart';
import 'local_store_provider.dart';

final layoutReportHistoryServiceProvider = Provider<LayoutReportHistory>((ref) {
  return SupabaseLayoutReportHistory();
});

/// The version this app was built from, to tell a reader whose fix is in a
/// later release to update.
final appVersionProvider = FutureProvider<String>((ref) => loadAppVersion());

final layoutReportHistoryProvider =
    StateNotifierProvider<
      LayoutReportHistoryNotifier,
      LayoutReportHistoryState
    >(
      (ref) => LayoutReportHistoryNotifier(
        ref.read(layoutReportHistoryServiceProvider),
        ref.read(localStoreProvider),
      ),
    );

class LayoutReportHistoryState {
  /// Null until the first read comes back.
  final List<LayoutReportRecord>? reports;

  /// The last read failed. The reports from before it, if any, stay.
  final bool failed;
  final Set<String> seenAnswers;

  const LayoutReportHistoryState({
    this.reports,
    this.failed = false,
    this.seenAnswers = const {},
  });

  bool get hasReports => reports?.isNotEmpty ?? false;

  /// Answers the reader has not opened Report History to see yet.
  int get unseenAnswers => [
    for (final report in reports ?? const <LayoutReportRecord>[])
      if (report.isSettled && !seenAnswers.contains(report.answerKey)) report,
  ].length;
}

class LayoutReportHistoryNotifier
    extends StateNotifier<LayoutReportHistoryState> {
  final LayoutReportHistory _history;
  final LocalStore _store;

  /// A read must not be overwritten by a slower one it replaced.
  int _readGeneration = 0;

  LayoutReportHistoryNotifier(this._history, LocalStore store)
    : _store = store,
      super(LayoutReportHistoryState(seenAnswers: store.seenReportAnswers));

  Future<void> refresh() async {
    final generation = ++_readGeneration;
    try {
      final reports = await _history.list();
      if (!mounted || generation != _readGeneration) return;
      state = LayoutReportHistoryState(
        reports: reports,
        seenAnswers: state.seenAnswers,
      );
    } catch (error) {
      debugPrint('Unable to load the layout report history: $error');
      if (!mounted || generation != _readGeneration) return;
      // The list Home already shows is still the best it has.
      state = LayoutReportHistoryState(
        reports: state.reports,
        failed: true,
        seenAnswers: state.seenAnswers,
      );
    }
  }

  /// Every answer in the list has been on the reader's screen. Only those:
  /// the set never outgrows the history.
  Future<void> markAnswersSeen() async {
    final reports = state.reports;
    if (reports == null) return;
    final seen = {
      for (final report in reports)
        if (report.isSettled) report.answerKey,
    };
    if (setEquals(seen, state.seenAnswers)) return;
    state = LayoutReportHistoryState(
      reports: reports,
      failed: state.failed,
      seenAnswers: seen,
    );
    await _store.saveSeenReportAnswers(seen);
  }
}
