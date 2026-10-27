import 'dart:async';

import 'package:cotime_book/models/announcement.dart';
import 'package:cotime_book/services/announcement_service.dart';
import 'package:cotime_book/widgets/announcement_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers each [list] call with the next queued result; a [Completer] stays
/// pending until the test completes it.
class FakeAnnouncements implements AnnouncementService {
  final List<Object> results;
  int calls = 0;

  FakeAnnouncements([List<Object>? results]) : results = results ?? [];

  @override
  Future<List<Announcement>> list() {
    calls++;
    final next = results.isEmpty ? const <Announcement>[] : results.removeAt(0);
    if (next is Completer<List<Announcement>>) return next.future;
    if (next is List<Announcement>) return Future.value(next);
    return Future.error(next);
  }
}

Announcement announcement(String title, {String content = '', int id = 1}) =>
    Announcement(
      id: id,
      title: title,
      content: content,
      publishedAt: DateTime(2026, 10, 27, 9),
    );

void main() {
  group('Announcement.fromRow', () {
    test('reads a row of the table', () {
      final parsed = Announcement.fromRow({
        'id': 3,
        'title': ' v1.0.18 ',
        'content': 'New:\r\n- News on the home screen\r\n',
        'published_at': '2026-10-27T01:00:00+00:00',
      })!;

      expect(parsed.id, 3);
      expect(parsed.title, 'v1.0.18');
      expect(parsed.content, 'New:\n- News on the home screen');
      expect(parsed.publishedAt.isUtc, isFalse);
    });

    test('the date is the day on this device\'s calendar', () {
      final parsed = announcement('Notes');
      expect(parsed.dateLabel, '2026-10-27');
    });

    test('a row that cannot be shown is left out, not an error', () {
      expect(
        Announcement.fromRow({
          'id': 1,
          'title': '  ',
          'published_at': '2026-10-27T01:00:00Z',
        }),
        isNull,
      );
      expect(Announcement.fromRow({'id': 1, 'title': 'No date'}), isNull);
    });

    test('an announcement without content is just its title', () {
      final parsed = Announcement.fromRow({
        'id': 1,
        'title': 'Short',
        'content': null,
        'published_at': '2026-10-27T01:00:00Z',
      })!;
      expect(parsed.content, '');
    });
  });

  test('the service keeps the rows it can show, in the order given', () async {
    final service = SupabaseAnnouncementService(
      readTable: () async => [
        {
          'id': 2,
          'title': 'Newer',
          'content': 'b',
          'published_at': '2026-10-27T00:00:00Z',
        },
        {'id': 9, 'title': '', 'published_at': '2026-10-26T00:00:00Z'},
        {
          'id': 1,
          'title': 'Older',
          'content': 'a',
          'published_at': '2026-10-20T00:00:00Z',
        },
      ],
    );

    final listed = await service.list();
    expect(listed.map((a) => a.title), ['Newer', 'Older']);
  });

  group('AnnouncementList', () {
    Future<void> pumpList(WidgetTester tester, AnnouncementService service) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AnnouncementList(announcements: service)),
          ),
        );

    testWidgets('shows each announcement with its date and text', (
      tester,
    ) async {
      final pending = Completer<List<Announcement>>();
      await pumpList(tester, FakeAnnouncements([pending]));

      // Words, not a spinner: e-ink.
      expect(find.text('Loading...'), findsOneWidget);

      pending.complete([
        announcement('v1.0.18', content: 'News on the home screen', id: 2),
        announcement('v1.0.17', id: 1),
      ]);
      await tester.pump();

      expect(find.text('Loading...'), findsNothing);
      expect(find.text('v1.0.18'), findsOneWidget);
      expect(find.text('News on the home screen'), findsOneWidget);
      expect(find.text('v1.0.17'), findsOneWidget);
      expect(find.text('2026-10-27'), findsNWidgets(2));
    });

    testWidgets('says so when there is nothing to read', (tester) async {
      await pumpList(tester, FakeAnnouncements([<Announcement>[]]));
      await tester.pump();

      expect(find.text('No announcements yet.'), findsOneWidget);
    });

    testWidgets('a failed load can be tried again', (tester) async {
      final service = FakeAnnouncements([
        StateError('offline'),
        [announcement('Back online')],
      ]);
      await pumpList(tester, service);
      await tester.pump();

      expect(
        find.text('The announcements could not be loaded.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Try Again'));
      await tester.pump();

      expect(service.calls, 2);
      expect(find.text('The announcements could not be loaded.'), findsNothing);
      expect(find.text('Back online'), findsOneWidget);
    });
  });
}
