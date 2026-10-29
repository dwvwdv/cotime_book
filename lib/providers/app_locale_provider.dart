import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../services/local_store.dart';
import 'local_store_provider.dart';

/// The interface language picked with the toggle on Home, or null until one
/// is: the device's languages decide then.
final appLocaleProvider = StateNotifierProvider<AppLocaleNotifier, Locale?>(
  (ref) => AppLocaleNotifier(ref.read(localStoreProvider)),
);

class AppLocaleNotifier extends StateNotifier<Locale?> {
  final LocalStore _store;

  AppLocaleNotifier(this._store) : super(_saved(_store));

  /// A saved code the app no longer has (or a hand-edited file) is as good
  /// as none.
  static Locale? _saved(LocalStore store) {
    final code = store.appLanguage;
    return appLocales.firstWhereOrNull((locale) => locale.languageCode == code);
  }

  /// Switches to the other language from [shown], the one on screen. From
  /// the screen rather than [state]: before the first switch the state is
  /// null and the device decided.
  void toggle(Locale shown) {
    final next = appLocales.firstWhere(
      (locale) => locale.languageCode != shown.languageCode,
    );
    // Now, not on the rebuild: a message made in between would come out in
    // the old language.
    resolveAppLocale([next]);
    state = next;
    unawaited(_store.saveAppLanguage(next.languageCode));
  }
}
