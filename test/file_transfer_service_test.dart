import 'dart:async';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/transfer_state.dart';
import 'package:cotime_book/services/file_transfer_service.dart';
import 'package:cotime_book/services/peer_book_link.dart';
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
    'a receive still running when a new book is shared cannot replace it',
    () async {
      // Regression: sharing H2 left the receive of H1 running; when H1
      // finished it replaced H2 on the sharer, who then could not serve H2.
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice');
      final bob = room.join('bob');
      bob.service.expectBook(bookHash);

      final other = Uint8List.fromList(List.generate(5000, (i) => i % 7));
      final otherHash = sha256.convert(other).toString();
      await bob.share(other, otherHash);
      // The old book keeps arriving.
      await alice.share(book, bookHash);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(bob.service.heldBookHash, otherHash);
      expect(bob.service.wantedBookHash, isNull);
      expect(bob.store.books.containsKey(bookHash), isFalse);
      expect(bob.service.currentState.bookHash, isNot(bookHash));
    },
  );

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

  group('library books', () {
    test('are downloaded instead of asked from the room', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice');
      alice.service.holdBook(bookHash, bytes: book);
      room.announceHolder('alice', bookHash);
      final bob = room.join('bob');

      bob.service.expectBook(bookHash, download: () async => book);

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(bob.service.currentState.status, TransferStatus.completed);
      expect(bob.service.heldBookHash, bookHash);
      // Nobody had to broadcast the book.
      expect(room.requests, isEmpty);
      expect(room.chunksSent, 0);
    });

    test('come from the room when the library download fails', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice');
      alice.service.holdBook(bookHash, bytes: book);
      room.announceHolder('alice', bookHash);
      final bob = room.join('bob');

      bob.service.expectBook(
        bookHash,
        download: () async => throw Exception('offline'),
      );

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(room.requests.single['sender_id'], 'alice');
    });

    test('are not kept when the library copy is a different book', () async {
      // The file in the library was replaced after it was shared.
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice');
      alice.service.holdBook(bookHash, bytes: book);
      room.announceHolder('alice', bookHash);
      final bob = room.join('bob');

      final replaced = Uint8List.fromList(List.generate(5000, (i) => i % 7));
      bob.service.expectBook(bookHash, download: () async => replaced);

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(bob.store.books.length, 1);
    });

    test('a slow library download does not hold the receive up', () async {
      final room = TransferRoom(
        directDownloadGrace: const Duration(milliseconds: 30),
      );
      addTearDown(room.dispose);
      final alice = room.join('alice');
      alice.service.holdBook(bookHash, bytes: book);
      room.announceHolder('alice', bookHash);
      final bob = room.join('bob');

      final never = Completer<Uint8List>();
      bob.service.expectBook(bookHash, download: () => never.future);
      expect(
        bob.service.currentState.message,
        contains('Downloading the book from the library'),
      );

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.service.currentState.status, TransferStatus.completed);
    });

    test('the download is used when the share arrives after the lobby '
        'already expects the book', () async {
      // The lobby expects the room's book as soon as it opens; the share
      // broadcast saying it is a library book can arrive after that.
      final room = TransferRoom();
      addTearDown(room.dispose);
      final bob = room.join('bob');

      bob.service.expectBook(bookHash);
      bob.service.expectBook(bookHash, download: () async => book);

      // Nobody in the room holds it: only the library can provide it.
      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
    });

    test('a download that finishes after another book was shared is '
        'dropped', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final bob = room.join('bob');

      final slow = Completer<Uint8List>();
      bob.service.expectBook(bookHash, download: () => slow.future);

      final other = Uint8List.fromList(List.generate(5000, (i) => i % 7));
      final otherHash = sha256.convert(other).toString();
      await bob.service.shareBook(fileBytes: other, bookHash: otherHash);
      slow.complete(book);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bob.service.heldBookHash, otherHash);
      expect(bob.store.books.containsKey(bookHash), isFalse);
    });
  });

  group('direct transfer (GH-60)', () {
    test('a receiver gets the book straight from the holder, with nothing '
        'broadcast', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);
      final bob = room.join('bob', direct: true);

      await alice.share(book, bookHash);
      bob.service.expectBook(bookHash);

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(bob.service.currentState.status, TransferStatus.completed);
      expect(bob.peerLink!.fetchedFrom, ['alice']);
      expect(room.requests, isEmpty);
      expect(room.chunksSent, 0);
    });

    test('an app that cannot fetch directly still gets a book that was not '
        'pushed', () async {
      // A sharer that sends directly no longer pushes the book; an older app
      // in the room asks for it like a late joiner does.
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);
      final bob = room.join('bob');

      await alice.share(book, bookHash);
      expect(room.chunksSent, 0);
      bob.service.expectBook(bookHash);

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(room.requests.single['sender_id'], 'alice');
    });

    test(
      'a holder whose app cannot send directly is asked over the room',
      () async {
        final room = TransferRoom();
        addTearDown(room.dispose);
        final alice = room.join('alice');
        final bob = room.join('bob', direct: true);

        await alice.share(book, bookHash);
        bob.service.expectBook(bookHash);

        await room.waitFor(() => bob.store.books.containsKey(bookHash));
        expect(bob.peerLink!.fetchedFrom, isEmpty);
      },
    );

    test('a direct fetch that fails falls back to asking the room', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);
      final bob = room.join('bob', direct: true);
      room.peerMode = PeerMode.fail;

      await alice.share(book, bookHash);
      bob.service.expectBook(bookHash);

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(bob.peerLink!.fetchedFrom, ['alice']);
      expect(room.requests, isNotEmpty);
    });

    test('a direct fetch that stalls is given up on', () async {
      // Regression guard: a connection that never opens must not leave the
      // receiver on "Getting the book..." with nobody asking the room.
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);
      final bob = room.join('bob', direct: true);
      room.peerMode = PeerMode.stall;

      await alice.share(book, bookHash);
      bob.service.expectBook(bookHash);
      await room.waitFor(
        () => bob.service.currentState.message?.contains('from alice') == true,
      );

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.peerLink!.cancels, 1);
      expect(room.requests, isNotEmpty);
    });

    test(
      'a slow direct fetch that keeps arriving is not given up on',
      () async {
        final room = TransferRoom(
          peerConnectTimeout: const Duration(milliseconds: 200),
          peerStallTimeout: const Duration(milliseconds: 200),
        );
        addTearDown(room.dispose);
        final alice = room.join('alice', direct: true);
        final bob = room.join('bob', direct: true);
        // Longer than either timeout in total, never quiet for one of them.
        room.peerMode = PeerMode.slow;

        await alice.share(book, bookHash);
        bob.service.expectBook(bookHash);
        await room.waitFor(
          () => bob.service.currentState.status == TransferStatus.transferring,
        );
        expect(bob.service.currentState.totalBytes, book.length);

        await room.waitFor(() => bob.store.books.containsKey(bookHash));
        expect(bob.peerLink!.cancels, 0);
        expect(room.requests, isEmpty);
      },
    );

    test('a damaged direct copy is not kept', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);
      final bob = room.join('bob', direct: true);
      room.peerMode = PeerMode.corrupt;

      await alice.share(book, bookHash);
      bob.service.expectBook(bookHash);

      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      expect(bob.store.books[bookHash], book);
      expect(room.requests, isNotEmpty);
    });

    test(
      'each holder is tried directly once, then the room is asked',
      () async {
        final room = TransferRoom();
        addTearDown(room.dispose);
        final alice = room.join('alice', direct: true);
        final carol = room.join('carol', direct: true);
        final bob = room.join('bob', direct: true);
        room.peerMode = PeerMode.fail;

        await alice.share(book, bookHash);
        carol.store.books[bookHash] = book;
        carol.service.holdBook(bookHash);
        room.announceHolder('carol', bookHash);
        bob.service.expectBook(bookHash);

        await room.waitFor(() => bob.store.books.containsKey(bookHash));
        expect(bob.peerLink!.fetchedFrom, ['alice', 'carol']);
        expect(room.requests, isNotEmpty);
      },
    );

    test('a direct fetch still running when another book is shared is '
        'cancelled and cannot replace it', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);
      final bob = room.join('bob', direct: true);
      room.peerMode = PeerMode.gated;

      await alice.share(book, bookHash);
      bob.service.expectBook(bookHash);
      await room.waitFor(() => bob.peerLink!.fetchedFrom.isNotEmpty);

      final other = Uint8List.fromList(List.generate(5000, (i) => i % 7));
      final otherHash = sha256.convert(other).toString();
      await bob.share(other, otherHash);
      room.peerGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(bob.peerLink!.cancels, 1);
      expect(bob.service.heldBookHash, otherHash);
      expect(bob.store.books.containsKey(bookHash), isFalse);
    });

    test('a member who just received the book sends it on directly', () async {
      // Regression: a finished receive held the book without telling the
      // link, so the next member waited out the connect timeout and fell
      // back to the broadcast.
      final room = TransferRoom();
      addTearDown(room.dispose);
      // An older app: it pushes the book and cannot send it directly.
      final alice = room.join('alice');
      final bob = room.join('bob', direct: true);
      bob.service.expectBook(bookHash);
      await alice.share(book, bookHash);
      await room.waitFor(() => bob.store.books.containsKey(bookHash));
      room.announceHolder('bob', bookHash);
      final requestsBefore = room.requests.length;

      final carol = room.join('carol', direct: true);
      carol.service.expectBook(bookHash);

      await room.waitFor(() => carol.store.books.containsKey(bookHash));
      expect(carol.peerLink!.fetchedFrom, ['bob']);
      expect(room.requests, hasLength(requestsBefore));
    });

    test('the link serves whatever book this device holds', () async {
      final room = TransferRoom();
      addTearDown(room.dispose);
      final alice = room.join('alice', direct: true);

      alice.store.books[bookHash] = book;
      alice.service.holdBook(bookHash);
      expect(alice.peerLink!.servedHash, bookHash);
      expect(await alice.peerLink!.read!(), book);

      alice.service.reset();
      expect(alice.peerLink!.servedHash, isNull);
    });
  });

  test('a 40MB book can be shared', () async {
    // The limit used to be 10MB, which turned away illustrated books.
    final room = TransferRoom();
    addTearDown(room.dispose);
    final alice = room.join('alice');
    final largest = Uint8List(40 * 1024 * 1024);
    final largestHash = sha256.convert(largest).toString();

    await alice.service.shareBook(fileBytes: largest, bookHash: largestHash);

    expect(alice.service.heldBookHash, largestHash);
    expect(room.chunksSent, largest.length ~/ AppConstants.fileChunkSize);
  });

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
  final FakePeerLink? peerLink;

  TransferClient(
    this.userId,
    this.service,
    this.store,
    this.transport, {
    this.peerLink,
  });

  Future<void> share(Uint8List bytes, String hash) async {
    store.books[hash] = bytes;
    transport.room.announceHolder(userId, hash);
    await service.shareBook(fileBytes: bytes, bookHash: hash);
  }
}

class TransferRoom {
  final Duration directDownloadGrace;
  final Duration peerConnectTimeout;
  final Duration peerStallTimeout;
  final Map<String, TransferClient> clients = {};
  final Map<String, Set<String>> _holdings = {};
  final List<Map<String, dynamic>> requests = [];
  bool dropChunks = false;
  Set<int> dropChunkIndices = {};
  bool corruptNextChunk = false;
  int chunksSent = 0;
  PeerMode peerMode = PeerMode.ok;
  final peerGate = Completer<void>();

  TransferRoom({
    this.directDownloadGrace = const Duration(milliseconds: 500),
    this.peerConnectTimeout = const Duration(milliseconds: 30),
    this.peerStallTimeout = const Duration(milliseconds: 30),
  });

  /// [direct]: this member's app sends and fetches books directly.
  TransferClient join(String userId, {bool direct = false}) {
    final store = MemoryStore();
    final transport = TransferTransport(this, userId);
    final peerLink = direct ? FakePeerLink(this) : null;
    final service = FileTransferService(
      transport: transport,
      store: store,
      currentUserId: userId,
      peerLink: peerLink,
      chunkDelay: const Duration(milliseconds: 1),
      firstRequestDelay: const Duration(milliseconds: 10),
      stallTimeout: const Duration(milliseconds: 25),
      directDownloadGrace: directDownloadGrace,
      peerConnectTimeout: peerConnectTimeout,
      peerStallTimeout: peerStallTimeout,
    );
    service.initialize();
    _holdings.putIfAbsent(userId, () => {});
    final client = TransferClient(
      userId,
      service,
      store,
      transport,
      peerLink: peerLink,
    );
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
        if (clients[entry.key]?.peerLink != null)
          'direct_book_hashes': entry.value.toList(),
      },
  ];

  void deliver(String event, Map<String, dynamic> payload) {
    if (event == FileTransferService.requestEvent) requests.add(payload);
    if (event == FileTransferService.chunkEvent) {
      chunksSent++;
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

enum PeerMode {
  ok,

  /// The connection fails at once.
  fail,

  /// Nothing ever arrives.
  stall,

  /// The book arrives in steps, each sooner than the stall timeout.
  slow,

  /// The book arrives, one byte wrong.
  corrupt,

  /// The book arrives once [TransferRoom.peerGate] completes.
  gated,
}

/// Direct transfer between the room's members, without WebRTC.
class FakePeerLink implements BookPeerLink {
  FakePeerLink(this.room);

  final TransferRoom room;
  final List<String> fetchedFrom = [];
  int cancels = 0;
  String? servedHash;
  Future<Uint8List?> Function()? read;

  @override
  void initialize() {}

  @override
  BookPeerFetch fetch({
    required String bookHash,
    required String holderId,
    required void Function(int received, int total) onProgress,
  }) {
    fetchedFrom.add(holderId);
    final result = Completer<Uint8List>();
    result.future.ignore();

    Future<void> run() async {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final holder = room.clients[holderId]?.peerLink;
      final read = holder?.read;
      if (room.peerMode == PeerMode.fail ||
          holder?.servedHash != bookHash ||
          read == null) {
        throw const PeerBookException('could not connect');
      }
      if (room.peerMode == PeerMode.stall) return;
      if (room.peerMode == PeerMode.gated) await room.peerGate.future;
      final bytes = await read();
      if (bytes == null) throw const PeerBookException('no book');
      if (room.peerMode == PeerMode.slow) {
        final step = room.peerStallTimeout ~/ 4;
        for (var part = 0; part < 6; part++) {
          await Future<void>.delayed(step);
          if (result.isCompleted) return;
          onProgress(bytes.length * part ~/ 6, bytes.length);
        }
      }
      onProgress(bytes.length, bytes.length);
      if (room.peerMode == PeerMode.corrupt) {
        final damaged = Uint8List.fromList(bytes)..[0] ^= 0xff;
        if (!result.isCompleted) result.complete(damaged);
        return;
      }
      if (!result.isCompleted) result.complete(bytes);
    }

    run().catchError((Object error) {
      if (!result.isCompleted) result.completeError(error);
    });
    return BookPeerFetch(result.future, () {
      cancels++;
      if (!result.isCompleted) {
        result.completeError(const PeerBookException('cancelled'));
      }
    });
  }

  @override
  void serve(String? bookHash, Future<Uint8List?> Function() read) {
    servedHash = bookHash;
    this.read = bookHash == null ? null : read;
  }

  @override
  Future<void> dispose() async {}
}
