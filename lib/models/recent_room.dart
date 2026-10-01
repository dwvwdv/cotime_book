/// A room this device has been in, kept so it can be re-entered in one tap.
class RecentRoom {
  final String code;
  final String? bookTitle;
  final DateTime lastVisitedAt;

  const RecentRoom({
    required this.code,
    this.bookTitle,
    required this.lastVisitedAt,
  });

  factory RecentRoom.fromJson(Map<String, dynamic> json) {
    return RecentRoom(
      code: json['code'] as String,
      bookTitle: json['book_title'] as String?,
      lastVisitedAt: DateTime.parse(json['last_visited_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'book_title': bookTitle,
    'last_visited_at': lastVisitedAt.toUtc().toIso8601String(),
  };
}
