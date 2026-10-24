import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../config/app_constants.dart';
import 'file_transfer_service.dart';

/// One end of a direct connection between two devices: a reliable, ordered
/// data channel. The WebRTC one is [WebRtcPeerWire]; tests use in-memory ones.
abstract interface class PeerWire {
  /// The fetching side: opens the channel and returns the offer, with its
  /// candidates already in it (no trickle: one signal each way).
  Future<String> createOffer();

  /// The serving side: returns the answer to [offer], candidates included.
  Future<String> answerOffer(String offer);

  /// The fetching side: the serving device's answer arrived.
  Future<void> acceptAnswer(String answer);

  /// Completes when the channel is open; fails if the connection does.
  Future<void> get opened;

  /// What the other device sent. Done when the channel closes.
  Stream<PeerWireMessage> get messages;

  Future<void> sendText(String text);

  Future<void> sendBytes(Uint8List bytes);

  Future<void> close();
}

class PeerWireMessage {
  const PeerWireMessage.text(String this.text) : bytes = null;

  const PeerWireMessage.bytes(Uint8List this.bytes) : text = null;

  final String? text;
  final Uint8List? bytes;
}

typedef PeerWireFactory = Future<PeerWire> Function();

class PeerBookException implements Exception {
  const PeerBookException(this.message);

  final String message;

  @override
  String toString() => 'PeerBookException: $message';
}

/// [BookPeerLink] over [PeerWire]s, negotiated through room broadcasts (GH-60).
///
/// Only the connection details go through Realtime — one offer, one answer.
/// The book itself goes device to device (through a TURN relay when the two
/// cannot reach each other), so it never passes through or stays on our
/// servers, and does not count against the Realtime quota (#35).
///
/// Wire format on the channel, all JSON text except the book:
///
/// * serving → fetching: `{"type": "book", "book_hash", "size"}`, then the
///   book as binary messages of [messageSize] bytes.
/// * fetching → serving: `{"type": "ack", "received"}` every [ackInterval]
///   bytes, `{"type": "done"}` once the book checks out.
///
/// The sender keeps at most [sendWindow] bytes unacknowledged. Flow control
/// is ours rather than the channel's `bufferedAmount`, which the native plugin
/// only reports after the fact.
class SignalingBookPeerLink implements BookPeerLink {
  static const signalEvent = 'book_peer_signal';

  // 16KB is the message size every WebRTC stack delivers in one piece.
  static const messageSize = 16 * 1024;
  static const ackInterval = 256 * 1024;
  static const sendWindow = 1024 * 1024;

  /// Receivers served at once. More are told this device is busy, so they ask
  /// another holder instead of waiting on a queue they cannot see.
  static const maxServes = 3;

  /// How long a serving device waits on the other side at each step (the
  /// channel to open, the next ack, the final done) before giving up.
  static const defaultServeTimeout = Duration(seconds: 30);

  final BookTransferTransport _transport;
  final String _currentUserId;
  final PeerWireFactory _createWire;
  final Duration _serveTimeout;

  /// Which of this user's devices is talking: one person can hold the book on
  /// two devices, and both see an offer addressed to them.
  final String _peerId = const Uuid().v4();

  StreamSubscription<Map<String, dynamic>>? _signals;
  final Map<String, _Fetch> _fetches = {};
  final Map<String, _Serve> _serves = {};
  String? _servedHash;
  Future<Uint8List?> Function()? _read;
  bool _disposed = false;

  SignalingBookPeerLink({
    required BookTransferTransport transport,
    required String currentUserId,
    required PeerWireFactory createWire,
    Duration serveTimeout = defaultServeTimeout,
  }) : _transport = transport,
       _currentUserId = currentUserId,
       _createWire = createWire,
       _serveTimeout = serveTimeout;

  int get activeServeCount => _serves.length;

  @override
  void initialize() {
    if (_disposed || _signals != null) return;
    _signals = _transport.broadcastStream(signalEvent).listen(_onSignal);
  }

  @override
  BookPeerFetch fetch({
    required String bookHash,
    required String holderId,
    required void Function(int received, int total) onProgress,
  }) {
    final fetch = _Fetch(
      session: const Uuid().v4(),
      hash: bookHash.toLowerCase(),
      holderId: holderId,
      onProgress: onProgress,
    );
    if (_disposed) {
      fetch.abort(const PeerBookException('closed'));
    } else {
      _fetches[fetch.session] = fetch;
      unawaited(_runFetch(fetch));
    }
    return BookPeerFetch(
      fetch.result.future,
      () => fetch.abort(const PeerBookException('cancelled')),
    );
  }

  @override
  void serve(String? bookHash, Future<Uint8List?> Function() read) {
    final hash = bookHash?.toLowerCase();
    _servedHash = hash;
    _read = read;
    // A device that moved to another book stops sending the old one.
    for (final serve in _serves.values) {
      if (serve.hash != hash) {
        serve.abort(const PeerBookException('book changed'));
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _servedHash = null;
    _read = null;
    for (final run in [..._fetches.values, ..._serves.values]) {
      run.abort(const PeerBookException('closed'));
    }
    await _signals?.cancel();
    _signals = null;
  }

  // ---------------------------------------------------------------------------
  // Fetching

  Future<void> _runFetch(_Fetch fetch) async {
    PeerWire? wire;
    try {
      wire = await _openWire(fetch);
      final offer = await fetch.until(wire.createOffer());
      await fetch.until(
        _transport.broadcast(
          event: signalEvent,
          payload: {
            'kind': 'offer',
            'session': fetch.session,
            'from_user': _currentUserId,
            'from_peer': _peerId,
            'to_user': fetch.holderId,
            'book_hash': fetch.hash,
            'sdp': offer,
          },
        ),
      );
      final answer = await fetch.until(fetch.answer.future);
      await fetch.until(wire.acceptAnswer(answer));
      await fetch.until(wire.opened);
      final bytes = await fetch.until(_receive(fetch, wire));
      try {
        await wire.sendText(jsonEncode({'type': 'done'}));
      } catch (_) {
        // The sender treats the channel closing as the end too.
      }
      fetch.succeed(bytes);
    } catch (error) {
      fetch.abort(error);
    } finally {
      _fetches.remove(fetch.session);
      await _closeQuietly(wire);
    }
  }

  Future<Uint8List> _receive(_Fetch fetch, PeerWire wire) {
    final done = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    int? size;
    var received = 0;
    var acked = 0;

    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    final subscription = wire.messages.listen(
      (message) {
        if (done.isCompleted) return;
        final expected = size;
        if (expected == null) {
          final header = _decode(message.text);
          final headerSize = header?['size'];
          if (header?['type'] != 'book' ||
              header?['book_hash'] != fetch.hash ||
              headerSize is! int ||
              headerSize <= 0 ||
              headerSize > AppConstants.maxFileSize) {
            fail(const PeerBookException('unexpected header'));
            return;
          }
          size = headerSize;
          fetch.onProgress(0, headerSize);
          return;
        }
        final chunk = message.bytes;
        if (chunk == null || received + chunk.length > expected) {
          fail(const PeerBookException('unexpected data'));
          return;
        }
        builder.add(chunk);
        received += chunk.length;
        fetch.onProgress(received, expected);
        if (received == expected) {
          final bytes = builder.takeBytes();
          if (sha256.convert(bytes).toString() != fetch.hash) {
            fail(const PeerBookException('the book arrived damaged'));
          } else {
            done.complete(bytes);
          }
        } else if (received - acked >= ackInterval) {
          acked = received;
          unawaited(
            wire
                .sendText(jsonEncode({'type': 'ack', 'received': received}))
                .catchError((Object _) {}),
          );
        }
      },
      onError: fail,
      onDone: () => fail(const PeerBookException('the connection closed')),
    );
    return done.future.whenComplete(subscription.cancel);
  }

  // ---------------------------------------------------------------------------
  // Signals

  void _onSignal(Map<String, dynamic> payload) {
    if (_disposed || payload['to_user'] != _currentUserId) return;
    final session = payload['session'];
    if (session is! String) return;
    switch (payload['kind']) {
      case 'offer':
        _onOffer(session, payload);
      case 'answer':
        final fetch = _addressedFetch(session, payload);
        final sdp = payload['sdp'];
        // The first of the holder's devices to answer is the one used.
        if (fetch != null && sdp is String && !fetch.answer.isCompleted) {
          fetch.answer.complete(sdp);
        }
      case 'reject':
        final fetch = _addressedFetch(session, payload);
        if (fetch != null && !fetch.answer.isCompleted) {
          fetch.answer.completeError(
            PeerBookException('declined: ${payload['reason']}'),
          );
        }
    }
  }

  _Fetch? _addressedFetch(String session, Map<String, dynamic> payload) {
    final fetch = _fetches[session];
    if (fetch == null ||
        payload['to_peer'] != _peerId ||
        payload['from_user'] != fetch.holderId) {
      return null;
    }
    return fetch;
  }

  void _onOffer(String session, Map<String, dynamic> payload) {
    final hash = _servedHash;
    final read = _read;
    final offeredHash = payload['book_hash'];
    final sdp = payload['sdp'];
    final fromUser = payload['from_user'];
    final fromPeer = payload['from_peer'];
    if (hash == null ||
        read == null ||
        offeredHash is! String ||
        offeredHash.toLowerCase() != hash ||
        sdp is! String ||
        fromUser is! String ||
        fromPeer is! String ||
        _serves.containsKey(session)) {
      return;
    }
    final reply = <String, dynamic>{
      'session': session,
      'from_user': _currentUserId,
      'from_peer': _peerId,
      'to_user': fromUser,
      'to_peer': fromPeer,
    };
    if (_serves.length >= maxServes) {
      unawaited(_sendSignal({...reply, 'kind': 'reject', 'reason': 'busy'}));
      return;
    }
    final serve = _Serve(session: session, hash: hash);
    _serves[session] = serve;
    unawaited(_runServe(serve, sdp, read, reply));
  }

  // ---------------------------------------------------------------------------
  // Serving

  Future<void> _runServe(
    _Serve serve,
    String offer,
    Future<Uint8List?> Function() read,
    Map<String, dynamic> reply,
  ) async {
    PeerWire? wire;
    StreamSubscription<PeerWireMessage>? subscription;
    try {
      final bytes = await serve.until(read());
      if (bytes == null || _servedHash != serve.hash) {
        throw const PeerBookException('the book is not here');
      }
      wire = await _openWire(serve);
      final answer = await serve.until(wire.answerOffer(offer));
      await serve.until(
        _sendSignal({...reply, 'kind': 'answer', 'sdp': answer}),
      );
      await serve.until(wire.opened.timeout(_serveTimeout));

      var acked = 0;
      Completer<void>? windowOpen;
      final finished = Completer<void>();
      subscription = wire.messages.listen(
        (message) {
          final signal = _decode(message.text);
          switch (signal?['type']) {
            case 'ack':
              final received = signal?['received'];
              if (received is int && received > acked) acked = received;
              if (windowOpen?.isCompleted == false) windowOpen!.complete();
            case 'done':
              if (!finished.isCompleted) finished.complete();
          }
        },
        onError: (Object error) => serve.abort(error),
        onDone: () {
          // Closing after the whole book went out is how a receiver that
          // could not send "done" says it is done.
          if (!finished.isCompleted) finished.complete();
          serve.abort(const PeerBookException('the connection closed'));
        },
      );

      await serve.until(
        wire.sendText(
          jsonEncode({
            'type': 'book',
            'book_hash': serve.hash,
            'size': bytes.length,
          }),
        ),
      );
      for (var offset = 0; offset < bytes.length; offset += messageSize) {
        while (offset - acked >= sendWindow) {
          windowOpen = Completer<void>();
          await serve.until(windowOpen.future.timeout(_serveTimeout));
        }
        final end = math.min(offset + messageSize, bytes.length);
        await serve.until(
          wire.sendBytes(Uint8List.sublistView(bytes, offset, end)),
        );
      }
      await serve.until(finished.future.timeout(_serveTimeout));
    } catch (error) {
      if (error is! PeerBookException ||
          error.message != 'the connection closed') {
        debugPrint('Direct book send ended: $error');
      }
    } finally {
      _serves.remove(serve.session);
      await subscription?.cancel();
      await _closeQuietly(wire);
    }
  }

  /// A wire for [run]. Stopping [run] does not stop the wire being made (the
  /// ICE servers can take a while to fetch), so one that arrives after [run]
  /// was stopped is closed here: nobody else will ever see it.
  Future<PeerWire> _openWire(_Run run) {
    final creating = _createWire();
    unawaited(
      creating.then((wire) {
        if (run.isAborted) unawaited(_closeQuietly(wire));
      }, onError: (Object _) {}),
    );
    return run.until(creating);
  }

  Future<void> _sendSignal(Map<String, dynamic> payload) async {
    try {
      await _transport.broadcast(event: signalEvent, payload: payload);
    } catch (error) {
      // The receiver's own timeout moves it on to another holder.
      debugPrint('Book peer signal not sent: $error');
    }
  }

  Map<String, dynamic>? _decode(String? text) {
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _closeQuietly(PeerWire? wire) async {
    if (wire == null) return;
    try {
      await wire.close();
    } catch (error) {
      debugPrint('Closing a book peer connection failed: $error');
    }
  }
}

/// Something that can be stopped from outside while it awaits: every await in
/// it goes through [until], which fails as soon as [abort] is called.
abstract class _Run {
  final _aborted = Completer<Object>();

  bool get isAborted => _aborted.isCompleted;

  void abort(Object error) {
    if (!_aborted.isCompleted) _aborted.complete(error);
  }

  Future<T> until<T>(Future<T> future) {
    if (isAborted) {
      future.ignore();
      return _aborted.future.then<T>((error) => Future<T>.error(error));
    }
    return Future.any<T>([
      future,
      _aborted.future.then<T>((error) => Future<T>.error(error)),
    ]);
  }
}

class _Fetch extends _Run {
  _Fetch({
    required this.session,
    required this.hash,
    required this.holderId,
    required this.onProgress,
  }) {
    // Nobody may be listening when these fail (the fetch was cancelled first).
    answer.future.ignore();
    result.future.ignore();
  }

  final String session;
  final String hash;
  final String holderId;
  final void Function(int received, int total) onProgress;
  final answer = Completer<String>();
  final result = Completer<Uint8List>();

  void succeed(Uint8List bytes) {
    if (!result.isCompleted) result.complete(bytes);
  }

  @override
  void abort(Object error) {
    super.abort(error);
    if (!result.isCompleted) result.completeError(error);
  }
}

class _Serve extends _Run {
  _Serve({required this.session, required this.hash});

  final String session;
  final String hash;
}
