import 'package:flutter_test/flutter_test.dart';
import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/models/book_metadata.dart';
import 'package:cotime_book/services/room_service.dart';

void main() {
  group('PageTurnRequest', () {
    test('isConsensusReached returns true when all users confirmed', () {
      final request = PageTurnRequest(
        requestId: 'test-1',
        requestedByUserId: 'user-a',
        requestedByNickname: 'Alice',
        direction: PageTurnDirection.next,
        fromSeq: 3,
        requestedAt: DateTime.now(),
        confirmedUserIds: {'user-a', 'user-b', 'user-c'},
        requiredUserIds: {'user-a', 'user-b', 'user-c'},
      );

      expect(request.isConsensusReached, isTrue);
      expect(request.pendingUserIds, isEmpty);
      expect(request.progress, 1.0);
    });

    test('isConsensusReached returns false when not all confirmed', () {
      final request = PageTurnRequest(
        requestId: 'test-2',
        requestedByUserId: 'user-a',
        requestedByNickname: 'Alice',
        direction: PageTurnDirection.next,
        fromSeq: 3,
        requestedAt: DateTime.now(),
        confirmedUserIds: {'user-a'},
        requiredUserIds: {'user-a', 'user-b', 'user-c'},
      );

      expect(request.isConsensusReached, isFalse);
      expect(request.pendingUserIds, {'user-b', 'user-c'});
      expect(request.progress, closeTo(0.333, 0.01));
    });

    test('handles removing disconnected users', () {
      final request = PageTurnRequest(
        requestId: 'test-3',
        requestedByUserId: 'user-a',
        requestedByNickname: 'Alice',
        direction: PageTurnDirection.next,
        fromSeq: 3,
        requestedAt: DateTime.now(),
        confirmedUserIds: {'user-a'},
        requiredUserIds: {'user-a', 'user-b', 'user-c'},
      );

      // Simulate user-c disconnecting
      final updated = request.copyWith(requiredUserIds: {'user-a', 'user-b'});

      expect(updated.requiredUserIds.length, 2);

      // user-b confirms
      final confirmed = updated.copyWith(
        confirmedUserIds: {'user-a', 'user-b'},
      );
      expect(confirmed.isConsensusReached, isTrue);
    });

    test('serialization roundtrip', () {
      final original = PageTurnRequest(
        requestId: 'test-4',
        requestedByUserId: 'user-a',
        requestedByNickname: 'Alice',
        direction: PageTurnDirection.previous,
        fromSeq: 3,
        requestedAt: DateTime.now(),
        confirmedUserIds: {'user-a'},
        requiredUserIds: {'user-a', 'user-b'},
      );

      final json = original.toJson();
      final restored = PageTurnRequest.fromJson(json);

      expect(restored.fromSeq, original.fromSeq);
      expect(restored.requestId, original.requestId);
      expect(restored.direction, original.direction);
      expect(restored.requiredUserIds, original.requiredUserIds);
      expect(restored.requestedByNickname, original.requestedByNickname);
    });
  });

  group('Room', () {
    test('fromJson/toJson roundtrip', () {
      final now = DateTime.now();
      final room = Room(
        id: '123',
        code: 'ABC123',
        hostUserId: 'user-1',
        currentBookTitle: 'Test Book',
        currentBookHash: 'hash123',
        currentBookLibraryPath: 'classics/test.epub',
        currentCfi: 'epubcfi(/6/4)',
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );

      final json = room.toJson();
      final restored = Room.fromJson(json);

      expect(restored.id, room.id);
      expect(restored.code, room.code);
      expect(restored.hostUserId, room.hostUserId);
      expect(restored.currentBookTitle, room.currentBookTitle);
      expect(restored.currentBookLibraryPath, 'classics/test.epub');
      expect(restored.isActive, room.isActive);
    });

    test('only a library book writes the library path column', () {
      // A book from this device leaves the column out: the database clears a
      // stale path itself, and sharing keeps working against a database that
      // does not have the column yet (GH-28).
      expect(roomBookUpdate(bookTitle: 'Notes', bookHash: 'abc'), {
        'current_book_title': 'Notes',
        'current_book_hash': 'abc',
      });
      expect(
        roomBookUpdate(
          bookTitle: 'Moby Dick',
          bookHash: 'def',
          libraryPath: 'classics/moby-dick.epub',
        )['current_book_library_path'],
        'classics/moby-dick.epub',
      );
    });

    test('a room row from before the library path column has no path', () {
      final json = Room(
        id: '123',
        code: 'ABC123',
        hostUserId: 'user-1',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ).toJson()..remove('current_book_library_path');

      expect(Room.fromJson(json).currentBookLibraryPath, isNull);
    });

    test('copyWith keeps the library path unless it is passed', () {
      final room = Room(
        id: '123',
        code: 'ABC123',
        hostUserId: 'user-1',
        currentBookLibraryPath: 'classics/test.epub',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      expect(
        room.copyWith(currentCfi: 'epubcfi(/6/4)').currentBookLibraryPath,
        'classics/test.epub',
      );
      expect(
        room.copyWith(currentBookLibraryPath: null).currentBookLibraryPath,
        isNull,
      );
    });

    test('copyWith updates fields', () {
      final now = DateTime.now();
      final room = Room(
        id: '123',
        code: 'ABC123',
        hostUserId: 'user-1',
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );

      final updated = room.copyWith(
        currentBookTitle: 'New Book',
        currentBookHash: 'newhash',
      );

      expect(updated.currentBookTitle, 'New Book');
      expect(updated.currentBookHash, 'newhash');
      expect(updated.id, room.id);
    });
  });

  group('BookMetadata', () {
    test('fileSizeFormatted returns correct format', () {
      expect(
        const BookMetadata(
          id: '1',
          title: 'Test',
          author: 'A',
          fileName: 'test.epub',
          fileSizeBytes: 500,
          fileHash: 'h',
        ).fileSizeFormatted,
        '500 B',
      );

      expect(
        const BookMetadata(
          id: '1',
          title: 'Test',
          author: 'A',
          fileName: 'test.epub',
          fileSizeBytes: 2048,
          fileHash: 'h',
        ).fileSizeFormatted,
        '2.0 KB',
      );

      expect(
        const BookMetadata(
          id: '1',
          title: 'Test',
          author: 'A',
          fileName: 'test.epub',
          fileSizeBytes: 5242880,
          fileHash: 'h',
        ).fileSizeFormatted,
        '5.0 MB',
      );
    });
  });
}
