import 'dart:async';

import 'package:flutter/foundation.dart';

/// Asks the credentials function for ICE servers; null when it has none.
typedef IceCredentialsFetch = Future<Object?> Function();

/// The STUN / TURN servers a direct book transfer connects through (GH-60).
///
/// TURN credentials come from our Edge Function, which keeps the Cloudflare
/// key on the server and hands out short-lived ones. Until it answers — or
/// when it is not deployed — connections use Cloudflare's free STUN server
/// alone: devices that can reach each other still connect, the rest fall
/// back to Realtime.
class IceServerSource {
  static const stunOnly = <Map<String, dynamic>>[
    {'urls': 'stun:stun.cloudflare.com:3478'},
  ];

  /// Credentials are fetched again this long before the function says they
  /// expire, so a connection never starts on ones about to run out.
  static const refreshMargin = Duration(minutes: 5);

  /// After a failed fetch, how long STUN alone is used before asking again.
  static const retryDelay = Duration(minutes: 1);

  IceServerSource(this._fetch, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final IceCredentialsFetch _fetch;
  final DateTime Function() _clock;
  List<Map<String, dynamic>>? _servers;
  DateTime? _validUntil;
  Future<List<Map<String, dynamic>>>? _inFlight;

  Future<List<Map<String, dynamic>>> get() {
    final servers = _servers;
    final validUntil = _validUntil;
    if (servers != null &&
        validUntil != null &&
        _clock().isBefore(validUntil)) {
      return Future.value(servers);
    }
    // Several connections starting together share one request.
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<List<Map<String, dynamic>>> _refresh() async {
    try {
      final parsed = parseIceResponse(await _fetch());
      if (parsed != null) {
        _servers = parsed.servers;
        _validUntil = _clock().add(parsed.ttl - refreshMargin);
        return parsed.servers;
      }
    } catch (error) {
      debugPrint('TURN credentials unavailable, using STUN only: $error');
    }
    _servers = stunOnly;
    _validUntil = _clock().add(retryDelay);
    return stunOnly;
  }
}

/// The function's answer: `{"iceServers": [...], "ttl": seconds}`. Anything
/// else is null. Each server keeps only `urls`, `username` and `credential`,
/// and needs at least one `stun:`, `turn:` or `turns:` URL.
({List<Map<String, dynamic>> servers, Duration ttl})? parseIceResponse(
  Object? response,
) {
  if (response is! Map) return null;
  final listed = response['iceServers'];
  final ttl = response['ttl'];
  if (listed is! List ||
      ttl is! num ||
      ttl <= IceServerSource.refreshMargin.inSeconds) {
    return null;
  }
  final servers = <Map<String, dynamic>>[];
  for (final entry in listed) {
    if (entry is! Map) continue;
    final rawUrls = entry['urls'];
    final urls = [
      if (rawUrls is String) rawUrls,
      if (rawUrls is List) ...rawUrls.whereType<String>(),
    ].where(_isIceUrl).toList();
    if (urls.isEmpty) continue;
    final username = entry['username'];
    final credential = entry['credential'];
    servers.add({
      'urls': urls,
      if (username is String) 'username': username,
      if (credential is String) 'credential': credential,
    });
  }
  if (servers.isEmpty) return null;
  return (servers: servers, ttl: Duration(seconds: ttl.toInt()));
}

bool _isIceUrl(String url) =>
    url.startsWith('stun:') ||
    url.startsWith('turn:') ||
    url.startsWith('turns:');
