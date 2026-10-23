import 'dart:convert';
import 'dart:io';

import 'package:cotime_book/config/theme.dart';
import 'package:cotime_book/models/shared_page.dart';
import 'package:cotime_book/services/layout_report_service.dart';
import 'package:cotime_book/widgets/layout_report_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> report({Map<String, dynamic>? script}) =>
      buildLayoutReport(
        appVersion: '1.0.9+13',
        device: const {'platform': 'android'},
        book: const {'hash': 'abc', 'title': 'Moby-Dick', 'libraryPath': null},
        room: const {'isHost': false, 'textSizeLocked': true, 'textSize': 20},
        reading: const {'theme': 'day', 'ownFontSize': 18.0},
        viewer: const Size(384, 654),
        ownFit: const PageFit(width: 384, height: 654, fontSize: 18),
        roomPage: const SharedPage(width: 384, height: 649, fontSize: 18),
        appliedPage: const SharedPage(width: 384, height: 649, fontSize: 18),
        appliedViewer: const Size(384, 654),
        layoutRepairs: 1,
        lastLayoutProblems: const ['container 384x600'],
        epoch: 2,
        seq: 41,
        roomCfi: 'epubcfi(/6/24!/4/2/1:0)',
        localCfi: 'epubcfi(/6/24!/4/2/1:0)',
        recentMoves: const [
          {'ms': 1200, 'cfi': 'epubcfi(/6/24!/4/2/1:0)', 'by': 'turn'},
        ],
        script: script,
        at: DateTime.utc(2026, 10, 23, 8),
      );

  test('the report holds both sides of the page: the app and the viewer', () {
    // Round-tripped through JSON, as it is stored.
    final decoded =
        jsonDecode(
              jsonEncode(report(script: {'scale': 1, 'problems': <String>[]})),
            )
            as Map<String, dynamic>;

    expect(decoded['app'], '1.0.9+13');
    expect(decoded['at'], '2026-10-23T08:00:00.000Z');
    expect(decoded['viewer'], [384, 654]);
    expect(decoded['roomPage'], 'SharedPage(384x649, 18px)');
    expect(decoded['lastLayoutProblems'], ['container 384x600']);
    expect(decoded['position'], {
      'epoch': 2,
      'seq': 41,
      'cfi': 'epubcfi(/6/24!/4/2/1:0)',
    });
    expect(decoded['book']['title'], 'Moby-Dick');
    expect(decoded['room']['textSize'], 20);
    expect(decoded['recentMoves'].single['by'], 'turn');
    expect(decoded['script'], {'scale': 1, 'problems': <String>[]});
  });

  test('a viewer that could not be asked still gives the app\'s side', () {
    final decoded = report();

    expect(decoded['script'], 'unavailable');
    expect(decoded['layoutRepairs'], 1);
  });

  test('the readers in a report say what made the page, not who they are', () {
    final readers = layoutReportReaders(
      [
        {
          'user_id': 'user-a',
          'nickname': 'Alice',
          'is_reading': true,
          'reader_ready': true,
          'page_fit': {'w': 384, 'h': 600, 'font': 18},
          'protocol': 1,
          'protocol_min': 0,
        },
        {'user_id': 'user-b', 'nickname': 'Bob', 'is_reading': false},
      ],
      currentUserId: 'user-a',
      hostUserId: 'user-b',
    );

    expect(readers, [
      {
        'self': true,
        'host': false,
        'reading': true,
        'ready': true,
        'fit': {'w': 384, 'h': 600, 'font': 18},
        'protocol': 1,
        'protocolMin': 0,
      },
      {
        'self': false,
        'host': true,
        'reading': false,
        'ready': null,
        'fit': null,
        'protocol': null,
        'protocolMin': null,
      },
    ]);
    expect(jsonEncode(readers), isNot(contains('Alice')));
    expect(jsonEncode(readers), isNot(contains('user-')));
  });

  test('a report is small enough for the database to take', () {
    // layout_reports_report_shape caps a report at 64 KB.
    final big = report(
      script: {
        'views': [
          for (var i = 0; i < 3; i++)
            {'section': i, 'href': 'OEBPS/Text/chapter-$i.xhtml'},
        ],
        'errors': [for (var i = 0; i < 20; i++) 'TypeError: ${'x' * 200}'],
      },
    );
    expect(utf8.encode(jsonEncode(big)).length, lessThan(65536));
  });

  test('the app version comes from the pubspec it was built from', () async {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      appVersionFromPubspec(pubspec),
      matches(r'^\d+\.\d+\.\d+\+\d+$'),
      reason: 'the version line must stay readable by appVersionFromPubspec',
    );
    expect(
      appVersionFromPubspec('name: x\nversion: 1.2.3+4 # note\n'),
      '1.2.3+4',
    );
    expect(appVersionFromPubspec('name: x\n'), isNull);
    // Bundled, so the running app can read it.
    expect(await loadAppVersion(), appVersionFromPubspec(pubspec));
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    Future<String> Function(String note)? onSend,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.paperTheme,
        home: Scaffold(
          body: LayoutReportSheet(report: report(), onSend: onSend),
        ),
      ),
    );
  }

  testWidgets('the report can be copied in one tap', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpSheet(tester);
    await tester.tap(find.text('Copy Report'));
    await tester.pump();

    expect(copied, layoutReportText(report()));
    expect(find.text('Report copied'), findsOneWidget);
  });

  testWidgets('a sent report shows the id to quote', (tester) async {
    final notes = <String>[];
    await pumpSheet(
      tester,
      onSend: (note) async {
        notes.add(note);
        return '1a2b3c4d-0000-0000-0000-000000000000';
      },
    );

    await tester.enterText(find.byType(TextField), 'last line cut off');
    await tester.tap(find.text('Send Report'));
    await tester.pump();

    expect(notes, ['last line cut off']);
    expect(find.text('Sent. Report ID: 1a2b3c4d'), findsOneWidget);
    // Sent once: nothing left to tap that would send it again.
    expect(find.text('Send Report'), findsNothing);
  });

  testWidgets('a report that could not be sent can be sent again', (
    tester,
  ) async {
    var attempts = 0;
    await pumpSheet(
      tester,
      onSend: (_) async {
        attempts++;
        if (attempts == 1) throw Exception('offline');
        return '5e6f0000-0000-0000-0000-000000000000';
      },
    );

    await tester.tap(find.text('Send Report'));
    await tester.pump();
    expect(find.textContaining("Couldn't send the report"), findsOneWidget);

    await tester.tap(find.text('Send Report'));
    await tester.pump();
    expect(find.text('Sent. Report ID: 5e6f0000'), findsOneWidget);
  });

  testWidgets('too many reports says so instead of a generic failure', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      onSend: (_) async => throw const LayoutReportRateLimitedException(),
    );

    await tester.tap(find.text('Send Report'));
    await tester.pump();

    expect(find.textContaining('Too many reports'), findsOneWidget);
  });
}
