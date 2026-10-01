import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'config/supabase_config.dart';
import 'providers/local_store_provider.dart';
import 'services/local_store.dart';
import 'services/supabase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerFontLicense();

  if (SupabaseConfig.isConfigured) {
    await SupabaseService.initialize();
  } else {
    debugPrint(
      'WARNING: Supabase not configured. '
      'Run with --dart-define=SUPABASE_URL=xxx --dart-define=SUPABASE_ANON_KEY=xxx',
    );
  }

  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(LocalStore(await _loadPrefs())),
      ],
      child: const CoTimeBookApp(),
    ),
  );
}

Future<SharedPreferences?> _loadPrefs() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (error) {
    debugPrint('Local preferences unavailable, keeping them in memory: $error');
    return null;
  }
}

/// The OFL asks for its text to travel with the font; this puts it on the
/// app's licence page next to the packages'.
void _registerFontLicense() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/literata/OFL.txt');
    yield LicenseEntryWithLineBreaks(['Literata'], text);
  });
}
