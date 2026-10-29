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

    test('an answer that allowed no ads is asked again later', () async {
      final platform = FakeConsentPlatform()
        ..canRequest = false
        ..onUpdate = () async => throw Exception('offline');
      final consent = AdConsent(platform, retryAfter: Duration.zero);
      expect(await consent.gather(), isFalse);

      platform
        ..onUpdate = () async {}
        ..canRequest = true;
      expect(await consent.gather(), isTrue);
      expect(platform.updates, 2);
      expect(platform.forms, 1);

      // Once it allows ads, it is not asked again in this session.
      expect(await consent.gather(), isTrue);
      expect(platform.updates, 2);
    });

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
        expect(elsewhere.privacyOptionsRequired.value, isFalse);

        final platform = FakeConsentPlatform()..optionsRequired = true;
        final inEurope = AdConsent(platform);
        await inEurope.gather();
        expect(inEurope.privacyOptionsRequired.value, isTrue);

        platform.onPrivacyForm = () async => throw Exception('not shown');
        await inEurope.showPrivacyOptions();
        expect(platform.privacyForms, 1);
      },
    );
  });

  group('ad requests follow the consent (GH-58)', () {
    late int adMobCalls;
    late int sdkStarts;

    setUp(() {
      adMobCalls = 0;
      sdkStarts = 0;
      AdMobInterstitialAds.resetForTest();
      AdMobInterstitialAds.initializeSdk = () async => sdkStarts++;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('plugins.flutter.io/google_mobile_ads', (
            _,
          ) async {
            adMobCalls++;
            return null;
          });
    });

    tearDown(() {
      AdMobInterstitialAds.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('plugins.flutter.io/google_mobile_ads', null);
    });

    test('without consent AdMob is never asked for an ad', () async {
      final ads = AdMobInterstitialAds(adUnitId: 'ca-app-pub-0/0');

      await ads.start(AdConsent(FakeConsentPlatform()..canRequest = false));
      // The page an ad is due on: none is ready, which would load one.
      expect(await ads.show(), isFalse);
      ads.preload();
      await pumpEventQueue();

      expect(ads.isReady, isFalse);
      expect(sdkStarts, 0);
      expect(adMobCalls, 0);
    });

    test('consent that comes later in the session brings the ads, without '
        'a restart', () async {
      // Offline on the first start, or the message failed to show; or the
      // user says yes in Ad Privacy Choices later. E-readers keep the app
      // alive for days.
      final platform = FakeConsentPlatform()..canRequest = false;
      final consent = AdConsent(platform, retryAfter: Duration.zero);
      final ads = AdMobInterstitialAds(
        adUnitId: 'ca-app-pub-0/0',
        retryAfterFailure: Duration.zero,
      );
      await ads.start(consent);
      expect(sdkStarts, 0);

      platform.canRequest = true;
      ads.preload();
      await pumpEventQueue();

      expect(sdkStarts, 1);
      expect(adMobCalls, greaterThan(0));
    });

    test(
      'an answer withdrawn after the SDK started stops the requests',
      () async {
        final platform = FakeConsentPlatform();
        final ads = AdMobInterstitialAds(
          adUnitId: 'ca-app-pub-0/0',
          retryAfterFailure: Duration.zero,
        );
        await ads.start(AdConsent(platform));
        await pumpEventQueue();
        final asked = adMobCalls;
        expect(asked, greaterThan(0));

        // Changed in Ad Privacy Choices.
        platform.canRequest = false;
        ads.preload();
        await pumpEventQueue();

        expect(adMobCalls, asked);
      },
    );
  });
}
