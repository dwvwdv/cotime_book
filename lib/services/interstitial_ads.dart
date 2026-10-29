import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';
import 'ad_consent.dart';

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

  /// After a failed load, or a request consent did not allow, how long
  /// before trying again. Without it a device offline would ask on every
  /// page.
  final Duration retryAfterFailure;

  /// Set by [start]; no ad is requested before it.
  AdConsent? _consent;
  InterstitialAd? _ad;
  DateTime? _loadedAt;
  DateTime? _failedAt;
  bool _loading = false;
  bool _showing = false;

  AdMobInterstitialAds({
    required this.adUnitId,
    this.retryAfterFailure = AdConfig.retryAfterFailure,
  });

  /// [unitId] as this build asks for it (see [AdConfig.unitFor]).
  factory AdMobInterstitialAds.forPlatform(String unitId) =>
      AdMobInterstitialAds(
        adUnitId: AdConfig.unitFor(unitId, isIOS: Platform.isIOS),
      );

  /// Shared by every placement: the SDK is initialized once. Cleared when
  /// consent did not allow it or it failed, so a later [preload] tries
  /// again — an e-reader keeps the app alive for days, and a user who says
  /// yes in Ad Privacy Choices should not have to restart it.
  static Future<bool>? _sdkReady;

  /// Starts the SDK. Swapped in tests, which have none.
  @visibleForTesting
  static Future<void> Function() initializeSdk = _initializeMobileAds;

  static Future<void> _initializeMobileAds() async {
    await MobileAds.instance.initialize();
  }

  @visibleForTesting
  static void resetForTest() {
    _sdkReady = null;
    initializeSdk = _initializeMobileAds;
  }

  static Future<bool> _sdkStarted(AdConsent consent) =>
      _sdkReady ??= _initializeSdk(consent).then((started) {
        if (!started) _sdkReady = null;
        return started;
      });

  static Future<bool> _initializeSdk(AdConsent consent) async {
    // Not even initialized without consent (GH-58): the SDK starts its
    // adapters and their network requests on initialize.
    if (!await consent.gather()) return false;
    try {
      await initializeSdk();
      return true;
    } catch (error) {
      debugPrint('Mobile Ads unavailable: $error');
      return false;
    }
  }

  /// Asks for consent where it is needed, initializes the SDK and loads the
  /// first ad, so the first one due is usually ready. Without consent no ad
  /// is requested, and [show] resolves false.
  Future<void> start(AdConsent consent) {
    _consent = consent;
    return _preload();
  }

  bool get _isStale {
    final loadedAt = _loadedAt;
    return loadedAt != null &&
        DateTime.now().difference(loadedAt) > AdConfig.adLifetime;
  }

  @override
  bool get isReady => _ad != null && !_showing && !_isStale;

  @override
  void preload() => unawaited(_preload());

  Future<void> _preload() async {
    final consent = _consent;
    if (consent == null || _loading || _showing) return;
    if (_ad != null) {
      if (!_isStale) return;
      _discard();
    }
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < retryAfterFailure) {
      return;
    }
    _loading = true;
    // Checked before every request, as Google asks (GH-58): the answer can
    // change in Ad Privacy Choices after the SDK started, either way.
    final allowed = await _sdkStarted(consent) && await consent.canRequestAds();
    if (!allowed) {
      _loading = false;
      _failedAt = DateTime.now();
      return;
    }

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
