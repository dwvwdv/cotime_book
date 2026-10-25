import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/ad_config.dart';
import '../services/interstitial_ads.dart';

InterstitialAds _interstitialAds(String unitId) {
  if (!platformHasInterstitialAds) return const NoInterstitialAds();
  final ads = AdMobInterstitialAds.forPlatform(unitId);
  unawaited(ads.start());
  return ads;
}

/// Between pages in a room. Its own ad unit, so AdMob reports the two
/// placements apart.
final pageTurnAdsProvider = Provider<InterstitialAds>(
  (ref) => _interstitialAds(AdConfig.pageTurnUnitId),
);

/// Before a converted book is saved.
final txtSaveAdsProvider = Provider<InterstitialAds>(
  (ref) => _interstitialAds(AdConfig.txtSaveUnitId),
);

final pageTurnAdCounterProvider = Provider<PageTurnAdCounter>(
  (ref) => PageTurnAdCounter(),
);
