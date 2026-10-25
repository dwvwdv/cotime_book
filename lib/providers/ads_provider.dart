import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/interstitial_ads.dart';

final interstitialAdsProvider = Provider<InterstitialAds>((ref) {
  if (!platformHasInterstitialAds) return const NoInterstitialAds();
  final ads = AdMobInterstitialAds.forPlatform();
  unawaited(ads.start());
  return ads;
});

final pageTurnAdCounterProvider = Provider<PageTurnAdCounter>(
  (ref) => PageTurnAdCounter(),
);
