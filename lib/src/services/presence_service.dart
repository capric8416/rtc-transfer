import 'dart:async';
import 'dart:convert';
import 'dart:io';

class PresenceService {
  static const _heartbeatInterval = Duration(seconds: 15);

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  bool _stopped = true;
  bool _connecting = false;
  int _generation = 0;
  String? _signalingUrl;
  String? _identifier;
  String? _hostToken;

  Future<void> start({
    required String signalingUrl,
    required String identifier,
    required String hostToken,
  }) async {
    await stop();
    _stopped = false;
    _signalingUrl = signalingUrl;
    _identifier = identifier;
    _hostToken = hostToken;
    final generation = ++_generation;
    await _connect(generation);
  }

  Future<void> _connect(int generation) async {
    if (_stopped || generation != _generation || _connecting) return;
    _connecting = true;
    try {
      final base = Uri.parse(_signalingUrl!);
      if (base.scheme != 'wss') return;
      final uri = base.replace(
        path: '${base.path.replaceAll(RegExp(r'/$'), '')}/signal',
        queryParameters: {
          'identifier': _identifier!,
          'role': 'presence',
          'clientIdentifier': _identifier!,
          'hostToken': _hostToken!,
        },
      );
      final socket = await WebSocket.connect(
        uri.toString(),
      ).timeout(const Duration(seconds: 12));
      if (_stopped || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
        if (!identical(_socket, socket) ||
            socket.readyState != WebSocket.open) {
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          return;
        }
        socket.add(jsonEncode({'type': 'heartbeat'}));
      });
      _subscription = socket.listen(
        (_) {},
        onError: (_) {
          if (!identical(_socket, socket)) return;
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          _socket = null;
          _subscription = null;
          _scheduleReconnect(generation);
        },
        onDone: () {
          if (!identical(_socket, socket)) return;
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          _socket = null;
          _subscription = null;
          _scheduleReconnect(generation);
        },
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect(generation);
    } finally {
      _connecting = false;
    }
  }

  void _scheduleReconnect(int generation) {
    if (_stopped || generation != _generation) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () {
      _socket = null;
      _subscription = null;
      _connect(generation);
    });
  }

  Future<void> stop() async {
    _stopped = true;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    _connecting = false;
  }

  Future<void> dispose() => stop();

  static Future<bool> isOnline({
    required String signalingUrl,
    required String identifier,
  }) async {
    final base = Uri.parse(signalingUrl);
    if (base.scheme != 'wss') return false;
    final uri = base.replace(
      scheme: 'https',
      path: '${base.path.replaceAll(RegExp(r'/$'), '')}/presence',
      queryParameters: {'identifier': identifier},
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return false;
      final body = await utf8.decoder.bind(response).join();
      return (jsonDecode(body) as Map<String, dynamic>)['online'] == true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
