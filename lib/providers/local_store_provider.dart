import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/local_store.dart';

/// Overridden in `main()` with a store backed by SharedPreferences. The
/// in-memory default keeps tests and widget previews free of plugin setup.
final localStoreProvider = Provider<LocalStore>((ref) => LocalStore());
