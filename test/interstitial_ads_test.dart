import 'dart:io';

import 'package:cotime_book/config/ad_config.dart';
import 'package:cotime_book/services/interstitial_ads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('without the ad SDK nothing is shown and nothing waits', () async {
    const ads = NoInterstitialAds();
    expect(ads.isReady, isFalse);
    expect(await ads.show(), isFalse);
  });

  test('pages and saving each have their own ad unit, from the same AdMob '
      'account as the app ID in the manifest', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final appId = RegExp(
      r'APPLICATION_ID"\s+android:value="ca-app-pub-(\d+)~\d+"',
    ).firstMatch(manifest);
    expect(appId, isNotNull);
    final unit = RegExp('^ca-app-pub-${appId!.group(1)}/\\d+\$');

    expect(AdConfig.pageTurnUnitId, matches(unit));
    expect(AdConfig.txtSaveUnitId, matches(unit));
    expect(AdConfig.pageTurnUnitId, isNot(AdConfig.txtSaveUnitId));
  });

  test('only release builds ask for real ads', () {
    expect(
      AdConfig.unitFor(AdConfig.pageTurnUnitId, isIOS: false, isRelease: true),
      AdConfig.pageTurnUnitId,
    );
    expect(
      AdConfig.unitFor(AdConfig.txtSaveUnitId, isIOS: false, isRelease: true),
      AdConfig.txtSaveUnitId,
    );
    expect(
      AdConfig.unitFor(AdConfig.pageTurnUnitId, isIOS: false, isRelease: false),
      AdConfig.androidTestUnitId,
    );
    // No iOS app in AdMob: iOS never asks for the Android units.
    expect(
      AdConfig.unitFor(AdConfig.pageTurnUnitId, isIOS: true, isRelease: true),
      AdConfig.iosTestUnitId,
    );
  });
}
