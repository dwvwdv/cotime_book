import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// The account sent its hourly allowance of reports already.
class LayoutReportRateLimitedException implements Exception {
  const LayoutReportRateLimitedException();
}

/// Sends page layout reports to `cotime_book.submit_layout_report`.
class LayoutReportService {
  /// Returns the stored report's id.
  Future<String> submit({
    required String? roomId,
    required String appVersion,
    required String note,
    required Map<String, dynamic> report,
  }) async {
    try {
      final id = await SupabaseService.database.rpc(
        'submit_layout_report',
        params: {
          'p_room_id': roomId,
          'p_app_version': appVersion,
          'p_note': note,
          'p_report': report,
        },
      );
      return id as String;
    } on PostgrestException catch (error) {
      if (error.code == '54000') throw const LayoutReportRateLimitedException();
      rethrow;
    }
  }
}

/// The `version:` of the pubspec the app was built from, e.g. `1.0.9+13`.
///
/// Read from the bundled pubspec rather than written down a second time:
/// pubspec.yaml is the only place the version lives (see version-update.md).
Future<String> loadAppVersion([AssetBundle? bundle]) async {
  try {
    final pubspec = await (bundle ?? rootBundle).loadString('pubspec.yaml');
    return appVersionFromPubspec(pubspec) ?? 'unknown';
  } catch (_) {
    return 'unknown';
  }
}

String? appVersionFromPubspec(String pubspec) => RegExp(
  r'^version:\s*([^\s#]+)',
  multiLine: true,
).firstMatch(pubspec)?.group(1);
