import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// The app's languages, English first: a device in any other language gets
/// English.
const appLocales = AppLocalizations.supportedLocales;

AppLocalizations? _appStrings;

/// The strings for text made away from any widget: provider state, services,
/// the lobby's readiness hints.
///
/// Those are stored as text and shown later, so they cannot look up a
/// [BuildContext]. Starts from the device's languages and follows the locale
/// the app resolves ([resolveAppLocale]).
AppLocalizations get appStrings => _appStrings ??= lookupAppLocalizations(
  resolveAppLocale(PlatformDispatcher.instance.locales),
);

/// The locale the app shows, for [MaterialApp.localeListResolutionCallback].
///
/// Also moves [appStrings] to it, so text made outside the widget tree is in
/// the same language as the screens.
Locale resolveAppLocale(List<Locale>? preferred) {
  final locale = basicLocaleListResolution(preferred, appLocales);
  _appStrings = lookupAppLocalizations(locale);
  return locale;
}

extension AppLocalizationsContext on BuildContext {
  /// The strings for this part of the tree.
  ///
  /// Falls back to [appStrings] where no [AppLocalizations] delegate is
  /// installed (a widget pumped alone in a test): the text is then the
  /// device's language rather than an error.
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ?? appStrings;
}
