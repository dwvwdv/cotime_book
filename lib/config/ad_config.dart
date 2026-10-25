/// Interstitial ads: where they come from and how often the reader sees one.
///
/// The IDs below are Google's sample IDs, which always serve test ads. Before
/// a release with real ads, replace both the ad unit IDs here and the AdMob
/// app ID in `android/app/src/main/AndroidManifest.xml`
/// (`com.google.android.gms.ads.APPLICATION_ID`): an app ID and ad units from
/// different AdMob apps serve nothing.
class AdConfig {
  AdConfig._();

  static const androidInterstitialUnitId =
      'ca-app-pub-3940256099942544/1033173712';
  static const iosInterstitialUnitId = 'ca-app-pub-3940256099942544/4411468910';

  /// The room's page moves this device sees between two interstitials.
  static const pageTurnsPerAd = 20;

  /// A loaded interstitial is only good for an hour; one kept longer is
  /// dropped and loaded again.
  static const adLifetime = Duration(minutes: 55);

  /// After a failed load, how long to wait before trying again. Without it a
  /// device offline would ask for an ad on every page.
  static const retryAfterFailure = Duration(minutes: 1);
}
