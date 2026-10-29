import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// The app's languages, English first: a device in any other language gets
/// English.
///
/// The Chinese is Traditional, and says so: with a bare `zh`, Material's own
/// text (the copy and paste menu, the back button's tooltip) comes out in
/// Simplified. AppLocalizations still finds its strings by language alone.
const appLocales = [
  Locale('en'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
];

AppLocalizations? _appStrings;

/// The strings for text made away from any widget: provider state, services,
/// the lobby's readiness hints.
///
/// Those are stored as text and shown later, so they cannot look up a
/// [BuildContext]. Starts from the device's languages and follows the locale
/// the screens are in ([followAppLocale]).
AppLocalizations get appStrings => _appStrings ??= lookupAppLocalizations(
  resolveAppLocale(PlatformDispatcher.instance.locales),
);

/// The app's language for [preferred], the device's languages.
Locale resolveAppLocale(List<Locale>? preferred) =>
    basicLocaleListResolution(preferred, appLocales);

/// Makes [appStrings] the strings of [locale].
void useAppStringsOf(Locale locale) {
  _appStrings = lookupAppLocalizations(locale);
}

/// For [MaterialApp.builder]: keeps [appStrings] in the language the screens
/// are in, whether the device or the toggle on Home picked it.
///
/// Read from the [Localizations] the screens use rather than set from a
/// locale resolution callback: WidgetsApp also runs that callback with the
/// device's languages when they change, even while [MaterialApp.locale]
/// overrides them, and the screens would stay English while the messages
/// turned Chinese.
Widget followAppLocale(BuildContext context, Widget? child) {
  useAppStringsOf(Localizations.localeOf(context));
  return child ?? const SizedBox.shrink();
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
