/// Where a page layout report the reader sent stands: one row of
/// `cotime_book.my_layout_reports()`.
enum LayoutReportStatus {
  /// Not looked at yet, or still being worked on.
  open,

  /// Fixed, usually in a release ([LayoutReportRecord.fixedIn]).
  resolved,

  /// Closed without a fix: could not be reproduced, the book itself is
  /// broken, already reported.
  declined,
}

class LayoutReportRecord {
  final String id;
  final DateTime sentAt;

  /// The book's title as the room had it; null when the report had none.
  final String? bookTitle;

  /// What the reader wrote when sending it.
  final String? note;
  final LayoutReportStatus status;
  final DateTime? resolvedAt;

  /// The release with the fix, as major.minor.patch.
  final String? fixedIn;

  /// From the maintainers, as written: one note in both languages.
  final String? resolutionNote;

  const LayoutReportRecord({
    required this.id,
    required this.sentAt,
    required this.status,
    this.bookTitle,
    this.note,
    this.resolvedAt,
    this.fixedIn,
    this.resolutionNote,
  });

  /// Null for a row that cannot be shown, so one bad row does not take the
  /// whole history down with it. A status this app does not know (added by a
  /// later release) reads as still open rather than hiding the report.
  static LayoutReportRecord? fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final sentAt = DateTime.tryParse('${row['created_at']}');
    if (id is! String || sentAt == null) return null;
    final status = LayoutReportStatus.values.firstWhere(
      (value) => value.name == row['status'],
      orElse: () => LayoutReportStatus.open,
    );
    return LayoutReportRecord(
      id: id,
      sentAt: sentAt.toLocal(),
      status: status,
      bookTitle: _text(row['book_title']),
      note: _text(row['note']),
      resolvedAt: DateTime.tryParse('${row['resolved_at']}')?.toLocal(),
      fixedIn: _text(row['fixed_in']),
      resolutionNote: _text(row['resolution_note'])?.replaceAll('\r\n', '\n'),
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Answered one way or the other: what the home screen tells the reader
  /// about until they have seen it.
  bool get isSettled => status != LayoutReportStatus.open;

  /// Tells this answer apart from an earlier one for the same report, so a
  /// report reopened and then answered again is news again.
  String get answerKey => '$id@${resolvedAt?.toUtc().toIso8601String()}';

  /// Fixed in a release newer than [appVersion]: on this app the bug is still
  /// there, and calling it solved would read as a fix that did not work.
  /// False when either version cannot be read.
  bool needsUpdate(String appVersion) {
    final fixedIn = this.fixedIn;
    if (status != LayoutReportStatus.resolved || fixedIn == null) return false;
    final comparison = compareReleases(appVersion, fixedIn);
    return comparison != null && comparison < 0;
  }
}

/// Orders two versions by major.minor.patch, ignoring any `+build`; null when
/// either is not a version (`unknown`).
int? compareReleases(String a, String b) {
  List<int>? parse(String version) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version.trim());
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  final left = parse(a);
  final right = parse(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  return 0;
}

/// A time on this device's clock: `2026-10-30 09:53`.
String reportTimeLabel(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final local = time.toLocal();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
