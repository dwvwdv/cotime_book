/// A note from the people who make the app, usually what changed in a
/// release: one row of `cotime_book.announcements`.
class Announcement {
  final int id;
  final String title;

  /// Plain text; line breaks are kept as written.
  final String content;
  final DateTime publishedAt;

  const Announcement({
    required this.id,
    required this.title,
    required this.content,
    required this.publishedAt,
  });

  /// Null for a row that cannot be shown, so one bad row edited by hand in
  /// the dashboard does not take the whole list down with it.
  static Announcement? fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final title = row['title'];
    final publishedAt = DateTime.tryParse('${row['published_at']}');
    if (id is! num || title is! String || title.trim().isEmpty) return null;
    if (publishedAt == null) return null;
    final content = row['content'];
    return Announcement(
      id: id.toInt(),
      title: title.trim(),
      // Written by hand in the dashboard, possibly pasted from Windows.
      content: content is String ? content.replaceAll('\r\n', '\n').trim() : '',
      publishedAt: publishedAt.toLocal(),
    );
  }

  /// The day it was posted, on this device's calendar: `2026-10-27`.
  String get dateLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${publishedAt.year}-${two(publishedAt.month)}-'
        '${two(publishedAt.day)}';
  }
}
