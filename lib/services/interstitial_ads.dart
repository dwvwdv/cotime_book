import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';

/// Full-screen ads shown between pages and before a converted book is saved.
///
/// An ad never stands in the way: [show] resolves at once when none is ready,
/// and the caller carries on as if there were no ads.
abstract class InterstitialAds {
  /// Starts loading an ad, if none is ready or on its way.
  void preload();

  /// An ad is loaded and [show] would show it.
  bool get isReady;

  /// Shows the ad that is ready. Resolves once it is gone: true when one was
  /// shown, false when none was ready (one is then loaded for next time).
  Future<bool> show();
}

/// Where AdMob has no SDK (web, desktop) and in tests.
class NoInterstitialAds implements InterstitialAds {
  const NoInterstitialAds();

  @override
  void preload() {}

  @override
  bool get isReady => false;

  @override
  Future<bool> show() async => false;
}

/// AdMob's SDK exists only on Android and iOS.
bool get platformHasInterstitialAds =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

class AdMobInterstitialAds implements InterstitialAds {
  final String adUnitId;

  InterstitialAd? _ad;
  DateTime? _loadedAt;
  DateTime? _failedAt;
  bool _loading = false;
  bool _showing = false;

  AdMobInterstitialAds({required this.adUnitId});

  /// [unitId] as this build asks for it (see [AdConfig.unitFor]).
  factory AdMobInterstitialAds.forPlatform(String unitId) =>
      AdMobInterstitialAds(
        adUnitId: AdConfig.unitFor(unitId, isIOS: Platform.isIOS),
      );

  /// Shared by every placement: the SDK is initialized once.
  static Future<bool>? _sdkReady;

  static Future<bool> _initializeSdk() async {
    try {
      await MobileAds.instance.initialize();
      return true;
    } catch (error) {
      debugPrint('Mobile Ads unavailable: $error');
      return false;
    }
  }

  /// Initializes the SDK and loads the first ad, so the first one due is
  /// usually ready.
  Future<void> start() async {
    if (await (_sdkReady ??= _initializeSdk())) preload();
  }

  bool get _isStale {
    final loadedAt = _loadedAt;
    return loadedAt != null &&
        DateTime.now().difference(loadedAt) > AdConfig.adLifetime;
  }

  @override
  bool get isReady => _ad != null && !_showing && !_isStale;

  @override
  void preload() {
    if (_loading || _showing) return;
    if (_ad != null) {
      if (!_isStale) return;
      _discard();
    }
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < AdConfig.retryAfterFailure) {
      return;
    }
    _loading = true;
    void failed(Object error) {
      _loading = false;
      _failedAt = DateTime.now();
      debugPrint('Interstitial ad failed to load: $error');
    }

    try {
      unawaited(
        InterstitialAd.load(
          adUnitId: adUnitId,
          request: const AdRequest(),
          adLoadCallback: InterstitialAdLoadCallback(
            onAdLoaded: (ad) {
              _loading = false;
              _failedAt = null;
              _ad = ad;
              _loadedAt = DateTime.now();
            },
            onAdFailedToLoad: failed,
          ),
        ).catchError(failed),
      );
    } catch (error) {
      failed(error);
    }
  }

  @override
  Future<bool> show() async {
    if (_showing) return false;
    if (_isStale) _discard();
    final ad = _ad;
    if (ad == null) {
      preload();
      return false;
    }
    _ad = null;
    _loadedAt = null;
    _showing = true;

    final done = Completer<bool>();
    void finish(InterstitialAd ad, bool shown) {
      ad.dispose();
      _showing = false;
      if (!done.isCompleted) done.complete(shown);
      preload();
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) => finish(ad, true),
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('Interstitial ad failed to show: $error');
        finish(ad, false);
      },
    );
    try {
      await ad.show();
    } catch (error) {
      debugPrint('Interstitial ad failed to show: $error');
      finish(ad, false);
    }
    return done.future;
  }

  void _discard() {
    _ad?.dispose();
    _ad = null;
    _loadedAt = null;
  }
}
