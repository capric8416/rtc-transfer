import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum SignalingRole { host, peer, presence }

class SignalingService {
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  Future<void> connect({
    required String baseUrl,
    required String identifier,
    required SignalingRole role,
    required String clientIdentifier,
    required String hostToken,
  }) async {
    await close();
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
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 12));
    _socket = socket;
    _subscription = socket.listen(
      (data) {
        if (data is! String) return;
        try {
          _messages.add(jsonDecode(data) as Map<String, dynamic>);
        } catch (_) {
          _messages.add({'type': 'error', 'message': '信令消息格式错误'});
        }
      },
      onError: (Object error) =>
          _messages.add({'type': 'error', 'message': error.toString()}),
      onDone: () => _messages.add({'type': 'signaling_closed'}),
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
