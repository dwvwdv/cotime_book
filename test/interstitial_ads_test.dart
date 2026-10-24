import 'package:cotime_book/config/ad_config.dart';
import 'package:cotime_book/services/interstitial_ads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an ad is due after every twenty page moves', () {
    final counter = PageTurnAdCounter();
    expect(counter.every, AdConfig.pageTurnsPerAd);
    expect(AdConfig.pageTurnsPerAd, 20);

    for (var i = 0; i < 19; i++) {
      counter.recordMove();
    }
    expect(counter.isDue, isFalse);
    counter.recordMove();
    expect(counter.isDue, isTrue);

    counter.adShown();
    expect(counter.isDue, isFalse);
    for (var i = 0; i < 20; i++) {
      counter.recordMove();
    }
    expect(counter.isDue, isTrue);
  });

  test('an ad that was not ready stays due for a later page', () {
    final counter = PageTurnAdCounter(every: 3);
    for (var i = 0; i < 3; i++) {
      counter.recordMove();
    }
    // Nothing shown: the next page tries again rather than waiting for
    // another three.
    counter.recordMove();
    expect(counter.isDue, isTrue);
  });

  test('without the ad SDK nothing is shown and nothing waits', () async {
    expect(await const NoInterstitialAds().show(), isFalse);
  });

  test('the ad IDs are AdMob IDs for this platform', () {
    final unit = RegExp(r'^ca-app-pub-\d+/\d+$');
    expect(AdConfig.androidInterstitialUnitId, matches(unit));
    expect(AdConfig.iosInterstitialUnitId, matches(unit));
  });
}
