import 'dart:async';

import 'package:cotime_book/config/theme.dart';
import 'package:cotime_book/l10n/l10n.dart';
import 'package:cotime_book/models/layout_report_record.dart';
import 'package:cotime_book/providers/layout_report_history_provider.dart';
import 'package:cotime_book/providers/local_store_provider.dart';
import 'package:cotime_book/services/layout_report_service.dart';
import 'package:cotime_book/services/local_store.dart';
import 'package:cotime_book/widgets/layout_report_history_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers each read with the next of [results]: a list of reports, a
/// [Completer] for one still on its way, or anything else as an error.
class FakeReportHistory implements LayoutReportHistory {
  final List<Object> results;
  int calls = 0;

  FakeReportHistory([List<Object>? results]) : results = results ?? [];

  @override
  Future<List<LayoutReportRecord>> list() {
    calls++;
    final next = results.isEmpty
        ? (_last ?? const <LayoutReportRecord>[])
        : results.removeAt(0);
    if (next is Completer<List<LayoutReportRecord>>) return next.future;
    if (next is List<LayoutReportRecord>) {
      _last = next;
      return Future.value(next);
    }
    return Future.error(next);
  }

  /// Read again with nothing new queued, the server says the same.
  List<LayoutReportRecord>? _last;
}

LayoutReportRecord reportRecord({
  String id = 'r1',
  String? bookTitle = '少年實用機械',
  LayoutReportStatus status = LayoutReportStatus.open,
  DateTime? resolvedAt,
  String? fixedIn,
  String? resolutionNote,
  String? note,
}) => LayoutReportRecord(
  id: id,
  sentAt: DateTime(2026, 10, 29, 16, 53),
  bookTitle: bookTitle,
  status: status,
  resolvedAt:
      resolvedAt ??
      (status == LayoutReportStatus.open ? null : DateTime(2026, 10, 30, 9, 5)),
  fixedIn: fixedIn,
  resolutionNote: resolutionNote,
  note: note,
);

void main() {
  group('a report row', () {
    test('reads what the server sends', () {
      final report = LayoutReportRecord.fromRow({
        'id': 'ae589eae-cff8-41f0-a209-136d7332b08e',
        'created_at': '2026-10-29T16:53:56.392396+00:00',
        'book_title': '少年實用機械',
        'note': '上下頁切換異常耗時',
        'status': 'resolved',
        'resolved_at': '2026-10-30T02:00:00+00:00',
        'fixed_in': '1.0.28',
        'resolution_note': '已修正\r\nFixed',
      })!;

      expect(report.status, LayoutReportStatus.resolved);
      expect(report.bookTitle, '少年實用機械');
      expect(report.fixedIn, '1.0.28');
      expect(report.resolutionNote, '已修正\nFixed');
      expect(report.isSettled, isTrue);
    });

    test('a status from a later release still lists the report', () {
      final report = LayoutReportRecord.fromRow({
        'id': 'r1',
        'created_at': '2026-10-29T16:53:56Z',
        'status': 'in_progress',
      })!;

      expect(report.status, LayoutReportStatus.open);
      expect(report.bookTitle, isNull);
    });

    test('a row without an id or a time is left out, not the list', () async {
      expect(LayoutReportRecord.fromRow({'created_at': 'x'}), isNull);
      final history = SupabaseLayoutReportHistory(
        call: () async => [
          {'id': 'r1', 'created_at': '2026-10-29T16:53:56Z', 'status': 'open'},
          {'id': 'r2'},
          'not a row',
        ],
      );

      expect([for (final r in await history.list()) r.id], ['r1']);
    });

    test('a fix in a later release asks this app to update', () {
      final fixed = reportRecord(
        status: LayoutReportStatus.resolved,
        fixedIn: '1.0.28',
      );

      expect(fixed.needsUpdate('1.0.27+31'), isTrue);
      expect(fixed.needsUpdate('1.0.28+32'), isFalse);
      expect(fixed.needsUpdate('1.1.0+40'), isFalse);
      // Version numbers, not text: 1.0.9 is older than 1.0.28.
      expect(
        reportRecord(
          status: LayoutReportStatus.resolved,
          fixedIn: '1.0.10',
        ).needsUpdate('1.0.9+13'),
        isTrue,
      );
      expect(fixed.needsUpdate('unknown'), isFalse);
      expect(reportRecord().needsUpdate('1.0.1+1'), isFalse);
    });
  });

  group('answers on Home', () {
    late LocalStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
    });

    LayoutReportHistoryNotifier notifier(FakeReportHistory history) =>
        LayoutReportHistoryNotifier(history, store);

    test('an answer is news until Report History has shown it', () async {
      final history = notifier(
        FakeReportHistory([
          [
            reportRecord(id: 'a', status: LayoutReportStatus.resolved),
            reportRecord(id: 'b', status: LayoutReportStatus.declined),
            reportRecord(id: 'c'),
          ],
        ]),
      );
      await history.refresh();
      expect(history.state.unseenAnswers, 2);

      await history.markAnswersSeen();
      expect(history.state.unseenAnswers, 0);
      // Remembered the next time the app opens.
      expect(notifier(FakeReportHistory()).state.seenAnswers, hasLength(2));
    });

    test('a report reopened and answered again is news again', () async {
      final history = notifier(
        FakeReportHistory([
          [
            reportRecord(
              id: 'a',
              status: LayoutReportStatus.declined,
              resolvedAt: DateTime(2026, 10, 30),
            ),
          ],
          [
            reportRecord(
              id: 'a',
              status: LayoutReportStatus.resolved,
              resolvedAt: DateTime(2026, 11, 2),
            ),
          ],
        ]),
      );
      await history.refresh();
      await history.markAnswersSeen();

      await history.refresh();

      expect(history.state.unseenAnswers, 1);
    });

    test('a failed read keeps the reports Home already has', () async {
      final history = notifier(
        FakeReportHistory([
          [reportRecord()],
          Exception('offline'),
        ]),
      );
      await history.refresh();
      await history.refresh();

      expect(history.state.reports, hasLength(1));
      expect(history.state.failed, isTrue);
    });

    test('a slow read does not overwrite the one after it', () async {
      final slow = Completer<List<LayoutReportRecord>>();
      final history = notifier(
        FakeReportHistory([
          slow,
          [reportRecord(id: 'new')],
        ]),
      );
      final first = history.refresh();
      await history.refresh();
      slow.complete([reportRecord(id: 'old')]);
      await first;

      expect([for (final r in history.state.reports!) r.id], ['new']);
    });
  });

  group('Report History', () {
    late LocalStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
    });

    Future<ProviderContainer> pumpHistory(
      WidgetTester tester,
      FakeReportHistory history, {
      String appVersion = '1.0.27+31',
    }) async {
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          layoutReportHistoryServiceProvider.overrideWithValue(history),
          appVersionProvider.overrideWith((ref) async => appVersion),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.paperTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: appLocales,
            home: const Scaffold(body: LayoutReportHistoryList()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('lists each report with the book, its status and the times', (
      tester,
    ) async {
      await pumpHistory(
        tester,
        FakeReportHistory([
          [
            reportRecord(id: 'b', note: 'turns take forever'),
            reportRecord(
              id: 'a',
              bookTitle: null,
              status: LayoutReportStatus.declined,
              resolutionNote: '無法重現 / Could not reproduce',
            ),
          ],
        ]),
      );

      expect(find.text('少年實用機械'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Sent 2026-10-29 16:53'), findsNWidgets(2));
      expect(find.text('Your note: turns take forever'), findsOneWidget);

      expect(find.text('Book not recorded'), findsOneWidget);
      expect(find.text('Not fixed'), findsOneWidget);
      expect(find.text('Handled 2026-10-30 09:05'), findsOneWidget);
      expect(find.text('無法重現 / Could not reproduce'), findsOneWidget);
    });

    testWidgets('a fix this app does not have yet says to update', (
      tester,
    ) async {
      await pumpHistory(
        tester,
        FakeReportHistory([
          [
            reportRecord(
              status: LayoutReportStatus.resolved,
              fixedIn: '1.0.28',
            ),
          ],
        ]),
      );

      expect(find.text('Resolved'), findsOneWidget);
      expect(
        find.text('Fixed in 1.0.28. Update the app to get the fix.'),
        findsOneWidget,
      );
    });

    testWidgets('a fix this app has is just fixed', (tester) async {
      await pumpHistory(
        tester,
        FakeReportHistory([
          [
            reportRecord(
              status: LayoutReportStatus.resolved,
              fixedIn: '1.0.28',
            ),
          ],
        ]),
        appVersion: '1.0.28+32',
      );

      expect(find.text('Fixed in 1.0.28'), findsOneWidget);
      expect(find.textContaining('Update the app'), findsNothing);
    });

    testWidgets('opening it counts its answers as seen', (tester) async {
      final container = await pumpHistory(
        tester,
        FakeReportHistory([
          [reportRecord(status: LayoutReportStatus.resolved)],
        ]),
      );

      expect(container.read(layoutReportHistoryProvider).unseenAnswers, 0);
    });

    testWidgets(
      'closed before the read came back, its answers are still news',
      (tester) async {
        final slow = Completer<List<LayoutReportRecord>>();
        final container = await pumpHistory(tester, FakeReportHistory([slow]));
        await tester.pumpWidget(const SizedBox());

        slow.complete([reportRecord(status: LayoutReportStatus.resolved)]);
        await tester.pumpAndSettle();

        expect(container.read(layoutReportHistoryProvider).unseenAnswers, 1);
      },
    );

    testWidgets('a failed read can be tried again', (tester) async {
      await pumpHistory(
        tester,
        FakeReportHistory([
          Exception('offline'),
          [reportRecord()],
        ]),
      );
      expect(find.textContaining("Couldn't load your reports"), findsOneWidget);

      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();

      expect(find.text('少年實用機械'), findsOneWidget);
    });
  });
}
