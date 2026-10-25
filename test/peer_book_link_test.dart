import 'dart:async';
import 'dart:typed_data';

import 'package:cotime_book/services/file_transfer_service.dart';
import 'package:cotime_book/services/peer_book_link.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Several send windows' worth, so the sender has to wait for acks.
  final book = Uint8List.fromList(
    List.generate(
      SignalingBookPeerLink.sendWindow * 2 + 12345,
      (i) => (i * 7) % 251,
    ),
  );
  final bookHash = sha256.convert(book).toString();

  late PeerNetwork network;

  setUp(() => network = PeerNetwork());
  tearDown(() => network.dispose());

  test('a book goes from the holder to the receiver in one piece', () async {
    final alice = network.join('alice');
    alice.serve(bookHash, () async => book);
    final bob = network.join('bob');

    final progress = <int>[];
    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (received, total) {
        expect(total, book.length);
        progress.add(received);
      },
    );

    expect(await fetch.bytes, book);
    expect(progress.first, 0);
    expect(progress.last, book.length);
    // Only the connection details went through the room.
    expect(network.signals.map((s) => s['kind']), ['offer', 'answer']);
    expect(network.signals.every((s) => !s.containsKey('data')), isTrue);
  });

  test('only the first of the holder\'s devices to answer is used', () async {
    // One person with the book on two devices: both see the offer.
    final phone = network.join('alice');
    final tablet = network.join('alice');
    phone.serve(bookHash, () async => book);
    tablet.serve(bookHash, () async => book);
    final bob = network.join('bob');

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );

    expect(await fetch.bytes, book);
    expect(network.signals.where((s) => s['kind'] == 'answer'), hasLength(2));
    // The device that lost the race does not keep its connection open.
    await network.waitFor(
      () => phone.activeServeCount + tablet.activeServeCount == 0,
    );
  });

  test(
    'a busy holder says so instead of leaving the receiver waiting',
    () async {
      final alice = network.join('alice');
      final gate = Completer<void>();
      alice.serve(bookHash, () async {
        await gate.future;
        return book;
      });
      final receivers = [
        for (var i = 0; i <= SignalingBookPeerLink.maxServes; i++)
          network.join('reader$i'),
      ];
      final fetches = [
        for (final receiver in receivers)
          receiver.fetch(
            bookHash: bookHash,
            holderId: 'alice',
            onProgress: (_, _) {},
          ),
      ];

      await expectLater(
        fetches.last.bytes,
        throwsA(
          isA<PeerBookException>().having(
            (e) => e.message,
            'message',
            contains('busy'),
          ),
        ),
      );
      gate.complete();
      for (final fetch in fetches.take(SignalingBookPeerLink.maxServes)) {
        expect(await fetch.bytes, book);
      }
    },
  );

  test('a holder that does not have the book never answers', () async {
    final alice = network.join('alice');
    alice.serve(List.filled(64, 'a').join(), () async => book);
    final bob = network.join('bob');

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );
    await network.settle();
    expect(network.signals.where((s) => s['kind'] == 'answer'), isEmpty);

    fetch.cancel();
    await expectLater(fetch.bytes, throwsA(isA<PeerBookException>()));
  });

  test('a damaged book is not handed over', () async {
    final alice = network.join('alice');
    alice.serve(bookHash, () async => book);
    final bob = network.join('bob');
    network.corruptNextBytes = true;

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );

    await expectLater(
      fetch.bytes,
      throwsA(
        isA<PeerBookException>().having(
          (e) => e.message,
          'message',
          contains('damaged'),
        ),
      ),
    );
  });

  test(
    'a holder that moves to another book stops sending the old one',
    () async {
      final alice = network.join('alice');
      alice.serve(bookHash, () async => book);
      final bob = network.join('bob');
      // Hold the receiver's first ack back so the send stops at the window.
      network.holdAcks = true;

      final fetch = bob.fetch(
        bookHash: bookHash,
        holderId: 'alice',
        onProgress: (_, _) {},
      );
      await network.waitFor(() => alice.activeServeCount == 1);
      await network.settle();
      alice.serve(null, () async => null);

      await expectLater(fetch.bytes, throwsA(isA<PeerBookException>()));
      await network.settle();
      expect(alice.activeServeCount, 0);
    },
  );

  test('cancelling a fetch closes its connection', () async {
    final alice = network.join('alice');
    alice.serve(bookHash, () async => book);
    final bob = network.join('bob');
    network.holdAcks = true;

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );
    await network.waitFor(() => alice.activeServeCount == 1);
    fetch.cancel();

    await expectLater(fetch.bytes, throwsA(isA<PeerBookException>()));
    await network.waitFor(() => network.openWires == 0);
    // The holder sees the connection close and lets go too.
    await network.waitFor(() => alice.activeServeCount == 0);
  });

  test('a wire that is made after its fetch was cancelled is closed', () async {
    // Regression: cancelling while the ICE servers were still being fetched
    // left the wire that came afterwards open, holding a native connection.
    final alice = network.join('alice');
    alice.serve(bookHash, () async => book);
    final bob = network.join('bob');
    final gate = network.wireGates['bob'] = Completer<void>();

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );
    fetch.cancel();
    await expectLater(fetch.bytes, throwsA(isA<PeerBookException>()));
    gate.complete();

    await network.waitFor(() => network.wiresMade == 1);
    await network.waitFor(() => network.openWires == 0);
  });

  test('a wire that is made after its send was stopped is closed', () async {
    final alice = network.join('alice');
    alice.serve(bookHash, () async => book);
    final bob = network.join('bob');
    // Alice's wire is only made after she has moved on to no book.
    final gate = network.wireGates['alice'] = Completer<void>();

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );
    await network.waitFor(() => alice.activeServeCount == 1);
    alice.serve(null, () async => null);
    // The stopped send has given up on its wire before the wire exists.
    await network.waitFor(() => alice.activeServeCount == 0);
    gate.complete();

    await network.waitFor(() => network.wiresMade == 2);
    fetch.cancel();
    await expectLater(fetch.bytes, throwsA(isA<PeerBookException>()));
    await network.waitFor(() => network.openWires == 0);
  });

  test('a link that is closed fails its fetches and serves nothing', () async {
    final alice = network.join('alice');
    alice.serve(bookHash, () async => book);
    final bob = network.join('bob');
    await bob.dispose();

    final fetch = bob.fetch(
      bookHash: bookHash,
      holderId: 'alice',
      onProgress: (_, _) {},
    );
    await expectLater(fetch.bytes, throwsA(isA<PeerBookException>()));
    expect(network.signals, isEmpty);
  });
}

/// The room's broadcast plus in-memory "WebRTC": a wire's offer names it, and
/// the answer connects the two.
class PeerNetwork {
  final List<SignalTransport> _members = [];
  final List<Map<String, dynamic>> signals = [];
  final Map<String, MemoryWire> _offers = {};
  final List<SignalingBookPeerLink> _links = [];
  int _nextWire = 0;
  bool corruptNextBytes = false;
  bool holdAcks = false;

  /// A member's wires are only made once their gate completes (slow ICE
  /// servers).
  final Map<String, Completer<void>> wireGates = {};

  int get openWires => _wires.where((wire) => !wire.isClosed).length;
  int get wiresMade => _wires.length;
  final List<MemoryWire> _wires = [];

  SignalingBookPeerLink join(String userId) {
    final transport = SignalTransport(this);
    _members.add(transport);
    final link = SignalingBookPeerLink(
      transport: transport,
      currentUserId: userId,
      createWire: () async {
        await wireGates[userId]?.future;
        final wire = MemoryWire(this, 'wire${_nextWire++}');
        _wires.add(wire);
        return wire;
      },
      serveTimeout: const Duration(milliseconds: 300),
    );
    link.initialize();
    _links.add(link);
    return link;
  }

  void deliver(SignalTransport from, Map<String, dynamic> payload) {
    signals.add(payload);
    for (final member in _members) {
      if (identical(member, from)) continue;
      final copy = Map<String, dynamic>.from(payload);
      scheduleMicrotask(() => member.receive(copy));
    }
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> dispose() async {
    for (final link in _links) {
      await link.dispose();
    }
    for (final member in _members) {
      await member.close();
    }
  }
}

class SignalTransport implements BookTransferTransport {
  SignalTransport(this.network);

  final PeerNetwork network;
  final _signals = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) {
    expect(event, SignalingBookPeerLink.signalEvent);
    return _signals.stream;
  }

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    expect(event, SignalingBookPeerLink.signalEvent);
    network.deliver(this, payload);
  }

  void receive(Map<String, dynamic> payload) {
    if (!_signals.isClosed) _signals.add(payload);
  }

  Future<void> close() => _signals.close();

  @override
  List<Map<String, dynamic>> getOnlineUsers() => const [];

  @override
  Stream<Map<String, dynamic>> get presenceStream => const Stream.empty();
}

class MemoryWire implements PeerWire {
  MemoryWire(this.network, this.id) {
    _opened.future.ignore();
  }

  final PeerNetwork network;
  final String id;
  final _opened = Completer<void>();
  final _messages = StreamController<PeerWireMessage>();
  MemoryWire? _peer;
  bool isClosed = false;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<PeerWireMessage> get messages => _messages.stream;

  @override
  Future<String> createOffer() async {
    network._offers[id] = this;
    return 'offer:$id';
  }

  @override
  Future<String> answerOffer(String offer) async {
    final offerer = network._offers[offer.substring('offer:'.length)];
    if (offerer == null) throw StateError('unknown offer');
    network._offers['answer:$id'] = this;
    _peer = offerer;
    return 'answer:$id:${offerer.id}';
  }

  @override
  Future<void> acceptAnswer(String answer) async {
    final parts = answer.split(':');
    final answerer = network._offers['answer:${parts[1]}'];
    // An answer from a device that lost the race connects to nothing.
    if (answerer == null || answerer._peer != this || _peer != null) return;
    _peer = answerer;
    scheduleMicrotask(() {
      if (!isClosed && !answerer.isClosed) {
        _opened.complete();
        answerer._opened.complete();
      }
    });
  }

  @override
  Future<void> sendText(String text) async {
    if (network.holdAcks && text.contains('"ack"')) return;
    _send(PeerWireMessage.text(text));
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    var data = Uint8List.fromList(bytes);
    if (network.corruptNextBytes) {
      network.corruptNextBytes = false;
      data[0] ^= 0xff;
    }
    _send(PeerWireMessage.bytes(data));
  }

  void _send(PeerWireMessage message) {
    final peer = _peer;
    if (isClosed || peer == null || !_opened.isCompleted) {
      throw const PeerBookException('the channel is not open');
    }
    scheduleMicrotask(() {
      if (!peer._messages.isClosed) peer._messages.add(message);
    });
  }

  @override
  Future<void> close() async {
    if (isClosed) return;
    isClosed = true;
    if (!_opened.isCompleted) {
      _opened.completeError(const PeerBookException('closed'));
    }
    unawaited(_messages.close());
    final peer = _peer;
    if (peer != null && !peer.isClosed) {
      scheduleMicrotask(() => peer.close());
    }
  }
}
