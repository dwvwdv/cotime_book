import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'ice_server_source.dart';
import 'peer_book_link.dart';

/// [PeerWire] over a WebRTC data channel (GH-60).
///
/// Candidates are gathered before the offer or answer is handed out, so each
/// side sends a single signal through Realtime instead of one per candidate.
/// [gatherTimeout] bounds that wait: whatever was gathered by then goes out,
/// which is usually enough (host and STUN candidates come within a second;
/// a relay candidate that comes later is the one thing lost).
class WebRtcPeerWire implements PeerWire {
  static const defaultGatherTimeout = Duration(seconds: 4);

  @visibleForTesting
  WebRtcPeerWire.forConnection(
    RTCPeerConnection connection, {
    Duration gatherTimeout = defaultGatherTimeout,
  }) : this._(connection, gatherTimeout);

  WebRtcPeerWire._(this._connection, this._gatherTimeout) {
    _opened.future.ignore();
    _connection.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        final gathered = _gathered;
        if (gathered != null && !gathered.isCompleted) gathered.complete();
      }
    };
    _connection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _end(const PeerBookException('the connection failed'));
      }
    };
    // The serving side gets the channel the fetching side opened.
    _connection.onDataChannel = _attach;
  }

  /// A wire with the ICE servers from [iceServers] (STUN, and TURN when the
  /// credentials function is set up).
  static Future<PeerWire> create(
    IceServerSource iceServers, {
    Duration gatherTimeout = defaultGatherTimeout,
  }) async {
    final servers = await iceServers.get();
    final connection = await createPeerConnection({
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
    });
    return WebRtcPeerWire._(connection, gatherTimeout);
  }

  final RTCPeerConnection _connection;
  final Duration _gatherTimeout;
  final _opened = Completer<void>();
  final _messages = StreamController<PeerWireMessage>();
  RTCDataChannel? _channel;
  Completer<void>? _gathered;

  /// The connection is over: failed, closed by the other side, or by us.
  bool _closed = false;

  /// The native connection has been let go. Separate from [_closed]: a
  /// connection the other side ended is over long before its owner calls
  /// [close], and still holds native resources until then.
  bool _released = false;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<PeerWireMessage> get messages => _messages.stream;

  @override
  Future<String> createOffer() async {
    final channel = await _connection.createDataChannel(
      'book',
      RTCDataChannelInit()..ordered = true,
    );
    _attach(channel);
    final offer = await _connection.createOffer();
    return _setLocal(offer);
  }

  @override
  Future<String> answerOffer(String offer) async {
    await _connection.setRemoteDescription(
      RTCSessionDescription(offer, 'offer'),
    );
    final answer = await _connection.createAnswer();
    return _setLocal(answer);
  }

  @override
  Future<void> acceptAnswer(String answer) {
    return _connection.setRemoteDescription(
      RTCSessionDescription(answer, 'answer'),
    );
  }

  @override
  Future<void> sendText(String text) =>
      _openChannel().send(RTCDataChannelMessage(text));

  @override
  Future<void> sendBytes(Uint8List bytes) =>
      _openChannel().send(RTCDataChannelMessage.fromBinary(bytes));

  @override
  Future<void> close() async {
    if (_released) return;
    _released = true;
    _end(const PeerBookException('closed'));
    try {
      await _channel?.close();
    } catch (error) {
      debugPrint('Closing the book channel failed: $error');
    }
    await _connection.close();
    await _connection.dispose();
  }

  RTCDataChannel _openChannel() {
    final channel = _channel;
    if (_closed || channel == null) {
      throw const PeerBookException('the channel is not open');
    }
    return channel;
  }

  void _attach(RTCDataChannel channel) {
    if (_closed || _channel != null) return;
    _channel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (!_opened.isCompleted) _opened.complete();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _end(const PeerBookException('the connection closed'));
      }
    };
    channel.onMessage = (message) {
      if (_messages.isClosed) return;
      _messages.add(
        message.isBinary
            ? PeerWireMessage.bytes(message.binary)
            : PeerWireMessage.text(message.text),
      );
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_opened.isCompleted) {
      _opened.complete();
    }
  }

  Future<String> _setLocal(RTCSessionDescription description) async {
    final gathered = _gathered = Completer<void>();
    await _connection.setLocalDescription(description);
    final state = await _connection.getIceGatheringState();
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !gathered.isCompleted) {
      gathered.complete();
    }
    await gathered.future.timeout(_gatherTimeout, onTimeout: () {});
    final local = await _connection.getLocalDescription();
    final sdp = local?.sdp;
    if (sdp == null) throw const PeerBookException('no local description');
    return sdp;
  }

  void _end(PeerBookException error) {
    _closed = true;
    if (!_opened.isCompleted) _opened.completeError(error);
    if (!_messages.isClosed) unawaited(_messages.close());
  }
}
