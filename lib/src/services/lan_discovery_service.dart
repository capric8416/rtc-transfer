import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/device_platform.dart';

class LanDevice {
  const LanDevice({
    required this.identifier,
    required this.address,
    required this.port,
    required this.lastSeen,
    this.platform = DevicePlatform.unknown,
  });

  final String identifier;
  final String address;
  final int port;
  final DateTime lastSeen;
  final DevicePlatform platform;
}

typedef LanConnectionHandler =
    Future<bool> Function(WebSocket socket, String peerIdentifier);

class LanDiscoveryService {
  LanDiscoveryService({required this.onConnection});

  static const multicastAddress = '239.255.42.99';
  static const multicastPort = 45892;
  static const signalPort = 45893;
  static const _serviceName = 'rtc-transfer';
  static const _protocolVersion = 1;
  static const _storageChannel = MethodChannel('dev.rtctransfer/storage');

  final LanConnectionHandler onConnection;
  final _devicesController = StreamController<List<LanDevice>>.broadcast();
  final Map<String, LanDevice> _devices = {};

  RawDatagramSocket? _discoverySocket;
  List<NetworkInterface> _multicastInterfaces = const [];
  HttpServer? _signalServer;
  StreamSubscription<HttpRequest>? _serverSubscription;
  Timer? _announceTimer;
  Timer? _expiryTimer;
  String? _identifier;
  bool _started = false;

  Stream<List<LanDevice>> get devices => _devicesController.stream;
  List<LanDevice> get currentDevices => List.unmodifiable(_devices.values);

  Future<void> start({required String identifier}) async {
    await stop();
    _identifier = identifier;
    try {
      await _setAndroidMulticastLock(true);
      _signalServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        signalPort,
      );
      _serverSubscription = _signalServer!.listen(_handleHttpRequest);
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        multicastPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      socket
        ..multicastLoopback = true
        ..broadcastEnabled = true;
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final joinedInterfaces = <NetworkInterface>[];
      for (final interface in interfaces) {
        if (!_isUsableInterface(interface)) continue;
        try {
          socket.joinMulticast(InternetAddress(multicastAddress), interface);
          joinedInterfaces.add(interface);
        } catch (_) {}
      }
      if (joinedInterfaces.isEmpty) {
        socket.joinMulticast(InternetAddress(multicastAddress));
      }
      _multicastInterfaces = joinedInterfaces;
      socket.listen(_handleDiscoveryEvent);
      _discoverySocket = socket;
      _started = true;
      debugPrint(
        'LAN discovery started on UDP $multicastPort via '
        '${joinedInterfaces.map((item) => item.name).join(', ')}',
      );
      _announce();
      _announceTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _announce(),
      );
      _expiryTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _removeExpiredDevices(),
      );
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> ensureStarted({required String identifier}) async {
    if (_started && _identifier == identifier) return;
    await start(identifier: identifier);
  }

  void _announce() {
    final socket = _discoverySocket;
    final server = _signalServer;
    final identifier = _identifier;
    if (!_started || socket == null || server == null || identifier == null) {
      return;
    }
    final payload = utf8.encode(
      jsonEncode({
        'service': _serviceName,
        'version': _protocolVersion,
        'identifier': identifier,
        'port': server.port,
        'platform': DevicePlatform.current.name,
      }),
    );
    final destination = InternetAddress(multicastAddress);
    var sent = false;
    for (final interface in _multicastInterfaces) {
      try {
        final address = interface.addresses.firstWhere(_isUsableAddress);
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            address.rawAddress,
          ),
        );
        sent =
            socket.send(payload, destination, multicastPort) ==
                payload.length ||
            sent;
      } catch (_) {}
    }
    if (!sent) socket.send(payload, destination, multicastPort);
    try {
      socket.send(payload, InternetAddress('255.255.255.255'), multicastPort);
    } catch (_) {}
  }

  void _handleDiscoveryEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _discoverySocket?.receive()) != null) {
      try {
        final data = jsonDecode(utf8.decode(datagram!.data));
        if (data is! Map<String, dynamic> ||
            data['service'] != _serviceName ||
            data['version'] != _protocolVersion) {
          continue;
        }
        final identifier = data['identifier'] as String?;
        final port = (data['port'] as num?)?.toInt();
        if (identifier == null ||
            identifier == _identifier ||
            !_validIdentifier(identifier) ||
            port == null ||
            port < 1 ||
            port > 65535) {
          continue;
        }
        final previous = _devices[identifier];
        // One process announces on every IPv4 interface. A VM can therefore
        // receive several announcements for the same device (Wi-Fi, VPN,
        // libvirt, Tailscale). Keep the first fresh route instead of letting
        // the last, often unreachable virtual-interface address overwrite it.
        if (previous != null &&
            previous.address != datagram.address.address &&
            DateTime.now().difference(previous.lastSeen) <
                const Duration(seconds: 12)) {
          continue;
        }
        final device = LanDevice(
          identifier: identifier,
          address: datagram.address.address,
          port: port,
          lastSeen: DateTime.now(),
          platform: DevicePlatform.fromWire(data['platform']),
        );
        _devices[identifier] = device;
        if (previous == null ||
            previous.address != device.address ||
            previous.port != device.port) {
          debugPrint(
            'LAN device discovered: $identifier at '
            '${device.address}:${device.port}',
          );
        }
      } catch (_) {
        continue;
      }
    }
    _emitDevices();
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (request.uri.path != '/signal' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    final target = request.uri.queryParameters['target'];
    final peerIdentifier = request.uri.queryParameters['identifier'];
    if (target != _identifier ||
        peerIdentifier == null ||
        !_validIdentifier(peerIdentifier)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final accepted = await onConnection(socket, peerIdentifier);
    if (!accepted) {
      await socket.close(4009, 'Device is busy');
    }
  }

  void _removeExpiredDevices() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 12));
    final before = _devices.length;
    _devices.removeWhere((_, device) => device.lastSeen.isBefore(cutoff));
    if (_devices.length != before) _emitDevices();
  }

  void _emitDevices() {
    final devices = _devices.values.toList()
      ..sort((left, right) => left.identifier.compareTo(right.identifier));
    if (!_devicesController.isClosed) _devicesController.add(devices);
  }

  Future<void> stop() async {
    _started = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _discoverySocket?.close();
    _discoverySocket = null;
    _multicastInterfaces = const [];
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    await _signalServer?.close(force: true);
    _signalServer = null;
    _devices.clear();
    _emitDevices();
    await _setAndroidMulticastLock(false);
  }

  Future<void> dispose() async {
    await stop();
    await _devicesController.close();
  }

  static bool _validIdentifier(String value) =>
      value.length >= 3 &&
      value.length <= 64 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static bool _isUsableInterface(NetworkInterface interface) =>
      interface.addresses.any(_isUsableAddress);

  static bool _isUsableAddress(InternetAddress address) =>
      address.type == InternetAddressType.IPv4 &&
      !address.isLoopback &&
      !address.address.startsWith('169.254.');

  static Future<void> _setAndroidMulticastLock(bool enabled) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _storageChannel.invokeMethod<void>(
        enabled ? 'acquireMulticastLock' : 'releaseMulticastLock',
      );
    } catch (_) {}
  }
}
