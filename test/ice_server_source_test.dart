import 'package:cotime_book/services/ice_server_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> credentials({int ttl = 3600}) => {
    'iceServers': [
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {
        'urls': [
          'turn:turn.cloudflare.com:3478?transport=udp',
          'turns:turn.cloudflare.com:443?transport=tcp',
          'https://example.com/not-ice',
        ],
        'username': 'user',
        'credential': 'secret',
        'extra': 'dropped',
      },
    ],
    'ttl': ttl,
  };

  test('TURN servers from the credentials function are used', () async {
    final source = IceServerSource(() async => credentials());

    final servers = await source.get();

    expect(servers, hasLength(2));
    expect(servers[1], {
      'urls': [
        'turn:turn.cloudflare.com:3478?transport=udp',
        'turns:turn.cloudflare.com:443?transport=tcp',
      ],
      'username': 'user',
      'credential': 'secret',
    });
  });

  test('credentials are reused until shortly before they expire', () async {
    var now = DateTime.utc(2026, 10, 24);
    var calls = 0;
    final source = IceServerSource(() async {
      calls++;
      return credentials();
    }, clock: () => now);

    await Future.wait([source.get(), source.get()]);
    expect(calls, 1);

    now = now.add(const Duration(minutes: 50));
    await source.get();
    expect(calls, 1);

    now = now.add(const Duration(minutes: 6));
    await source.get();
    expect(calls, 2);
  });

  test(
    'without the function, STUN alone is used and asked again later',
    () async {
      var now = DateTime.utc(2026, 10, 24);
      var calls = 0;
      final source = IceServerSource(() async {
        calls++;
        throw Exception('FunctionException(404)');
      }, clock: () => now);

      expect(await source.get(), IceServerSource.stunOnly);
      expect(await source.get(), IceServerSource.stunOnly);
      expect(calls, 1);

      now = now.add(IceServerSource.retryDelay);
      await source.get();
      expect(calls, 2);
    },
  );

  test('a malformed answer is not used', () {
    expect(parseIceResponse(null), isNull);
    expect(parseIceResponse('nope'), isNull);
    expect(parseIceResponse({'iceServers': [], 'ttl': 3600}), isNull);
    expect(parseIceResponse(credentials(ttl: 60)), isNull);
    expect(
      parseIceResponse({
        'iceServers': [
          {'urls': 'http://example.com'},
        ],
        'ttl': 3600,
      }),
      isNull,
    );
  });
}
