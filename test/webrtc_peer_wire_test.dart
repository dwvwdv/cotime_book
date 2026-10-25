import 'package:cotime_book/services/webrtc_peer_wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  test('a connection that already failed is still released on close', () async {
    // Regression: the failure marked the wire closed, and close() returned
    // early, leaving the native connection behind after every failed or
    // remotely ended transfer.
    final connection = FakeConnection();
    final wire = WebRtcPeerWire.forConnection(connection);

    connection.fire(
      'onConnectionState',
      RTCPeerConnectionState.RTCPeerConnectionStateFailed,
    );
    await expectLater(wire.opened, throwsA(anything));
    await wire.close();

    expect(connection.closed, isTrue);
    expect(connection.disposed, isTrue);
  });

  test('closing twice releases the connection once', () async {
    final connection = FakeConnection();
    final wire = WebRtcPeerWire.forConnection(connection);

    await wire.close();
    await wire.close();

    expect(connection.closeCalls, 1);
  });
}

/// Just enough of a native peer connection to watch it being released.
class FakeConnection implements RTCPeerConnection {
  final Map<String, Object?> _callbacks = {};
  bool closed = false;
  bool disposed = false;
  int closeCalls = 0;

  void fire(String callback, Object? argument) {
    (_callbacks[callback]! as Function)(argument);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    closed = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) {
      final name = invocation.memberName.toString();
      // Symbol("onConnectionState=") → onConnectionState
      final setter = name.substring('Symbol("'.length, name.length - 3);
      _callbacks[setter] = invocation.positionalArguments.first;
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}
