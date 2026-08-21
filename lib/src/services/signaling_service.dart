import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum SignalingRole { host, peer, presence }

class SignalingService {
  static const _heartbeatInterval = Duration(seconds: 15);

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  int _generation = 0;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  bool get isOpen => _socket?.readyState == WebSocket.open;

  Future<void> connect({
    required String baseUrl,
    required String identifier,
    required SignalingRole role,
    required String clientIdentifier,
    required String hostToken,
  }) async {
    await close();
    final generation = _generation;
    final base = Uri.parse(baseUrl);
    if (base.scheme != 'wss') {
      throw const FormatException('信令地址必须使用 wss:// TLS 加密');
    }
    final scheme = base.scheme == 'https'
        ? 'wss'
        : base.scheme == 'http'
        ? 'ws'
        : base.scheme;
    final uri = base.replace(
      scheme: scheme,
      path: '${base.path.replaceAll(RegExp(r'/$'), '')}/signal',
      queryParameters: {
        'identifier': identifier,
        'role': role.name,
        'clientIdentifier': clientIdentifier,
        'hostToken': hostToken,
      },
    );
    late final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
      ).timeout(const Duration(seconds: 12));
    } catch (_) {
      if (generation != _generation) {
        throw const SignalingConnectionCancelled();
      }
      rethrow;
    }
    if (generation != _generation) {
      await socket.close();
      throw const SignalingConnectionCancelled();
    }
    _socket = socket;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (!identical(_socket, socket) || socket.readyState != WebSocket.open) {
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        return;
      }
      socket.add(jsonEncode({'type': 'heartbeat'}));
    });
    _subscription = socket.listen(
      (data) {
        if (data is! String) return;
        try {
          _messages.add(jsonDecode(data) as Map<String, dynamic>);
        } catch (_) {
          _messages.add({'type': 'error', 'message': '信令消息格式错误'});
        }
      },
      onError: (Object error) {
        if (identical(_socket, socket)) {
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          _socket = null;
        }
        _messages.add({'type': 'error', 'message': error.toString()});
      },
      onDone: () {
        if (identical(_socket, socket)) {
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          _socket = null;
          _subscription = null;
        }
        _messages.add({'type': 'signaling_closed'});
      },
    );
  }

  void send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('信令连接尚未建立');
    }
    socket.add(jsonEncode(message));
  }

  Future<void> close() async {
    _generation++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await close();
    await _messages.close();
  }
}

class SignalingConnectionCancelled implements Exception {
  const SignalingConnectionCancelled();

  @override
  String toString() => '信令连接已取消';
}
