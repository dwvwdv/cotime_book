import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/ad_config.dart';
import '../services/ad_consent.dart';
import '../services/interstitial_ads.dart';

/// Consent for the ads (GH-58), asked once per start and shared by every
/// placement. Null where there are no ads.
final adConsentProvider = Provider<AdConsent?>(
  (ref) => platformHasInterstitialAds
      ? AdConsent(const GoogleConsentPlatform())
      : null,
);

InterstitialAds _interstitialAds(Ref ref, String unitId) {
  final consent = ref.read(adConsentProvider);
  if (consent == null) return const NoInterstitialAds();
  final ads = AdMobInterstitialAds.forPlatform(unitId);
  unawaited(ads.start(consent));
  return ads;
}

/// Between pages in a room. Its own ad unit, so AdMob reports the two
/// placements apart.
final pageTurnAdsProvider = Provider<InterstitialAds>(
  (ref) => _interstitialAds(ref, AdConfig.pageTurnUnitId),
);

/// Before a converted book is saved.
final txtSaveAdsProvider = Provider<InterstitialAds>(
  (ref) => _interstitialAds(ref, AdConfig.txtSaveUnitId),
);
