import 'package:flutter/foundation.dart';

/// Interstitial ads: where they come from and how often the reader sees one.
///
/// The ad units and the AdMob app ID in
/// `android/app/src/main/AndroidManifest.xml`
/// (`com.google.android.gms.ads.APPLICATION_ID`) belong to the same AdMob app;
/// ad units from another app serve nothing, so change them together.
class AdConfig {
  AdConfig._();

  /// Every [pageTurnsPerAd] pages in a room.
  static const pageTurnUnitId = 'ca-app-pub-3815823795185340/4634708480';

  /// Before a book made with TXT to EPUB is saved.
  static const txtSaveUnitId = 'ca-app-pub-3815823795185340/6282832075';

  /// Google's sample interstitial units, which always serve test ads. Debug
  /// and profile builds use them: real ads tapped while developing count as
  /// invalid traffic against the AdMob account.
  static const androidTestUnitId = 'ca-app-pub-3940256099942544/1033173712';
  static const iosTestUnitId = 'ca-app-pub-3940256099942544/4411468910';

  /// The unit a build on this platform asks for in place of [unitId]. There
  /// is no iOS app in AdMob yet, so iOS always gets test ads.
  static String unitFor(
    String unitId, {
    required bool isIOS,
    bool isRelease = kReleaseMode,
  }) {
    if (isIOS) return iosTestUnitId;
    return isRelease ? unitId : androidTestUnitId;
  }

  /// Shared pages between two ad breaks. Counted on the room's shared
  /// position, so every reader's ad comes up on the same page (see
  /// `PageSyncService.isAdBreakPage`).
  static const pageTurnsPerAd = 20;

  /// A loaded interstitial is only good for an hour; one kept longer is
  /// dropped and loaded again.
  static const adLifetime = Duration(minutes: 55);

  /// After a failed load, how long to wait before trying again. Without it a
  /// device offline would ask for an ad on every page.
  static const retryAfterFailure = Duration(minutes: 1);
}
