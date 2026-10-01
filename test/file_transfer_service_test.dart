import 'dart:async';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/transfer_state.dart';
import 'package:cotime_book/services/file_transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Four chunks: enough to lose some of them.
  final book = Uint8List.fromList(
    List.generate(AppConstants.fileChunkSize * 3 + 1234, (i) => i % 251),
  );
  final bookHash = sha256.convert(book).toString();

  test(
    'a receiver that missed the whole push asks and gets the book',
    () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice');
      final bob = room.join('bob');

      bob.service.expectBook(bookHash);
      room.dropChunks = true;
      await alice.share(book, bookHash);
      room.dropChunks = false;

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(bob.service.currentState.status, TransferStatus.completed);
    },
  );

  test('a member who joins after the share still receives the book', () async {
    // Regression: the book was pushed once. Anyone who arrived later waited
    // on "Receiving book..." forever.
    final room = TransferRoom();
    addTearDown(room.dispose);
    final alice = room.join('alice');
    await alice.share(book, bookHash);

    final bob = room.join('bob');
    bob.service.expectBook(bookHash);

    await room.waitFor(() => bob.store.books.containsKey(bookHash));
    expect(bob.store.books[bookHash], book);
  });

  test('only the lost chunks are asked for again', () async {
    final room = TransferRoom();
    addTearDown(room.dispose);
    final alice = room.join('alice');
    final bob = room.join('bob');
    bob.service.expectBook(bookHash);

    room.dropChunkIndices = {1, 3};
    await alice.share(book, bookHash);
    room.dropChunkIndices = {};
    expect(bob.service.currentState.status, TransferStatus.transferring);

    await room.waitFor(() => bob.store.books.containsKey(bookHash));
    final request = room.requests.first;
    expect(request['missing'], [1, 3]);
    expect(request['sender_id'], 'alice');
  });

  test('with nobody holding the book it waits, then asks the moment someone '
      'comes online', () async {
    final room = TransferRoom();
    addTearDown(room.dispose);
    final bob = room.join('bob');
    bob.service.expectBook(bookHash);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(bob.service.currentState.status, TransferStatus.waiting);
    expect(bob.service.currentState.message, contains('come online'));

    final alice = room.join('alice');
    alice.store.books[bookHash] = book;
    alice.service.holdBook(bookHash);
    room.announceHolder('alice', bookHash);

    await room.waitFor(() => bob.store.books.containsKey(bookHash));
  });

  test('a stalled holder is replaced by another one', () async {
    final room = TransferRoom();
    addTearDown(room.dispose);
    // "alice" sorts first and is asked first, but never answers.
    room.join('alice').service.dispose();
    room.announceHolder('alice', bookHash);
    final carol = room.join('carol');
    carol.store.books[bookHash] = book;
    carol.service.holdBook(bookHash);
    room.announceHolder('carol', bookHash);

    final bob = room.join('bob');
    bob.service.expectBook(bookHash);

    await room.waitFor(() => bob.store.books.containsKey(bookHash));
    expect(room.requests.map((r) => r['sender_id']), contains('carol'));
  });

  test('a damaged book is thrown away and asked for again', () async {
    final room = TransferRoom();
    addTearDown(room.dispose);
    final alice = room.join('alice');
    final bob = room.join('bob');
    bob.service.expectBook(bookHash);

    room.corruptNextChunk = true;
    await alice.share(book, bookHash);

    await room.waitFor(() => bob.store.books.containsKey(bookHash));
    expect(bob.store.books[bookHash], book);
  });

  test('a stalled receive never blocks sharing another book', () async {
    // Regression: a stuck receive left Share Book disabled ("A file transfer
    // is already active"), so the room could not recover.
    final room = TransferRoom();
    addTearDown(room.dispose);
    final bob = room.join('bob');
    bob.service.expectBook(bookHash);
    expect(bob.service.currentState.isActive, isTrue);

    final other = Uint8List.fromList(List.generate(5000, (i) => i % 7));
    final otherHash = sha256.convert(other).toString();
    await bob.service.shareBook(fileBytes: other, bookHash: otherHash);

    expect(bob.service.heldBookHash, otherHash);
  });

  test(
    'sharing rejects a file over the limit or with the wrong hash',
    () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice');

      await expectLater(
        alice.service.shareBook(
          fileBytes: Uint8List(AppConstants.maxFileSize + 1),
          bookHash: List.filled(64, '0').join(),
        ),
        throwsArgumentError,
      );
      await expectLater(
        alice.service.shareBook(
          fileBytes: book,
          bookHash: List.filled(64, 'a').join(),
        ),
        throwsArgumentError,
      );
    },
  );

  test('initialize installs its subscriptions once', () async {
    final room = TransferRoom();
    addTearDown(room.dispose);
    final alice = room.join('alice');
    alice.service.initialize();
    expect(alice.service.subscriptionCount, 3);
    await alice.service.dispose();
    expect(alice.service.subscriptionCount, 0);
  });
}

class MemoryStore implements BookBytesStore {
  final Map<String, Uint8List> books = {};

  @override
  Future<Uint8List?> readBook(String hash) async => books[hash];

  @override
  Future<void> saveBook(String hash, Uint8List bytes) async {
    books[hash] = bytes;
  }
}

class TransferClient {
  final String userId;
  final FileTransferService service;
  final MemoryStore store;
  final TransferTransport transport;

  TransferClient(this.userId, this.service, this.store, this.transport);

  Future<void> share(Uint8List bytes, String hash) async {
    store.books[hash] = bytes;
    transport.room.announceHolder(userId, hash);
    await service.shareBook(fileBytes: bytes, bookHash: hash);
  }
}

class TransferRoom {
  final Map<String, TransferClient> clients = {};
  final Map<String, Set<String>> _holdings = {};
  final List<Map<String, dynamic>> requests = [];
  bool dropChunks = false;
  Set<int> dropChunkIndices = {};
  bool corruptNextChunk = false;

  TransferClient join(String userId) {
    final store = MemoryStore();
    final transport = TransferTransport(this, userId);
    final service = FileTransferService(
      transport: transport,
      store: store,
      currentUserId: userId,
      chunkDelay: const Duration(milliseconds: 1),
      firstRequestDelay: const Duration(milliseconds: 10),
      stallTimeout: const Duration(milliseconds: 25),
    );
    service.initialize();
    _holdings.putIfAbsent(userId, () => {});
    final client = TransferClient(userId, service, store, transport);
    clients[userId] = client;
    _presenceChanged();
    return client;
  }

  void announceHolder(String userId, String hash) {
    _holdings.putIfAbsent(userId, () => {}).add(hash);
    _presenceChanged();
  }

  List<Map<String, dynamic>> presence() => [
    for (final entry in _holdings.entries)
      {
        'user_id': entry.key,
        'nickname': entry.key,
        'has_book': entry.value.isNotEmpty,
        'ready_book_hashes': entry.value.toList(),
      },
  ];

  void deliver(String event, Map<String, dynamic> payload) {
    if (event == FileTransferService.requestEvent) requests.add(payload);
    if (event == FileTransferService.chunkEvent) {
      if (dropChunks ||
          dropChunkIndices.contains(payload['chunk_index'] as int)) {
        return;
      }
      if (corruptNextChunk) {
        corruptNextChunk = false;
        // Same length, wrong bytes: only the final hash check can tell.
        final data = payload['data'] as String;
        payload = {...payload, 'data': 'AAAA${data.substring(4)}'};
      }
    }
    for (final client in clients.values) {
      final copy = Map<String, dynamic>.from(payload);
      scheduleMicrotask(() => client.transport.receive(event, copy));
    }
  }

  void _presenceChanged() {
    for (final client in clients.values) {
      scheduleMicrotask(() => client.transport.presenceTick());
    }
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not reached in time');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> dispose() async {
    for (final client in clients.values) {
      await client.service.dispose();
      await client.transport.close();
    }
  }
}

class TransferTransport implements BookTransferTransport {
  final TransferRoom room;
  final String userId;
  final Map<String, StreamController<Map<String, dynamic>>> _controllers = {};
  final _presence = StreamController<Map<String, dynamic>>.broadcast();

  TransferTransport(this.room, this.userId);

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) =>
      (_controllers[event] ??=
              StreamController<Map<String, dynamic>>.broadcast())
          .stream;

  @override
  Stream<Map<String, dynamic>> get presenceStream => _presence.stream;

  @override
  List<Map<String, dynamic>> getOnlineUsers() => room.presence();

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    room.deliver(event, payload);
  }

  void receive(String event, Map<String, dynamic> payload) {
    final controller = _controllers[event];
    if (controller != null && !controller.isClosed) controller.add(payload);
  }

  void presenceTick() {
    if (!_presence.isClosed) _presence.add({'event': 'sync'});
  }

  Future<void> close() async {
    await _presence.close();
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }
}
