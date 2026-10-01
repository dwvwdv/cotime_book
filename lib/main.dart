import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'config/supabase_config.dart';
import 'providers/local_store_provider.dart';
import 'services/local_store.dart';
import 'services/supabase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
