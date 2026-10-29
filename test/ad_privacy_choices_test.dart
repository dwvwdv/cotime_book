import 'package:cotime_book/providers/ads_provider.dart';
import 'package:cotime_book/providers/txt_convert_provider.dart';
import 'package:cotime_book/screens/txt_convert_screen.dart';
import 'package:cotime_book/services/ad_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ad_consent_test.dart' show FakeConsentPlatform;

void main() {
  // Saving a converted book shows an ad, so the consent behind it has to be
  // changeable there too, not only from a room's reading settings (GH-58).
  Future<void> pumpTxtTool(WidgetTester tester, AdConsent? consent) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adConsentProvider.overrideWithValue(consent),
          txtConvertProvider.overrideWith(
            (ref) => TxtConvertNotifier(
              directory: () async => throw UnimplementedError(),
              export: (fileName, bytes) async => null,
            ),
          ),
        ],
        child: const MaterialApp(home: TxtConvertScreen()),
      ),
    );
  }

  testWidgets('the TXT tool offers ad privacy choices where Google requires '
      'them, once consent has been asked', (tester) async {
    final platform = FakeConsentPlatform()..optionsRequired = true;
    final consent = AdConsent(platform);
    await pumpTxtTool(tester, consent);
    expect(find.text('Ad Privacy Choices'), findsNothing);

    // Asked on start, possibly after the screen was built.
    await tester.runAsync(consent.gather);
    await tester.pump();
    await tester.tap(find.text('Ad Privacy Choices'));
    await tester.runAsync(() async {});

    expect(platform.privacyForms, 1);
  });

  testWidgets('nothing about ad privacy where Google does not require it', (
    tester,
  ) async {
    final consent = AdConsent(FakeConsentPlatform());
    await pumpTxtTool(tester, consent);
    await tester.runAsync(consent.gather);
    await tester.pump();

    expect(find.text('Ad Privacy Choices'), findsNothing);
  });

  testWidgets('nothing about ad privacy without ads', (tester) async {
    await pumpTxtTool(tester, null);

    expect(find.text('Ad Privacy Choices'), findsNothing);
  });
}
