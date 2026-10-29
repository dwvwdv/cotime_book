import 'dart:async';

import 'package:cotime_book/services/ad_consent.dart';
import 'package:cotime_book/services/interstitial_ads.dart';
import 'package:flutter_test/flutter_test.dart';

/// Google's consent SDK as each case needs it to answer.
class FakeConsentPlatform implements ConsentPlatform {
  Future<void> Function() onUpdate = () async {};
  Future<void> Function() onForm = () async {};
  Future<void> Function() onPrivacyForm = () async {};
  bool canRequest = true;
  bool optionsRequired = false;

  int updates = 0;
  int forms = 0;
  int privacyForms = 0;

  @override
  Future<void> requestUpdate() {
    updates++;
    return onUpdate();
  }

  @override
  Future<void> showFormIfRequired() {
    forms++;
    return onForm();
  }

  @override
  Future<bool> canRequestAds() async => canRequest;

  @override
  Future<bool> privacyOptionsRequired() async => optionsRequired;

  @override
  Future<void> showPrivacyOptionsForm() {
    privacyForms++;
    return onPrivacyForm();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ad consent (GH-58)', () {
    test(
      'asks Google, shows its message when needed, then allows ads',
      () async {
        final platform = FakeConsentPlatform();
        final consent = AdConsent(platform);

        expect(await consent.gather(), isTrue);
        expect(platform.updates, 1);
        expect(platform.forms, 1);
      },
    );

    test(
      'no ads while the message is unanswered or could not be shown',
      () async {
        final platform = FakeConsentPlatform()
          ..canRequest = false
          ..onForm = () async => throw Exception('form failed to load');
        final consent = AdConsent(platform);

        expect(await consent.gather(), isFalse);
      },
    );

    test('a failed request goes by the answer given before, without the '
        'message', () async {
      final platform = FakeConsentPlatform()
        ..onUpdate = () async => throw Exception('offline');
      final consent = AdConsent(platform);

      expect(await consent.gather(), isTrue);
      expect(platform.forms, 0);
    });

    test(
      'a request that never answers does not hold the ads back for good',
      () async {
        final platform = FakeConsentPlatform()
          ..onUpdate = () => Completer<void>().future;
        final consent = AdConsent(
          platform,
          updateTimeout: const Duration(milliseconds: 10),
        );

        expect(await consent.gather(), isTrue);
        expect(platform.forms, 0);
      },
    );

    test(
      'every placement shares one answer: the message is shown once',
      () async {
        final platform = FakeConsentPlatform();
        final consent = AdConsent(platform);

        final answers = await Future.wait([consent.gather(), consent.gather()]);

        expect(answers, [isTrue, isTrue]);
        expect(platform.updates, 1);
        expect(platform.forms, 1);
      },
    );

    test(
      'privacy choices are offered only where Google requires them',
      () async {
        final elsewhere = AdConsent(FakeConsentPlatform());
        await elsewhere.gather();
        expect(elsewhere.privacyOptionsRequired, isFalse);

        final platform = FakeConsentPlatform()..optionsRequired = true;
        final inEurope = AdConsent(platform);
        await inEurope.gather();
        expect(inEurope.privacyOptionsRequired, isTrue);

        platform.onPrivacyForm = () async => throw Exception('not shown');
        await inEurope.showPrivacyOptions();
        expect(platform.privacyForms, 1);
      },
    );
  });

  test('without consent AdMob is never asked for an ad (GH-58)', () async {
    var adMobCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('plugins.flutter.io/google_mobile_ads', (
          _,
        ) async {
          adMobCalls++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('plugins.flutter.io/google_mobile_ads', null),
    );
    final ads = AdMobInterstitialAds(adUnitId: 'ca-app-pub-0/0');

    await ads.start(AdConsent(FakeConsentPlatform()..canRequest = false));
    // The page an ad is due on: none is ready, which would load one.
    expect(await ads.show(), isFalse);
    ads.preload();

    expect(ads.isReady, isFalse);
    expect(adMobCalls, 0);
  });
}
