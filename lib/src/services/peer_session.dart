import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';
import '../models/transfer_task.dart';
import 'receive_storage.dart';
import 'signaling_service.dart';
import 'totp_service.dart';

enum PeerStatus { idle, waiting, connecting, connected, disconnected, error }

enum PeerDirectoryKind { shared, receive }

class TransferOverview {
  TransferOverview({
    required this.id,
    required this.name,
    required this.totalBytes,
    required this.direction,
  });

  final String id;
  final String name;
  final int totalBytes;
  final TransferDirection direction;
  final Stopwatch stopwatch = Stopwatch()..start();
  int transferredBytes = 0;
  String? currentFile;
  String? error;
  TransferState state = TransferState.active;

  double get progress => totalBytes <= 0
      ? (state == TransferState.complete ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0, 1);

  double get bytesPerSecond =>
      transferredBytes * 1000 / max(1, stopwatch.elapsedMilliseconds);
}

class PeerSession extends ChangeNotifier {
  PeerSession({
    required this.sharedRoot,
    required this.receiveDirectory,
    required this.totpSecret,
    this.onPaired,
  });

  static const _chunkSize = 32 * 1024;
  static const _maxBufferedBytes = 1024 * 1024;
  static const _connectionTimeoutDuration = Duration(seconds: 30);
  static const _iceServers = [
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ];

  final String? sharedRoot;
  final String? receiveDirectory;
  final String totpSecret;
  final ValueChanged<String>? onPaired;
  final SignalingService _signaling = SignalingService();
  final List<TransferTask> transfers = [];
  TransferOverview? transferOverview;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  StreamSubscription<void>? _signalSubscription;
  WebSocket? _lanSignalSocket;
  StreamSubscription<dynamic>? _lanSignalSubscription;
  _IncomingFile? _incoming;
  SignalingRole? _role;
  String? _targetIdentifier;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  final Map<String, Completer<void>> _outgoingAcknowledgements = {};
  final Map<String, Completer<void>> _outgoingDirectoryAcknowledgements = {};
  final Map<String, Completer<void>> _outgoingBatchAcknowledgements = {};
  Future<void> _incomingMessageQueue = Future<void>.value();
  Future<void> _lanSignalMessageQueue = Future<void>.value();
  Timer? _connectionTimeout;
  Timer? _hostReconnectTimer;
  String? _hostSignalingUrl;
  String? _hostIdentifier;
  String? _hostToken;
  int _hostReconnectAttempt = 0;
  bool _remoteDescriptionSet = false;
  bool _hasPendingOffer = false;
  bool _initialDirectoryRequested = false;
  String? _pendingDirectoryRequestId;
  String? _outgoingBatchId;
  bool _incomingBatchFailed = false;
  String? _lastRemoteOfferSdp;
  bool _usingLan = false;
  bool _lanAuthenticated = false;
  bool _lanAuthSent = false;
  bool _outgoingTransferActive = false;
  String? _lanTotpCode;
  String? _localIdentifier;
  int _sessionGeneration = 0;

  PeerStatus status = PeerStatus.idle;
  String? errorMessage;
  List<FileEntry> remoteEntries = const [];
  String remoteCurrentPath = '';
  String remoteCurrentDisplayPath = '';
  String? remoteBrowserError;
  PeerDirectoryKind remoteDirectoryKind = PeerDirectoryKind.shared;

  bool get _isDataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
  bool get isConnected => status == PeerStatus.connected && _isDataChannelOpen;
  bool get isPeer => _role == SignalingRole.peer;
  bool get isLanConnection => _usingLan;
  String? get remoteIdentifier => _targetIdentifier;

  Future<void> host({
    required String signalingUrl,
    required String identifier,
    required String hostToken,
  }) async {
    await disconnect();
    _role = SignalingRole.host;
    _hostSignalingUrl = signalingUrl;
    _hostIdentifier = identifier;
    _hostToken = hostToken;
    final generation = _sessionGeneration;
    await _listenToSignals();
    await _connectHost(rethrowOnFailure: true, expectedGeneration: generation);
  }

  Future<void> _connectHost({
    bool rethrowOnFailure = false,
    int? expectedGeneration,
  }) async {
    final generation = expectedGeneration ?? _sessionGeneration;
    final signalingUrl = _hostSignalingUrl;
    final identifier = _hostIdentifier;
    final hostToken = _hostToken;
    if (_role != SignalingRole.host ||
        signalingUrl == null ||
        identifier == null ||
        hostToken == null) {
      return;
    }
    try {
      await _signaling.connect(
        baseUrl: signalingUrl,
        identifier: identifier,
        role: SignalingRole.host,
        clientIdentifier: identifier,
        hostToken: hostToken,
      );
      if (!_isCurrentHostSession(generation)) {
        return;
      }
      _hostReconnectAttempt = 0;
      if (!isConnected) _setStatus(PeerStatus.waiting);
    } catch (error) {
      if (!_isCurrentHostSession(generation) ||
          error is SignalingConnectionCancelled) {
        return;
      }
      _fail('无法连接信令服务，正在重试：$error');
      _scheduleHostReconnect();
      if (rethrowOnFailure) rethrow;
    }
  }

  void _scheduleHostReconnect({bool immediate = false}) {
    if (_role != SignalingRole.host || _hostReconnectTimer != null) return;
    final exponent = min(_hostReconnectAttempt, 4);
    final delay = immediate
        ? Duration.zero
        : Duration(seconds: min(30, 2 * (1 << exponent)));
    _hostReconnectAttempt++;
    _hostReconnectTimer = Timer(delay, () {
      _hostReconnectTimer = null;
      unawaited(_connectHost(expectedGeneration: _sessionGeneration));
    });
  }

  bool _isCurrentHostSession(int generation) =>
      generation == _sessionGeneration &&
      _role == SignalingRole.host &&
      !_usingLan;

  void ensureHosting() {
    if (_role == SignalingRole.host && !_signaling.isOpen) {
      _scheduleHostReconnect(immediate: true);
    }
  }

  Future<void> join({
    required String signalingUrl,
    required String identifier,
    required String totpCode,
    required String localIdentifier,
    required String localHostToken,
  }) async {
    await disconnect();
    final generation = _sessionGeneration;
    _role = SignalingRole.peer;
    _targetIdentifier = identifier;
    _setStatus(PeerStatus.connecting);
    await _listenToSignals();
    try {
      await _signaling.connect(
        baseUrl: signalingUrl,
        identifier: identifier,
        role: SignalingRole.peer,
        clientIdentifier: localIdentifier,
        hostToken: localHostToken,
      );
      if (generation != _sessionGeneration ||
          _role != SignalingRole.peer ||
          _usingLan) {
        return;
      }
      _signaling.send({'type': 'authenticate', 'totp': totpCode});
    } catch (error) {
      if (generation != _sessionGeneration ||
          error is SignalingConnectionCancelled) {
        return;
      }
      _fail('连接失败：$error');
      rethrow;
    }
  }

  Future<void> joinLan({
    required String address,
    required int port,
    required String identifier,
    required String totpCode,
    required String localIdentifier,
  }) async {
    await disconnect();
    _role = SignalingRole.peer;
    _usingLan = true;
    _targetIdentifier = identifier;
    _localIdentifier = localIdentifier;
    _lanTotpCode = totpCode;
    _setStatus(PeerStatus.connecting);
    try {
      final socket = await WebSocket.connect(
        Uri(
          scheme: 'ws',
          host: address,
          port: port,
          path: '/signal',
          queryParameters: {
            'identifier': localIdentifier,
            'target': identifier,
          },
        ).toString(),
      ).timeout(const Duration(seconds: 8));
      _attachLanSignalSocket(socket);
    } catch (error) {
      _fail('局域网直连 $address:$port 失败：$error');
      rethrow;
    }
  }

  Future<bool> acceptLanConnection(
    WebSocket socket,
    String peerIdentifier,
  ) async {
    if (isConnected || status == PeerStatus.connecting) return false;
    await disconnect();
    _role = SignalingRole.host;
    _usingLan = true;
    _targetIdentifier = peerIdentifier;
    _attachLanSignalSocket(socket);
    _setStatus(PeerStatus.connecting);
    try {
      await _createOffer();
      return true;
    } catch (error) {
      _fail('局域网协商失败：$error');
      return false;
    }
  }

  void _attachLanSignalSocket(WebSocket socket) {
    _lanSignalSocket = socket;
    _lanSignalSubscription = socket.listen(
      (data) {
        if (data is! String) return;
        try {
          final message = jsonDecode(data);
          if (message is Map<String, dynamic>) {
            _lanSignalMessageQueue = _lanSignalMessageQueue
                .then((_) => _handleSignal(message))
                .onError((Object error, StackTrace stackTrace) {
                  _fail('处理局域网信令失败：$error');
                });
          }
        } catch (_) {
          _fail('局域网信令消息格式错误');
        }
      },
      onError: (Object error) {
        if (!isConnected) _fail('局域网信令连接错误：$error');
      },
      onDone: () {
        if (identical(_lanSignalSocket, socket)) _lanSignalSocket = null;
        if (!isConnected && status != PeerStatus.idle) {
          _fail('局域网信令连接已断开');
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _listenToSignals() async {
    await _signalSubscription?.cancel();
    _signalSubscription = _signaling.messages
        .asyncMap(_handleSignal)
        .listen((_) {});
  }

  Future<void> _handleSignal(Map<String, dynamic> message) async {
    try {
      switch (message['type']) {
        case 'ready':
          if (_role == SignalingRole.host) _setStatus(PeerStatus.waiting);
          break;
        case 'auth_request':
          if (_role != SignalingRole.host) return;
          final valid = TotpService.verify(
            totpSecret,
            message['totp'] as String? ?? '',
          );
          _sendSignal({'type': 'auth_result', 'ok': valid});
          if (valid) {
            final peerIdentifier = message['peerIdentifier'] as String?;
            if (peerIdentifier != null && peerIdentifier.isNotEmpty) {
              _targetIdentifier = peerIdentifier;
              onPaired?.call(peerIdentifier);
            }
          }
          if (!valid) _setStatus(PeerStatus.waiting);
          break;
        case 'auth_ok':
          if (_role == SignalingRole.peer) {
            final target = _targetIdentifier;
            if (target != null) onPaired?.call(target);
            _setStatus(PeerStatus.connecting);
          }
          break;
        case 'auth_failed':
          _fail('唯一标识或 TOTP 安全码不正确');
          break;
        case 'peer_joined':
          if (_role == SignalingRole.host) await _createOffer();
          break;
        case 'offer':
          if (_role != SignalingRole.peer) return;
          final sdp = message['sdp'] as String;
          if (sdp == _lastRemoteOfferSdp) return;
          await _ensurePeerConnection();
          await _applyRemoteDescription(RTCSessionDescription(sdp, 'offer'));
          final answer = await _peerConnection!.createAnswer();
          await _peerConnection!.setLocalDescription(answer);
          _lastRemoteOfferSdp = sdp;
          _sendSignal({'type': 'answer', 'sdp': answer.sdp});
          break;
        case 'answer':
          if (!_hasPendingOffer || _peerConnection == null) return;
          await _applyRemoteDescription(
            RTCSessionDescription(message['sdp'] as String, 'answer'),
          );
          _hasPendingOffer = false;
          break;
        case 'candidate':
          await _ensurePeerConnection();
          await _addOrQueueRemoteCandidate(
            RTCIceCandidate(
              message['candidate'] as String?,
              message['sdpMid'] as String?,
              (message['sdpMLineIndex'] as num?)?.toInt(),
            ),
          );
          break;
        case 'peer_left':
          await _closePeerTransport();
          _setStatus(
            _role == SignalingRole.host
                ? PeerStatus.waiting
                : PeerStatus.disconnected,
          );
          break;
        case 'error':
          _fail(message['message'] as String? ?? '信令服务错误');
          break;
        case 'signaling_closed':
          if (_role == SignalingRole.host) {
            if (!isConnected) _fail('主机信令连接已断开，正在重连');
            _scheduleHostReconnect();
          } else if (!isConnected && status != PeerStatus.idle) {
            _fail('信令连接已断开');
          }
          break;
      }
    } catch (error) {
      _fail('协商失败：$error');
    }
  }

  Future<void> _createOffer() async {
    if (_hasPendingOffer || isConnected) return;
    _hasPendingOffer = true;
    _setStatus(PeerStatus.connecting);
    try {
      await _ensurePeerConnection();
      final init = RTCDataChannelInit()..ordered = true;
      _attachDataChannel(
        await _peerConnection!.createDataChannel('rtc-transfer', init),
      );
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      _sendSignal({'type': 'offer', 'sdp': offer.sdp});
    } catch (_) {
      _hasPendingOffer = false;
      rethrow;
    }
  }

  Future<void> _applyRemoteDescription(
    RTCSessionDescription description,
  ) async {
    await _peerConnection!.setRemoteDescription(description);
    _remoteDescriptionSet = true;
    final pending = List<RTCIceCandidate>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      await _peerConnection!.addCandidate(candidate);
    }
  }

  Future<void> _addOrQueueRemoteCandidate(RTCIceCandidate candidate) async {
    if (!_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await _peerConnection!.addCandidate(candidate);
  }

  Future<void> _ensurePeerConnection() async {
    if (_peerConnection != null) return;
    final connection = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _peerConnection = connection;
    connection.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _sendSignal({
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    connection.onDataChannel = _attachDataChannel;
    connection.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (_isDataChannelOpen) _markDataChannelReady();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _fail('WebRTC 连接失败，请检查网络或配置 TURN 服务');
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (status != PeerStatus.idle) _setStatus(PeerStatus.disconnected);
        default:
          break;
      }
    };
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onMessage = _enqueueDataMessage;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _markDataChannelReady();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed &&
          status != PeerStatus.idle) {
        _setStatus(PeerStatus.disconnected);
      }
    };
  }

  void _markDataChannelReady() {
    if (!_isDataChannelOpen) return;
    if (_usingLan && !_lanAuthenticated) {
      if (_role == SignalingRole.peer && !_lanAuthSent) {
        _lanAuthSent = true;
        unawaited(
          _sendJson({
            'type': 'lan_auth',
            'totp': _lanTotpCode,
            'peerIdentifier': _localIdentifier,
          }),
        );
      }
      return;
    }
    _finishDataChannelReady();
  }

  void _finishDataChannelReady() {
    _setStatus(PeerStatus.connected);
    if (_initialDirectoryRequested) return;
    _initialDirectoryRequested = true;
    requestRemoteDirectory('', kind: PeerDirectoryKind.shared);
  }

  void _enqueueDataMessage(RTCDataChannelMessage message) {
    _incomingMessageQueue = _incomingMessageQueue
        .then((_) => _handleDataMessage(message))
        .onError((Object error, StackTrace stackTrace) {
          _fail('处理传输数据失败：$error');
        });
  }

  Future<void> _handleDataMessage(RTCDataChannelMessage message) async {
    if (message.isBinary) {
      await _writeIncomingChunk(message.binary);
      return;
    }
    final data = jsonDecode(message.text) as Map<String, dynamic>;
    if (_usingLan && !_lanAuthenticated) {
      await _handleLanAuthentication(data);
      return;
    }
    switch (data['type']) {
      case 'list_request':
        await _sendDirectoryListing(
          data['path'] as String? ?? '',
          kind: _directoryKindFromWire(data['root']),
          requestId: data['requestId'] as String?,
        );
        break;
      case 'list_response':
        final responseRequestId = data['requestId'] as String?;
        if (responseRequestId != null &&
            responseRequestId != _pendingDirectoryRequestId) {
          break;
        }
        _pendingDirectoryRequestId = null;
        remoteBrowserError = null;
        remoteCurrentPath = data['path'] as String? ?? '';
        remoteCurrentDisplayPath =
            data['displayPath'] as String? ??
            (remoteCurrentPath.isEmpty ? '/' : '/$remoteCurrentPath');
        remoteDirectoryKind = _directoryKindFromWire(data['root']);
        remoteEntries = (data['entries'] as List<dynamic>)
            .map((item) => FileEntry.fromJson(item as Map<String, dynamic>))
            .toList();
        notifyListeners();
        break;
      case 'error':
        final responseRequestId = data['requestId'] as String?;
        if (responseRequestId == null && _pendingDirectoryRequestId == null) {
          _showIncomingTransferFailure(
            data['path'] as String? ?? '传输任务',
            data['message'] as String? ?? '对端发送失败',
          );
          break;
        }
        if (responseRequestId != null &&
            responseRequestId != _pendingDirectoryRequestId) {
          break;
        }
        _pendingDirectoryRequestId = null;
        remoteDirectoryKind = _directoryKindFromWire(data['root']);
        remoteCurrentPath = data['path'] as String? ?? remoteCurrentPath;
        remoteCurrentDisplayPath =
            data['displayPath'] as String? ?? remoteCurrentDisplayPath;
        remoteBrowserError = data['message'] as String? ?? '远端目录读取失败';
        remoteEntries = const [];
        notifyListeners();
        break;
      case 'transfer_failure':
        _showIncomingTransferFailure(
          data['name'] as String? ?? '传输任务',
          data['message'] as String? ?? '对端发送失败',
        );
        break;
      case 'download':
        // Do not await the complete directory transfer from the ordered
        // incoming-message queue. Each file waits for a transfer_ack sent on
        // this same channel; awaiting here would leave that acknowledgement
        // queued behind the download request and stop after the first file.
        unawaited(
          _sendRequestedPath(
            data['path'] as String,
            destinationDirectory: data['destination'] as String? ?? '',
            displayName: data['name'] as String?,
            totalBytes: (data['size'] as num?)?.toInt(),
            isDirectory: data['directory'] as bool?,
          ),
        );
        break;
      case 'batch_start':
        _incomingBatchFailed = false;
        transferOverview = TransferOverview(
          id: data['id'] as String,
          name: data['name'] as String? ?? '传输任务',
          totalBytes: (data['size'] as num?)?.toInt() ?? 0,
          direction: TransferDirection.receiving,
        );
        notifyListeners();
        break;
      case 'batch_end':
        final overview = transferOverview;
        final batchId = data['id'] as String;
        final succeeded = !_incomingBatchFailed;
        if (overview != null && overview.id == batchId && succeeded) {
          overview
            ..transferredBytes = overview.totalBytes
            ..state = TransferState.complete
            ..currentFile = null
            ..stopwatch.stop();
          notifyListeners();
        }
        await _sendJson({
          'type': 'batch_ack',
          'id': batchId,
          'ok': succeeded,
          if (!succeeded) 'message': overview?.error ?? '目录传输失败',
        });
        _incomingBatchFailed = false;
        break;
      case 'batch_ack':
        final id = data['id'] as String;
        final acknowledgement = _outgoingBatchAcknowledgements.remove(id);
        if (acknowledgement == null || acknowledgement.isCompleted) break;
        if (data['ok'] == true) {
          acknowledgement.complete();
        } else {
          acknowledgement.completeError(
            StateError(data['message'] as String? ?? '目录接收失败'),
          );
        }
        break;
      case 'batch_abort':
        final overview = transferOverview;
        if (overview != null && overview.id == data['id']) {
          overview
            ..state = TransferState.failed
            ..error = data['message'] as String? ?? '目录传输已中止'
            ..stopwatch.stop();
          _incomingBatchFailed = true;
          notifyListeners();
        }
        break;
      case 'directory_create':
        await _createIncomingDirectory(data);
        break;
      case 'directory_ack':
        final id = data['id'] as String;
        final acknowledgement = _outgoingDirectoryAcknowledgements.remove(id);
        if (acknowledgement == null || acknowledgement.isCompleted) break;
        if (data['ok'] == true) {
          acknowledgement.complete();
        } else {
          acknowledgement.completeError(
            StateError(data['message'] as String? ?? '接收端目录创建失败'),
          );
        }
        break;
      case 'transfer_start':
        await _startIncoming(data);
        break;
      case 'transfer_end':
        await _finishIncoming(data['id'] as String);
        break;
      case 'transfer_ack':
        final id = data['id'] as String;
        final acknowledgement = _outgoingAcknowledgements.remove(id);
        if (acknowledgement == null || acknowledgement.isCompleted) break;
        if (data['ok'] == true) {
          acknowledgement.complete();
        } else {
          acknowledgement.completeError(
            StateError(data['message'] as String? ?? '接收端文件校验失败'),
          );
        }
        break;
      case 'transfer_error':
        _markFailed(data['id'] as String, data['message'] as String);
        break;
    }
  }

  Future<void> _handleLanAuthentication(Map<String, dynamic> data) async {
    switch (data['type']) {
      case 'lan_auth':
        if (_role != SignalingRole.host) return;
        final valid = TotpService.verify(
          totpSecret,
          data['totp'] as String? ?? '',
        );
        await _sendJson({'type': 'lan_auth_result', 'ok': valid});
        if (!valid) {
          _fail('唯一标识或 TOTP 安全码不正确');
          return;
        }
        _lanAuthenticated = true;
        final peerIdentifier = _targetIdentifier;
        if (peerIdentifier != null) onPaired?.call(peerIdentifier);
        _finishDataChannelReady();
        return;
      case 'lan_auth_result':
        if (_role != SignalingRole.peer) return;
        if (data['ok'] != true) {
          _fail('唯一标识或 TOTP 安全码不正确');
          return;
        }
        _lanAuthenticated = true;
        final target = _targetIdentifier;
        if (target != null) onPaired?.call(target);
        _finishDataChannelReady();
        return;
      default:
        _fail('局域网连接尚未通过 TOTP 验证');
    }
  }

  void _sendSignal(Map<String, dynamic> message) {
    if (_usingLan) {
      final socket = _lanSignalSocket;
      if (socket == null || socket.readyState != WebSocket.open) {
        throw StateError('局域网信令连接尚未建立');
      }
      socket.add(jsonEncode(message));
      return;
    }
    _signaling.send(message);
  }

  Future<void> _sendRequestedPath(
    String relativePath, {
    required String destinationDirectory,
    String? displayName,
    int? totalBytes,
    bool? isDirectory,
  }) async {
    try {
      await sendRelativePath(
        relativePath,
        destinationDirectory: destinationDirectory,
        displayName: displayName,
        totalBytes: totalBytes,
        isDirectory: isDirectory,
      );
    } catch (error) {
      if (_isDataChannelOpen) {
        await _sendJson({
          'type': 'transfer_failure',
          'name': displayName ?? relativePath,
          'message': '发送目录失败：$error',
        });
      }
    }
  }

  Future<List<FileEntry>> listLocalDirectory(
    String relativePath, {
    PeerDirectoryKind kind = PeerDirectoryKind.shared,
  }) async {
    final rootValue = await _directoryRoot(kind);
    if (ReceiveStorage.isAndroidSafDirectory(rootValue)) {
      final entries = (await ReceiveStorage.listSharedDirectory(
        treeUri: rootValue!,
        relativePath: relativePath,
      )).map(FileEntry.fromJson).toList();
      _sortEntries(entries);
      return entries;
    }
    final directory = _safeEntityInRoot(rootValue, relativePath);
    if (directory == null ||
        !await FileSystemEntity.isDirectory(directory.path)) {
      return const [];
    }
    final entries = <FileEntry>[];
    await for (final entity in Directory(
      directory.path,
    ).list(followLinks: false)) {
      final stat = await entity.stat();
      final isDirectory = stat.type == FileSystemEntityType.directory;
      entries.add(
        FileEntry(
          name: p.basename(entity.path),
          relativePath: _wirePath(p.relative(entity.path, from: rootValue!)),
          isDirectory: isDirectory,
          size: isDirectory ? 0 : stat.size,
          modifiedMillis: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    _sortEntries(entries);
    return entries;
  }

  static void _sortEntries(List<FileEntry> entries) {
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  Future<void> _sendDirectoryListing(
    String relativePath, {
    required PeerDirectoryKind kind,
    String? requestId,
  }) async {
    try {
      final entries = await listLocalDirectory(relativePath, kind: kind);
      final displayPath = await localDirectoryDisplayPath(
        relativePath,
        kind: kind,
      );
      await _sendJson({
        'type': 'list_response',
        'root': kind.name,
        'path': relativePath,
        'requestId': ?requestId,
        'displayPath': displayPath,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      });
    } catch (error) {
      await _sendJson({
        'type': 'error',
        'root': kind.name,
        'path': relativePath,
        'requestId': ?requestId,
        'displayPath': await localDirectoryDisplayPath(
          relativePath,
          kind: kind,
        ),
        'message': kind == PeerDirectoryKind.shared
            ? '无法读取共享目录：$error'
            : '无法读取接收目录：$error',
      });
    }
  }

  Future<String?> _directoryRoot(PeerDirectoryKind kind) async =>
      kind == PeerDirectoryKind.shared
      ? sharedRoot
      : ReceiveStorage.resolveReceiveDirectory(receiveDirectory);

  Future<String> localDirectoryDisplayPath(
    String relativePath, {
    required PeerDirectoryKind kind,
  }) async {
    final root = await _directoryRoot(kind);
    if (root == null || root.isEmpty) return '未设置';
    if (relativePath.isEmpty) return root;
    return p.join(root, relativePath);
  }

  void requestRemoteDirectory(
    String path, {
    PeerDirectoryKind kind = PeerDirectoryKind.shared,
  }) {
    if (!_isDataChannelOpen) return;
    remoteBrowserError = null;
    remoteDirectoryKind = kind;
    final requestId = _randomId();
    _pendingDirectoryRequestId = requestId;
    unawaited(
      _sendControlMessage({
        'type': 'list_request',
        'requestId': requestId,
        'root': kind.name,
        'path': path,
      }),
    );
  }

  void requestDownload(FileEntry entry, {String destinationDirectory = ''}) {
    if (!_isDataChannelOpen) return;
    unawaited(
      _sendControlMessage({
        'type': 'download',
        'path': entry.relativePath,
        'destination': destinationDirectory,
        'name': entry.name,
        'size': entry.size,
        'directory': entry.isDirectory,
      }),
    );
  }

  Future<void> sendPaths(List<String> paths) async {
    for (final path in paths) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await _sendFile(File(path), p.basename(path));
      } else if (type == FileSystemEntityType.directory) {
        final root = Directory(path);
        await _sendDirectory(p.basename(root.path));
        await for (final entity in root.list(
          recursive: true,
          followLinks: false,
        )) {
          final destinationPath = p.join(
            p.basename(root.path),
            p.relative(entity.path, from: root.path),
          );
          if (entity is Directory) {
            await _sendDirectory(destinationPath);
          } else if (entity is File) {
            await _sendFile(entity, destinationPath);
          }
        }
      }
    }
  }

  Future<void> sendRelativePath(
    String relativePath, {
    String destinationDirectory = '',
    String? displayName,
    int? totalBytes,
    bool? isDirectory,
  }) async {
    if (_outgoingTransferActive) {
      throw StateError('已有传输任务正在进行');
    }
    _outgoingTransferActive = true;
    try {
      await _sendRelativePathExclusive(
        relativePath,
        destinationDirectory: destinationDirectory,
        displayName: displayName,
        totalBytes: totalBytes,
        isDirectory: isDirectory,
      );
    } finally {
      _outgoingTransferActive = false;
    }
  }

  Future<void> _sendRelativePathExclusive(
    String relativePath, {
    required String destinationDirectory,
    String? displayName,
    int? totalBytes,
    bool? isDirectory,
  }) async {
    final resolvedTotalBytes = totalBytes != null && totalBytes > 0
        ? totalBytes
        : await _relativePathSize(relativePath, isDirectory: isDirectory);
    final batchId = _randomId();
    final overview = TransferOverview(
      id: batchId,
      name: displayName ?? p.posix.basename(_wirePath(relativePath)),
      totalBytes: resolvedTotalBytes,
      direction: TransferDirection.sending,
    );
    transferOverview = overview;
    final batchAcknowledgement = Completer<void>();
    // The connection can close while files are still being streamed and
    // before this future is awaited. Keep an error handler attached so a
    // disconnect never becomes an unhandled asynchronous exception.
    batchAcknowledgement.future.ignore();
    _outgoingBatchAcknowledgements[batchId] = batchAcknowledgement;
    _outgoingBatchId = batchId;
    notifyListeners();
    await _sendJson({
      'type': 'batch_start',
      'id': batchId,
      'name': overview.name,
      'size': overview.totalBytes,
    });
    try {
      await _sendRelativePathContents(
        relativePath,
        destinationDirectory: destinationDirectory,
        isDirectory: isDirectory,
      );
      await _sendJson({'type': 'batch_end', 'id': batchId});
      await batchAcknowledgement.future.timeout(const Duration(minutes: 30));
      overview
        ..transferredBytes = overview.totalBytes
        ..state = TransferState.complete
        ..currentFile = null
        ..stopwatch.stop();
      notifyListeners();
    } catch (error) {
      _outgoingBatchAcknowledgements.remove(batchId);
      try {
        await _sendJson({
          'type': 'batch_abort',
          'id': batchId,
          'message': '$error',
        });
      } catch (_) {}
      overview
        ..state = TransferState.failed
        ..error = '$error'
        ..stopwatch.stop();
      notifyListeners();
      rethrow;
    } finally {
      if (_outgoingBatchId == batchId) _outgoingBatchId = null;
    }
  }

  Future<void> _sendRelativePathContents(
    String relativePath, {
    required String destinationDirectory,
    bool? isDirectory,
  }) async {
    if (ReceiveStorage.isAndroidSafDirectory(sharedRoot)) {
      final directories = await ReceiveStorage.listSharedDirectoriesRecursive(
        treeUri: sharedRoot!,
        relativePath: relativePath,
      );
      final files = await ReceiveStorage.listSharedFilesRecursive(
        treeUri: sharedRoot!,
        relativePath: relativePath,
      );
      final selected = _wirePath(relativePath);
      for (final directory in directories) {
        await _sendDirectory(
          p.join(
            destinationDirectory,
            _relativeTransferDestination(selected, _wirePath(directory)),
          ),
        );
      }
      for (final file in files) {
        final wireFile = _wirePath(file);
        final relativeDestination = _relativeTransferDestination(
          selected,
          wireFile,
        );
        await _sendSafFile(
          file,
          p.join(destinationDirectory, relativeDestination),
        );
      }
      return;
    }
    final entity = _safeEntity(relativePath, requireRoot: true);
    if (entity == null) return;
    final treatAsDirectory =
        isDirectory ?? await FileSystemEntity.isDirectory(entity.path);
    if (treatAsDirectory) {
      final directory = Directory(entity.path);
      final destinationPath = p.join(
        destinationDirectory,
        p.basename(directory.path),
      );
      await _sendDirectory(destinationPath);
      await _sendDirectoryContents(directory, destinationPath);
    } else if (await FileSystemEntity.isFile(entity.path)) {
      await _sendFile(
        File(entity.path),
        p.join(destinationDirectory, p.basename(entity.path)),
      );
    }
  }

  static String _relativeTransferDestination(String selected, String path) =>
      path == selected
      ? p.posix.basename(path)
      : p.posix.join(
          p.posix.basename(selected),
          p.posix.relative(path, from: selected),
        );

  Future<void> _sendDirectory(String destinationPath) async {
    final id = _randomId();
    final acknowledgement = Completer<void>();
    acknowledgement.future.ignore();
    _outgoingDirectoryAcknowledgements[id] = acknowledgement;
    try {
      await _sendJson({
        'type': 'directory_create',
        'id': id,
        'path': destinationPath,
      });
      await acknowledgement.future.timeout(const Duration(seconds: 15));
    } finally {
      _outgoingDirectoryAcknowledgements.remove(id);
    }
  }

  Future<void> _sendDirectoryContents(
    Directory directory,
    String destinationPath,
  ) async {
    await for (final child in directory.list(followLinks: false)) {
      final childDestination = p.join(destinationPath, p.basename(child.path));
      if (child is Directory) {
        await _sendDirectory(childDestination);
        await _sendDirectoryContents(child, childDestination);
      } else if (child is File) {
        await _sendFile(child, childDestination);
      }
    }
  }

  Future<int> _relativePathSize(
    String relativePath, {
    bool? isDirectory,
  }) async {
    if (ReceiveStorage.isAndroidSafDirectory(sharedRoot)) {
      return ReceiveStorage.sharedPathSize(
        treeUri: sharedRoot!,
        relativePath: relativePath,
      );
    }
    final entity = _safeEntity(relativePath, requireRoot: true);
    if (entity == null) return 0;
    final treatAsDirectory =
        isDirectory ?? await FileSystemEntity.isDirectory(entity.path);
    if (treatAsDirectory) {
      return _directorySize(Directory(entity.path));
    }
    return File(entity.path).length();
  }

  Future<void> _sendFile(File file, String destinationPath) async {
    final size = await file.length();
    final reader = await file.open();
    try {
      await _sendFileData(
        size: size,
        destinationPath: destinationPath,
        readChunk: () => reader.read(_chunkSize),
      );
    } finally {
      await reader.close();
    }
  }

  Future<void> _sendSafFile(String relativePath, String destinationPath) async {
    final handle = _randomId();
    final size = await ReceiveStorage.openSharedFile(
      handle: handle,
      treeUri: sharedRoot!,
      relativePath: relativePath,
    );
    try {
      await _sendFileData(
        size: size,
        destinationPath: destinationPath,
        readChunk: () =>
            ReceiveStorage.readSharedFile(handle: handle, maxBytes: _chunkSize),
      );
    } finally {
      await ReceiveStorage.closeSharedFile(handle);
    }
  }

  Future<void> _sendFileData({
    required int size,
    required String destinationPath,
    required Future<Uint8List> Function() readChunk,
  }) async {
    final channel = _dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('数据通道未连接');
    }
    final id = _randomId();
    final task = TransferTask(
      id: id,
      name: destinationPath,
      totalBytes: size,
      direction: TransferDirection.sending,
    )..state = TransferState.active;
    transfers.insert(0, task);
    final overview = transferOverview;
    if (overview != null && overview.direction == TransferDirection.sending) {
      overview.currentFile = destinationPath;
    }
    final acknowledgement = Completer<void>();
    acknowledgement.future.ignore();
    _outgoingAcknowledgements[id] = acknowledgement;
    notifyListeners();
    await _sendJson({
      'type': 'transfer_start',
      'id': id,
      'path': destinationPath,
      'size': size,
    });
    final stopwatch = Stopwatch()..start();
    var enqueuedBytes = 0;
    var lastBytes = 0;
    var lastSample = 0;
    var chunksSinceBufferPoll = 0;
    final overviewBase = overview?.transferredBytes ?? 0;
    try {
      while (true) {
        final chunk = await readChunk();
        if (chunk.isEmpty) break;
        await channel.send(RTCDataChannelMessage.fromBinary(chunk));
        enqueuedBytes += chunk.length;
        chunksSinceBufferPoll++;
        final now = stopwatch.elapsedMilliseconds;
        if (chunksSinceBufferPoll >= 8 || now - lastSample >= 250) {
          final buffered = await _waitForDataChannelCapacity(channel);
          chunksSinceBufferPoll = 0;
          final delivered = (enqueuedBytes - buffered).clamp(0, size);
          task.transferredBytes = max(task.transferredBytes, delivered);
          if (overview != null &&
              overview.direction == TransferDirection.sending) {
            overview.transferredBytes = max(
              overview.transferredBytes,
              overviewBase + task.transferredBytes,
            );
          }
        }
        if (now - lastSample >= 250) {
          task.bytesPerSecond =
              (task.transferredBytes - lastBytes) * 1000 / (now - lastSample);
          lastBytes = task.transferredBytes;
          lastSample = now;
          notifyListeners();
        }
      }
      await _waitForDataChannelDrain(channel);
      task.transferredBytes = size;
      if (overview != null && overview.direction == TransferDirection.sending) {
        overview.transferredBytes = max(
          overview.transferredBytes,
          overviewBase + size,
        );
      }
      await _sendJson({'type': 'transfer_end', 'id': id});
      await acknowledgement.future.timeout(const Duration(minutes: 5));
      task
        ..state = TransferState.complete
        ..bytesPerSecond = size * 1000 / max(1, stopwatch.elapsedMilliseconds);
      notifyListeners();
    } catch (error) {
      _outgoingAcknowledgements.remove(id);
      task
        ..state = TransferState.failed
        ..error = error.toString();
      try {
        await _sendJson({
          'type': 'transfer_error',
          'id': id,
          'message': '$error',
        });
      } catch (_) {
        // Preserve the original transfer error when the channel has already
        // closed; attempting to report it must not create another exception.
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<int> _waitForDataChannelCapacity(RTCDataChannel channel) async {
    var buffered = await channel.getBufferedAmount();
    while (buffered > _maxBufferedBytes) {
      if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
        throw StateError('数据通道已断开');
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
      buffered = await channel.getBufferedAmount();
    }
    return buffered;
  }

  Future<void> _waitForDataChannelDrain(RTCDataChannel channel) async {
    while (await channel.getBufferedAmount() > 0) {
      if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
        throw StateError('数据通道已断开');
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  Future<void> _startIncoming(Map<String, dynamic> data) async {
    if (_incoming != null) {
      _incomingBatchFailed = true;
      await _sendJson({
        'type': 'transfer_error',
        'id': data['id'],
        'message': '接收端当前正忙',
      });
      return;
    }
    final relativePath = _sanitizeRelative(data['path'] as String);
    final id = data['id'] as String;
    final task = TransferTask(
      id: id,
      name: relativePath,
      totalBytes: (data['size'] as num).toInt(),
      direction: TransferDirection.receiving,
    )..state = TransferState.active;
    transfers.insert(0, task);
    final overview = transferOverview;
    if (overview == null ||
        overview.direction != TransferDirection.receiving ||
        overview.state != TransferState.active) {
      transferOverview = TransferOverview(
        id: id,
        name: relativePath,
        totalBytes: task.totalBytes,
        direction: TransferDirection.receiving,
      )..currentFile = relativePath;
    } else {
      overview.currentFile = relativePath;
    }
    try {
      final writer = await ReceiveStorage.openFile(
        transferId: id,
        relativePath: relativePath,
        configuredDirectory: receiveDirectory,
      );
      _incoming = _IncomingFile(
        id: id,
        task: task,
        writer: writer,
        stopwatch: Stopwatch()..start(),
      );
    } catch (error) {
      final message = '无法创建接收文件：$error';
      task
        ..state = TransferState.failed
        ..error = message;
      transferOverview
        ?..state = TransferState.failed
        ..error = message
        ..stopwatch.stop();
      _incomingBatchFailed = true;
      notifyListeners();
      await _sendJson({'type': 'transfer_error', 'id': id, 'message': message});
      return;
    }
    notifyListeners();
  }

  Future<void> _createIncomingDirectory(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final relativePath = _sanitizeRelative(data['path'] as String);
    try {
      await ReceiveStorage.createDirectory(
        relativePath: relativePath,
        configuredDirectory: receiveDirectory,
      );
      await _sendJson({'type': 'directory_ack', 'id': id, 'ok': true});
    } catch (error) {
      final message = '无法创建接收目录：$error';
      _incomingBatchFailed = true;
      transferOverview
        ?..state = TransferState.failed
        ..error = message
        ..stopwatch.stop();
      notifyListeners();
      await _sendJson({
        'type': 'directory_ack',
        'id': id,
        'ok': false,
        'message': message,
      });
    }
  }

  Future<void> _writeIncomingChunk(Uint8List bytes) async {
    final incoming = _incoming;
    if (incoming == null) return;
    await incoming.writer.write(bytes);
    incoming.task.transferredBytes += bytes.length;
    final overview = transferOverview;
    if (overview != null && overview.direction == TransferDirection.receiving) {
      overview.transferredBytes += bytes.length;
    }
    final elapsed = incoming.stopwatch.elapsedMilliseconds;
    incoming.task.bytesPerSecond =
        incoming.task.transferredBytes * 1000 / max(1, elapsed);
    notifyListeners();
  }

  Future<void> _finishIncoming(String id) async {
    final incoming = _incoming;
    if (incoming == null || incoming.id != id) return;
    await incoming.writer.close();
    final complete = incoming.task.transferredBytes == incoming.task.totalBytes;
    if (!complete) {
      final message =
          '文件大小不一致：收到 ${incoming.task.transferredBytes}，预期 ${incoming.task.totalBytes} 字节';
      incoming.task
        ..state = TransferState.failed
        ..error = message;
      transferOverview
        ?..state = TransferState.failed
        ..error = message
        ..stopwatch.stop();
      _incomingBatchFailed = true;
      _incoming = null;
      notifyListeners();
      await _sendJson({
        'type': 'transfer_ack',
        'id': id,
        'ok': false,
        'message': message,
      });
      return;
    }
    incoming.task
      ..transferredBytes = incoming.task.totalBytes
      ..state = TransferState.complete;
    _incoming = null;
    final overview = transferOverview;
    if (overview != null && overview.id == id) {
      overview
        ..transferredBytes = overview.totalBytes
        ..state = TransferState.complete
        ..currentFile = null
        ..stopwatch.stop();
    }
    notifyListeners();
    await _sendJson({'type': 'transfer_ack', 'id': id, 'ok': true});
  }

  FileSystemEntity? _safeEntity(
    String relativePath, {
    required bool requireRoot,
  }) {
    final rootValue = sharedRoot;
    if (rootValue == null || rootValue.isEmpty) return null;
    final root = p.normalize(p.absolute(rootValue));
    final resolved = p.normalize(p.absolute(p.join(root, relativePath)));
    if (resolved != root && !p.isWithin(root, resolved)) return null;
    return FileSystemEntity.isDirectorySync(resolved)
        ? Directory(resolved)
        : File(resolved);
  }

  FileSystemEntity? _safeEntityInRoot(String? rootValue, String relativePath) {
    if (rootValue == null || rootValue.isEmpty) return null;
    final root = p.normalize(p.absolute(rootValue));
    final resolved = p.normalize(p.absolute(p.join(root, relativePath)));
    if (resolved != root && !p.isWithin(root, resolved)) return null;
    return FileSystemEntity.isDirectorySync(resolved)
        ? Directory(resolved)
        : File(resolved);
  }

  static PeerDirectoryKind _directoryKindFromWire(Object? value) =>
      value == PeerDirectoryKind.receive.name
      ? PeerDirectoryKind.receive
      : PeerDirectoryKind.shared;

  static String _wirePath(String value) => value.replaceAll('\\', '/');

  static String _sanitizeRelative(String input) {
    final normalized = p.normalize(input.replaceAll('\\', '/'));
    final segments = p.posix
        .split(normalized)
        .where(
          (segment) => segment != '..' && segment != '.' && segment.isNotEmpty,
        )
        .toList();
    return p.joinAll(segments.isEmpty ? ['download'] : segments);
  }

  Future<int> _directorySize(Directory directory) async {
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        total += await _directorySize(entity);
      } else if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  void _showIncomingTransferFailure(String name, String message) {
    transferOverview =
        TransferOverview(
            id: _randomId(),
            name: name,
            totalBytes: 0,
            direction: TransferDirection.receiving,
          )
          ..state = TransferState.failed
          ..error = message
          ..stopwatch.stop();
    notifyListeners();
  }

  Future<void> _sendJson(Map<String, dynamic> data) async {
    final channel = _dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('数据通道未连接');
    }
    await channel.send(RTCDataChannelMessage(jsonEncode(data)));
  }

  Future<void> _sendControlMessage(Map<String, dynamic> data) async {
    try {
      await _sendJson(data);
    } catch (error) {
      if (_isDataChannelOpen) _fail('发送数据通道消息失败：$error');
    }
  }

  void _markFailed(String id, String message) {
    final acknowledgement = _outgoingAcknowledgements.remove(id);
    if (acknowledgement != null && !acknowledgement.isCompleted) {
      acknowledgement.completeError(StateError(message));
    }
    for (final task in transfers) {
      if (task.id == id) {
        task
          ..state = TransferState.failed
          ..error = message;
      }
    }
    final overview = transferOverview;
    if (overview != null && overview.state == TransferState.active) {
      overview
        ..state = TransferState.failed
        ..error = message
        ..stopwatch.stop();
    }
    notifyListeners();
  }

  void _setStatus(PeerStatus value) {
    status = value;
    if (value == PeerStatus.connecting) {
      _connectionTimeout ??= Timer(_connectionTimeoutDuration, () {
        if (status == PeerStatus.connecting && !isConnected) {
          _fail('建立 P2P 连接超时（30 秒），请重试或检查 TURN 配置');
        }
      });
    } else {
      _connectionTimeout?.cancel();
      _connectionTimeout = null;
    }
    if (value != PeerStatus.error) errorMessage = null;
    notifyListeners();
  }

  void _fail(String message) {
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    errorMessage = message;
    status = PeerStatus.error;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _sessionGeneration++;
    _hostReconnectTimer?.cancel();
    _hostReconnectTimer = null;
    _hostReconnectAttempt = 0;
    _hostSignalingUrl = null;
    _hostIdentifier = null;
    _hostToken = null;
    _role = null;
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    for (final acknowledgement in _outgoingAcknowledgements.values) {
      if (!acknowledgement.isCompleted) {
        acknowledgement.completeError(StateError('连接已断开'));
      }
    }
    _outgoingAcknowledgements.clear();
    for (final acknowledgement in _outgoingDirectoryAcknowledgements.values) {
      if (!acknowledgement.isCompleted) {
        acknowledgement.completeError(StateError('连接已断开'));
      }
    }
    _outgoingDirectoryAcknowledgements.clear();
    for (final acknowledgement in _outgoingBatchAcknowledgements.values) {
      if (!acknowledgement.isCompleted) {
        acknowledgement.completeError(StateError('连接已断开'));
      }
    }
    _outgoingBatchAcknowledgements.clear();
    await _incoming?.writer.abort();
    _incoming = null;
    await _closePeerTransport();
    await _signalSubscription?.cancel();
    _signalSubscription = null;
    await _signaling.close();
    await _lanSignalSubscription?.cancel();
    _lanSignalSubscription = null;
    await _lanSignalSocket?.close();
    _lanSignalSocket = null;
    _usingLan = false;
    _lanAuthenticated = false;
    _lanAuthSent = false;
    _lanTotpCode = null;
    _localIdentifier = null;
    _lanSignalMessageQueue = Future<void>.value();
    status = PeerStatus.idle;
    _targetIdentifier = null;
    remoteEntries = const [];
    remoteCurrentPath = '';
    remoteCurrentDisplayPath = '';
    remoteBrowserError = null;
    remoteDirectoryKind = PeerDirectoryKind.shared;
    notifyListeners();
  }

  Future<void> _closePeerTransport() async {
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
    _hasPendingOffer = false;
    _initialDirectoryRequested = false;
    _pendingDirectoryRequestId = null;
    _lastRemoteOfferSdp = null;
    _outgoingBatchId = null;
    _outgoingTransferActive = false;
    _incomingBatchFailed = false;
    transferOverview = null;
    remoteEntries = const [];
    remoteCurrentPath = '';
    remoteCurrentDisplayPath = '';
    remoteBrowserError = null;
    remoteDirectoryKind = PeerDirectoryKind.shared;
  }

  @override
  void dispose() {
    unawaited(disconnect());
    unawaited(_signaling.dispose());
    super.dispose();
  }

  static String _randomId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
}

class _IncomingFile {
  _IncomingFile({
    required this.id,
    required this.task,
    required this.writer,
    required this.stopwatch,
  });

  final String id;
  final TransferTask task;
  final ReceiveFileWriter writer;
  final Stopwatch stopwatch;
}
