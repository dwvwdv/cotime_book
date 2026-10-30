import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/layout_report_record.dart';
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

/// The reports this account sent and what became of them, for the home
/// screen. Injectable so it can be tested without the network.
abstract interface class LayoutReportHistory {
  /// Newest first.
  Future<List<LayoutReportRecord>> list();
}

/// Reads `cotime_book.my_layout_reports()`: the account's own reports, and
/// only their outcome, never the report itself.
class SupabaseLayoutReportHistory implements LayoutReportHistory {
  static const listTimeout = Duration(seconds: 30);

  final Future<Object?> Function() _call;

  SupabaseLayoutReportHistory({Future<Object?> Function()? call})
    : _call = call ?? _callRpc;

  static Future<Object?> _callRpc() =>
      SupabaseService.database.rpc('my_layout_reports');

  @override
  Future<List<LayoutReportRecord>> list() async {
    final rows = await _call().timeout(listTimeout);
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        if (row is Map<String, dynamic>) ?LayoutReportRecord.fromRow(row),
    ];
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
