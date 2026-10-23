import 'dart:convert';

import 'package:cotime_book/config/theme.dart';
import 'package:cotime_book/models/shared_page.dart';
import 'package:cotime_book/widgets/layout_report_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String report({Map<String, dynamic>? script}) => buildLayoutReport(
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
    script: script,
  );

  test('the report holds both sides of the page: the app and the viewer', () {
    final decoded =
        jsonDecode(report(script: {'scale': 1, 'problems': <String>[]}))
            as Map<String, dynamic>;

    expect(decoded['viewer'], [384, 654]);
    expect(decoded['roomPage'], 'SharedPage(384x649, 18px)');
    expect(decoded['lastLayoutProblems'], ['container 384x600']);
    expect(decoded['position'], {
      'epoch': 2,
      'seq': 41,
      'cfi': 'epubcfi(/6/24!/4/2/1:0)',
    });
    expect(decoded['script'], {'scale': 1, 'problems': <String>[]});
  });

  test('a viewer that could not be asked still gives the app\'s side', () {
    final decoded = jsonDecode(report()) as Map<String, dynamic>;

    expect(decoded['script'], 'unavailable');
    expect(decoded['layoutRepairs'], 1);
  });

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
    final text = report();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.paperTheme,
        home: Scaffold(body: LayoutReportSheet(report: text)),
      ),
    );
    await tester.tap(find.text('Copy Report'));
    await tester.pump();

    expect(copied, text);
    expect(find.text('Report copied'), findsOneWidget);
  });
}
