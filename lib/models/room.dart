/// Marks a [Room.copyWith] argument that was not passed, so a nullable
/// field can still be cleared by passing null.
const Object _unset = Object();

class Room {
  final String id;
  final String code;
  final String hostUserId;
  final String? channelId;
  final String? currentBookTitle;
  final String? currentBookHash;

  /// Where [currentBookHash] is in the public library, when it was shared from
  /// there. Null for any other book.
  final String? currentBookLibraryPath;
  final String? currentCfi;

  /// Only the host sets the room's text size (the default). When the host
  /// turns this off, every reader asks for their own size again.
  final bool textSizeLocked;

  /// The size every reader asks for while [textSizeLocked]. Null until the
  /// host first opens the book with the lock on.
  final int? textSize;
  final bool isActive;
  final DateTime? closedAt;
  final DateTime? expiresAt;
  final DateTime? lastActivityAt;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Room({
    required this.id,
    required this.code,
    required this.hostUserId,
    this.channelId,
    this.currentBookTitle,
    this.currentBookHash,
    this.currentBookLibraryPath,
    this.currentCfi,
    this.textSizeLocked = true,
    this.textSize,
    this.isActive = true,
    this.closedAt,
    this.expiresAt,
    this.lastActivityAt,
    this.revision = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'] as String,
      code: json['code'] as String,
      hostUserId: json['host_user_id'] as String,
      channelId: json['channel_id'] as String?,
      currentBookTitle: json['current_book_title'] as String?,
      currentBookHash: json['current_book_hash'] as String?,
      currentBookLibraryPath: json['current_book_library_path'] as String?,
      currentCfi: json['current_cfi'] as String?,
      // Locked, like the column's default, when a database from before the
      // column does not send it.
      textSizeLocked: json['text_size_locked'] as bool? ?? true,
      textSize: (json['text_size'] as num?)?.toInt(),
      isActive: json['is_active'] as bool? ?? true,
      closedAt: json['closed_at'] != null
          ? DateTime.parse(json['closed_at'] as String)
          : null,
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
      lastActivityAt: json['last_activity_at'] != null
          ? DateTime.parse(json['last_activity_at'] as String)
          : null,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'host_user_id': hostUserId,
      'channel_id': channelId,
      'current_book_title': currentBookTitle,
      'current_book_hash': currentBookHash,
      'current_book_library_path': currentBookLibraryPath,
      'current_cfi': currentCfi,
      'text_size_locked': textSizeLocked,
      'text_size': textSize,
      'is_active': isActive,
      'closed_at': closedAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'last_activity_at': lastActivityAt?.toIso8601String(),
      'revision': revision,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Room copyWith({
    String? id,
    String? code,
    String? hostUserId,
    String? channelId,
    String? currentBookTitle,
    String? currentBookHash,
    Object? currentBookLibraryPath = _unset,
    String? currentCfi,
    bool? textSizeLocked,
    Object? textSize = _unset,
    bool? isActive,
    DateTime? closedAt,
    DateTime? expiresAt,
    DateTime? lastActivityAt,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Room(
      id: id ?? this.id,
      code: code ?? this.code,
      hostUserId: hostUserId ?? this.hostUserId,
      channelId: channelId ?? this.channelId,
      currentBookTitle: currentBookTitle ?? this.currentBookTitle,
      currentBookHash: currentBookHash ?? this.currentBookHash,
      currentBookLibraryPath: identical(currentBookLibraryPath, _unset)
          ? this.currentBookLibraryPath
          : currentBookLibraryPath as String?,
      currentCfi: currentCfi ?? this.currentCfi,
      textSizeLocked: textSizeLocked ?? this.textSizeLocked,
      textSize: identical(textSize, _unset) ? this.textSize : textSize as int?,
      isActive: isActive ?? this.isActive,
      closedAt: closedAt ?? this.closedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      revision: revision ?? this.revision,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
