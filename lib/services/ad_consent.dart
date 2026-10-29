import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Google's User Messaging Platform, which the consent below goes through.
/// An interface so the flow can be tested without the SDK.
abstract class ConsentPlatform {
  /// Asks Google whether this user's answer is needed, missing or out of
  /// date. Throws when the request fails.
  Future<void> requestUpdate();

  /// Shows Google's consent message when [requestUpdate] found it needed.
  /// Resolves once it is answered, or at once when it is not needed. Throws
  /// when the message could not be shown.
  Future<void> showFormIfRequired();

  /// Whether ads may be requested: the answer is not needed here, or was
  /// given — in this session or an earlier one.
  Future<bool> canRequestAds();

  /// Whether the user has to be offered a way to change their answer.
  Future<bool> privacyOptionsRequired();

  /// Google's form for changing the answer. Throws when it could not be
  /// shown.
  Future<void> showPrivacyOptionsForm();
}

/// Asking for consent before asking AdMob for ads (GH-58). In the EEA, the
/// UK and Switzerland ads may only be requested once the user has answered
/// Google's consent message; elsewhere Google says it is not needed and
/// nothing is shown.
///
/// Like the ads themselves, consent never stands in the way: a request or a
/// message that fails is taken as no ads, never as an error, and the next
/// start asks again.
class AdConsent {
  final ConsentPlatform _platform;

  /// How long asking Google may take before going on without an answer from
  /// this session. The answer given before still counts.
  final Duration updateTimeout;

  AdConsent(this._platform, {this.updateTimeout = const Duration(seconds: 15)});

  Future<bool>? _gathered;
  final ValueNotifier<bool> _privacyOptionsRequired = ValueNotifier(false);

  /// The user has to be able to change their answer: offer
  /// [showPrivacyOptions] wherever an ad can be shown. Known once [gather]
  /// is done, which may be after a screen offering it was built.
  ValueListenable<bool> get privacyOptionsRequired => _privacyOptionsRequired;

  /// Brings the user's answer up to date, showing Google's message when it
  /// is needed. True when ads may be requested. Asked once per start, as
  /// Google requires; every caller shares that one answer.
  Future<bool> gather() => _gathered ??= _gather();

  Future<bool> _gather() async {
    var updated = false;
    try {
      await _platform.requestUpdate().timeout(updateTimeout);
      updated = true;
    } catch (error) {
      // An answer given in an earlier session still counts below.
      debugPrint('Ad consent not updated: $error');
    }
    if (updated) {
      try {
        await _platform.showFormIfRequired();
      } catch (error) {
        debugPrint('Ad consent message not shown: $error');
      }
    }
    await _readPrivacyOptionsRequired();
    try {
      return await _platform.canRequestAds();
    } catch (error) {
      debugPrint('Ad consent unknown: $error');
      return false;
    }
  }

  /// Lets the user change their answer. Never throws.
  Future<void> showPrivacyOptions() async {
    try {
      await _platform.showPrivacyOptionsForm();
    } catch (error) {
      debugPrint('Ad privacy options not shown: $error');
    }
    await _readPrivacyOptionsRequired();
  }

  Future<void> _readPrivacyOptionsRequired() async {
    try {
      _privacyOptionsRequired.value = await _platform.privacyOptionsRequired();
    } catch (error) {
      debugPrint('Ad privacy options unknown: $error');
    }
  }
}

/// [ConsentPlatform] on Google's UMP SDK, which google_mobile_ads carries.
class GoogleConsentPlatform implements ConsentPlatform {
  const GoogleConsentPlatform();

  @override
  Future<void> requestUpdate() {
    final done = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () {
        if (!done.isCompleted) done.complete();
      },
      (error) {
        if (!done.isCompleted) done.completeError(_FormFailure(error));
      },
    );
    return done.future;
  }

  @override
  Future<void> showFormIfRequired() {
    final done = Completer<void>();
    unawaited(
      ConsentForm.loadAndShowConsentFormIfRequired((error) {
        if (done.isCompleted) return;
        if (error == null) {
          done.complete();
        } else {
          done.completeError(_FormFailure(error));
        }
      }).catchError((Object error) {
        if (!done.isCompleted) done.completeError(error);
      }),
    );
    return done.future;
  }

  @override
  Future<bool> canRequestAds() => ConsentInformation.instance.canRequestAds();

  @override
  Future<bool> privacyOptionsRequired() async =>
      await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
      PrivacyOptionsRequirementStatus.required;

  @override
  Future<void> showPrivacyOptionsForm() {
    final done = Completer<void>();
    unawaited(
      ConsentForm.showPrivacyOptionsForm((error) {
        if (done.isCompleted) return;
        if (error == null) {
          done.complete();
        } else {
          done.completeError(_FormFailure(error));
        }
      }).catchError((Object error) {
        if (!done.isCompleted) done.completeError(error);
      }),
    );
    return done.future;
  }
}

class _FormFailure implements Exception {
  final FormError error;

  _FormFailure(this.error);

  @override
  String toString() => 'UMP error ${error.errorCode}: ${error.message}';
}
