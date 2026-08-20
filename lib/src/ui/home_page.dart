import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import '../models/file_entry.dart';
import '../models/transfer_task.dart';
import '../services/app_settings.dart';
import '../services/lan_discovery_service.dart';
import '../services/peer_session.dart';
import '../services/presence_service.dart';
import '../services/receive_storage.dart';
import '../services/totp_service.dart';
import '../utils/formatters.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late PeerSession _session;
  final PresenceService _presence = PresenceService();
  late final LanDiscoveryService _lanDiscovery;
  StreamSubscription<List<LanDevice>>? _lanDevicesSubscription;
  Timer? _timer;
  final _targetIdentifier = TextEditingController();
  final _targetCode = TextEditingController();
  final _targetCodeFocus = FocusNode();
  Map<String, bool> _onlineDevices = const {};
  Map<String, LanDevice> _lanDevices = const {};
  bool _restoringHosting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = PeerSession(
      sharedRoot: widget.settings.sharedRoot,
      receiveDirectory: widget.settings.receiveDirectory,
      totpSecret: widget.settings.totpSecret,
      onPaired: _onPaired,
    )..addListener(_onSessionChanged);
    _lanDiscovery = LanDiscoveryService(
      onConnection: (socket, identifier) =>
          _session.acceptLanConnection(socket, identifier),
    );
    _lanDevicesSubscription = _lanDiscovery.devices.listen((devices) {
      if (!mounted) return;
      setState(() {
        _lanDevices = {for (final device in devices) device.identifier: device};
      });
    });
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPresence();
      _startHosting();
      _startLanDiscovery();
      _refreshPresence();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _session.ensureHosting();
    unawaited(_startPresence());
    if (!_session.isLanConnection) {
      unawaited(
        _lanDiscovery.ensureStarted(identifier: widget.settings.identifier),
      );
    }
  }

  void _tick(Timer timer) {
    if (!mounted) return;
    if (timer.tick % 10 == 0) unawaited(_refreshPresence());
    setState(() {});
  }

  int get _remainingSeconds => TotpService.secondsRemaining();

  Future<void> _startHosting() async {
    try {
      await _session.host(
        signalingUrl: widget.settings.signalingUrl,
        identifier: widget.settings.identifier,
        hostToken: widget.settings.hostToken,
      );
    } catch (_) {}
  }

  Future<void> _startPresence() async {
    await _presence.start(
      signalingUrl: widget.settings.signalingUrl,
      identifier: widget.settings.identifier,
      hostToken: widget.settings.hostToken,
    );
  }

  Future<void> _startLanDiscovery() async {
    try {
      await _lanDiscovery.start(identifier: widget.settings.identifier);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('局域网设备发现启动失败：$error')));
      }
    }
  }

  Future<void> _joinPeer() async {
    if (_session.status == PeerStatus.connecting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final identifier = _targetIdentifier.text.trim();
    final lanDevice = _lanDevices[identifier];
    try {
      if (lanDevice != null) {
        await _session.joinLan(
          address: lanDevice.address,
          port: lanDevice.port,
          identifier: identifier,
          totpCode: _targetCode.text.trim(),
          localIdentifier: widget.settings.identifier,
        );
      } else {
        await _session.join(
          signalingUrl: widget.settings.signalingUrl,
          identifier: identifier,
          totpCode: _targetCode.text.trim(),
          localIdentifier: widget.settings.identifier,
          localHostToken: widget.settings.hostToken,
        );
      }
    } catch (_) {}
  }

  void _submitJoinFromKeyboard() {
    if (_session.isConnected ||
        _session.status == PeerStatus.connecting ||
        _targetIdentifier.text.trim().isEmpty ||
        _targetCode.text.trim().length != 6) {
      return;
    }
    unawaited(_joinPeer());
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
    if ((_session.isPeer || _session.isLanConnection) &&
        (_session.status == PeerStatus.disconnected ||
            _session.status == PeerStatus.error)) {
      unawaited(_restoreHosting(errorMessage: _session.errorMessage));
    }
  }

  Future<void> _restoreHosting({String? errorMessage}) async {
    if (_restoringHosting || !mounted) return;
    _restoringHosting = true;
    try {
      await _startHosting();
      if (mounted && errorMessage != null && errorMessage.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMessage)));
      }
    } finally {
      _restoringHosting = false;
    }
  }

  Future<void> _onPaired(String identifier) async {
    if (identifier == widget.settings.identifier) return;
    await widget.settings.addPairedDevice(identifier);
    await _refreshPresence();
  }

  Future<void> _refreshPresence() async {
    final devices = widget.settings.pairedDevices;
    final statuses = await Future.wait(
      devices.map(
        (identifier) async => MapEntry(
          identifier,
          await PresenceService.isOnline(
            signalingUrl: widget.settings.signalingUrl,
            identifier: identifier,
          ),
        ),
      ),
    );
    if (mounted) setState(() => _onlineDevices = Map.fromEntries(statuses));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _targetIdentifier.dispose();
    _targetCode.dispose();
    _targetCodeFocus.dispose();
    _lanDevicesSubscription?.cancel();
    _lanDiscovery.dispose();
    _session
      ..removeListener(_onSessionChanged)
      ..dispose();
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(child: SafeArea(child: _buildPairedDevices(context))),
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined),
            SizedBox(width: 10),
            Text('RTC Transfer'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _session.isConnected
            ? _TransferWorkspace(
                session: _session,
                onDisconnect: () async {
                  await _session.disconnect();
                  await _restoreHosting();
                },
              )
            : _buildConnectionPage(context),
      ),
    );
  }

  Widget _buildConnectionPage(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusBanner(session: _session),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                _buildReceiveCard(context),
                _buildConnectCard(context),
              ];
              if (constraints.maxWidth >= 760) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 16),
                    Expanded(child: cards[1]),
                  ],
                );
              }
              return Column(
                children: [cards[0], const SizedBox(height: 16), cards[1]],
              );
            },
          ),
        ],
      ),
    ),
  );

  Widget _buildPairedDevices(BuildContext context) {
    final pairedDevices = widget.settings.pairedDevices.toSet();
    final devices = {...pairedDevices, ..._lanDevices.keys}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '设备列表',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: '刷新在线状态',
                onPressed: _refreshPresence,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: devices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('暂无设备\n局域网设备会自动发现，公网设备在完成 TOTP 验证后加入。'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final identifier = devices[index];
                    final lanDevice = _lanDevices[identifier];
                    final isLan = lanDevice != null;
                    final online =
                        isLan ||
                        (_onlineDevices[identifier] ?? false) ||
                        (_session.isConnected &&
                            _session.remoteIdentifier == identifier);
                    return GestureDetector(
                      onDoubleTap: online
                          ? () => _openTotpForDevice(identifier)
                          : null,
                      child: ListTile(
                        leading: Badge(
                          backgroundColor: online ? Colors.green : Colors.grey,
                          smallSize: 10,
                          child: CircleAvatar(
                            child: Icon(
                              isLan ? Icons.lan_outlined : Icons.public,
                              size: 20,
                            ),
                          ),
                        ),
                        title: Text(
                          identifier,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          isLan
                              ? '在线 · 双击验证'
                              : online
                              ? '在线 · 双击验证'
                              : '离线',
                        ),
                        trailing: pairedDevices.contains(identifier)
                            ? IconButton(
                                tooltip: '移除',
                                onPressed: () async {
                                  await widget.settings.removePairedDevice(
                                    identifier,
                                  );
                                  await _refreshPresence();
                                },
                                icon: const Icon(Icons.close, size: 18),
                              )
                            : null,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openTotpForDevice(String identifier) async {
    final controller = TextEditingController();
    final shouldConnect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('TOTP 验证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(identifier),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: '6 位 TOTP 安全码',
                counterText: '',
                prefixIcon: Icon(Icons.password),
              ),
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('验证并连接'),
          ),
        ],
      ),
    );
    if (shouldConnect == true && mounted) {
      _targetIdentifier.text = identifier;
      _targetCode.text = controller.text.trim();
      await _joinPeer();
    }
    controller.dispose();
  }

  Widget _buildReceiveCard(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('让对方连接我', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          const Text('唯一标识'),
          const SizedBox(height: 5),
          SelectableText(
            widget.settings.identifier,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 15,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    TotpService.code(widget.settings.totpSecret),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 4,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 58,
                height: 58,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(value: _remainingSeconds / 30),
                    Text('$_remainingSeconds'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _session.isConnected ? '身份已验证' : 'TOTP 安全码每 30 秒自动更新',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );

  Widget _buildConnectCard(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('连接另一台设备', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _targetIdentifier,
            enabled: !_session.isConnected,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _targetCodeFocus.requestFocus(),
            decoration: const InputDecoration(
              labelText: '对方唯一标识',
              prefixIcon: Icon(Icons.fingerprint),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetCode,
            focusNode: _targetCodeFocus,
            enabled: !_session.isConnected,
            maxLength: 6,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submitJoinFromKeyboard(),
            decoration: const InputDecoration(
              labelText: '6 位 TOTP 安全码',
              prefixIcon: Icon(Icons.key_outlined),
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _session.isConnected
                  ? () => unawaited(
                      _session.disconnect().then((_) => _startHosting()),
                    )
                  : _joinPeer,
              icon: Icon(_session.isConnected ? Icons.link_off : Icons.link),
              label: Text(_session.isConnected ? '断开连接' : '连接'),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _openSettings() async {
    final signaling = TextEditingController(text: widget.settings.signalingUrl);
    final identifier = TextEditingController(text: widget.settings.identifier);
    var totpSecret = widget.settings.totpSecret;
    var root = widget.settings.sharedRoot;
    var rootLabel = widget.settings.sharedRootLabel;
    var receiveDirectory = widget.settings.receiveDirectory;
    var receiveDirectoryLabel = widget.settings.receiveDirectoryLabel;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: signaling,
                    decoration: const InputDecoration(
                      labelText: '信令服务地址',
                      hintText: 'wss://example.workers.dev',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: identifier,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: '本机唯一标识',
                      suffixIcon: IconButton(
                        tooltip: '重新生成',
                        onPressed: () => setDialogState(
                          () =>
                              identifier.text = AppSettings.randomIdentifier(),
                        ),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Expanded(child: Text('TOTP 密钥')),
                            IconButton(
                              tooltip: '重新生成 TOTP 密钥',
                              onPressed: () => setDialogState(
                                () => totpSecret = TotpService.generateSecret(),
                              ),
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                        SelectableText(totpSecret),
                        const SizedBox(height: 10),
                        QrImageView(
                          data: TotpService.provisioningUriWithSecret(
                            identifier: identifier.text,
                            secret: totpSecret,
                          ),
                          size: 190,
                          backgroundColor: Colors.white,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('共享目录'),
                    subtitle: Text(rootLabel ?? '未设置，对方只能向你发送文件'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (root != null)
                          IconButton(
                            tooltip: '清除共享目录',
                            onPressed: () => setDialogState(() {
                              root = null;
                              rootLabel = null;
                            }),
                            icon: const Icon(Icons.clear),
                          ),
                        OutlinedButton(
                          onPressed: () async {
                            final selected =
                                await ReceiveStorage.pickDirectory();
                            if (selected != null) {
                              setDialogState(() {
                                root = selected.value;
                                rootLabel = selected.label;
                              });
                            }
                          },
                          child: const Text('选择'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('接收目录'),
                    subtitle: Text(receiveDirectoryLabel ?? '默认保存到应用专属下载目录'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (receiveDirectory != null)
                          IconButton(
                            tooltip: '恢复默认目录',
                            onPressed: () => setDialogState(() {
                              receiveDirectory = null;
                              receiveDirectoryLabel = null;
                            }),
                            icon: const Icon(Icons.clear),
                          ),
                        OutlinedButton(
                          onPressed: () async {
                            final selected =
                                await ReceiveStorage.pickDirectory();
                            if (selected != null) {
                              setDialogState(() {
                                receiveDirectory = selected.value;
                                receiveDirectoryLabel = selected.label;
                              });
                            }
                          },
                          child: const Text('选择'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await widget.settings.setSignalingUrl(signaling.text);
    await widget.settings.setIdentifier(identifier.text);
    await widget.settings.setTotpSecret(totpSecret);
    await widget.settings.setSharedRoot(root, rootLabel);
    await widget.settings.setReceiveDirectory(
      receiveDirectory,
      receiveDirectoryLabel,
    );
    _session
      ..removeListener(_onSessionChanged)
      ..dispose();
    _session = PeerSession(
      sharedRoot: widget.settings.sharedRoot,
      receiveDirectory: widget.settings.receiveDirectory,
      totpSecret: widget.settings.totpSecret,
      onPaired: _onPaired,
    )..addListener(_onSessionChanged);
    await _startPresence();
    await _startHosting();
    await _startLanDiscovery();
    await _refreshPresence();
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.session});

  final PeerSession session;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (session.status) {
      PeerStatus.idle => (Icons.circle_outlined, '未连接', Colors.grey),
      PeerStatus.waiting => (Icons.radar, '等待对方连接', Colors.blue),
      PeerStatus.connecting => (Icons.sync, '正在建立 P2P 连接', Colors.orange),
      PeerStatus.connected => (Icons.check_circle, 'P2P 已连接', Colors.green),
      PeerStatus.disconnected => (Icons.link_off, '连接已断开', Colors.grey),
      PeerStatus.error => (
        Icons.error_outline,
        session.errorMessage ?? '发生错误',
        Colors.red,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

enum _TransferMode { send, receive }

class _TransferWorkspace extends StatefulWidget {
  const _TransferWorkspace({required this.session, required this.onDisconnect});

  final PeerSession session;
  final Future<void> Function() onDisconnect;

  @override
  State<_TransferWorkspace> createState() => _TransferWorkspaceState();
}

class _TransferWorkspaceState extends State<_TransferWorkspace> {
  _TransferMode _mode = _TransferMode.send;
  String _localSharedPath = '';
  String _localReceivePath = '';
  String _remoteSharedPath = '';
  String _remoteReceivePath = '';
  List<FileEntry> _localEntries = const [];
  String _localDisplayPath = '';
  String? _localError;
  bool _localLoading = true;
  bool _remoteLoading = true;
  bool _disconnecting = false;
  int _completedReceives = 0;
  String? _completedReceiveBatchId;

  PeerDirectoryKind get _localKind => _mode == _TransferMode.send
      ? PeerDirectoryKind.shared
      : PeerDirectoryKind.receive;

  PeerDirectoryKind get _remoteKind => _mode == _TransferMode.send
      ? PeerDirectoryKind.receive
      : PeerDirectoryKind.shared;

  String get _localPath =>
      _mode == _TransferMode.send ? _localSharedPath : _localReceivePath;

  String get _remotePath =>
      _mode == _TransferMode.send ? _remoteReceivePath : _remoteSharedPath;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshWorkspace());
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    final completedReceives = widget.session.transfers
        .where(
          (task) =>
              task.direction == TransferDirection.receiving &&
              task.state == TransferState.complete,
        )
        .length;
    if (completedReceives != _completedReceives) {
      _completedReceives = completedReceives;
      if (_mode == _TransferMode.receive) unawaited(_loadLocalDirectory());
    }
    final overview = widget.session.transferOverview;
    if (overview != null &&
        overview.direction == TransferDirection.receiving &&
        overview.state == TransferState.complete &&
        overview.id != _completedReceiveBatchId) {
      _completedReceiveBatchId = overview.id;
      if (_mode == _TransferMode.receive) unawaited(_loadLocalDirectory());
    }
    final remoteReady =
        widget.session.remoteDirectoryKind == _remoteKind &&
        widget.session.remoteCurrentPath == _remotePath;
    setState(() {
      if (remoteReady) _remoteLoading = false;
    });
  }

  Future<void> _refreshWorkspace() async {
    _requestRemoteDirectory(_remotePath);
    await _loadLocalDirectory();
  }

  Future<void> _loadLocalDirectory() async {
    final kind = _localKind;
    final path = _localPath;
    setState(() {
      _localLoading = true;
      _localError = null;
    });
    try {
      final entries = await widget.session.listLocalDirectory(path, kind: kind);
      final displayPath = await widget.session.localDirectoryDisplayPath(
        path,
        kind: kind,
      );
      if (!mounted || kind != _localKind || path != _localPath) return;
      setState(() {
        _localEntries = entries;
        _localDisplayPath = displayPath;
        _localLoading = false;
      });
    } catch (error) {
      if (!mounted || kind != _localKind || path != _localPath) return;
      setState(() {
        _localEntries = const [];
        _localError = '无法读取目录：$error';
        _localLoading = false;
      });
    }
  }

  void _requestRemoteDirectory(String path) {
    setState(() => _remoteLoading = true);
    widget.session.requestRemoteDirectory(path, kind: _remoteKind);
  }

  void _setLocalPath(String path) {
    if (_mode == _TransferMode.send) {
      _localSharedPath = path;
    } else {
      _localReceivePath = path;
    }
    unawaited(_loadLocalDirectory());
  }

  void _setRemotePath(String path) {
    if (_mode == _TransferMode.send) {
      _remoteReceivePath = path;
    } else {
      _remoteSharedPath = path;
    }
    _requestRemoteDirectory(path);
  }

  void _changeMode(_TransferMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _localEntries = const [];
      _localLoading = true;
      _remoteLoading = true;
    });
    unawaited(_refreshWorkspace());
  }

  Future<void> _transfer(FileEntry entry) async {
    try {
      if (_mode == _TransferMode.send) {
        await widget.session.sendRelativePath(
          entry.relativePath,
          destinationDirectory: _remoteReceivePath,
          displayName: entry.name,
          totalBytes: entry.size,
          isDirectory: entry.isDirectory,
        );
        if (mounted) _requestRemoteDirectory(_remoteReceivePath);
      } else {
        widget.session.requestDownload(
          entry,
          destinationDirectory: _localReceivePath,
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('传输失败：$error')));
    }
  }

  Future<void> _disconnect() async {
    if (_disconnecting) return;
    setState(() => _disconnecting = true);
    await widget.onDisconnect();
  }

  @override
  Widget build(BuildContext context) {
    final remoteMatches =
        widget.session.remoteDirectoryKind == _remoteKind &&
        widget.session.remoteCurrentPath == _remotePath;
    final remoteEntries = remoteMatches
        ? widget.session.remoteEntries
        : const <FileEntry>[];
    final remoteError = remoteMatches
        ? widget.session.remoteBrowserError
        : null;
    final localPane = _FilePane(
      title: _mode == _TransferMode.send ? '本端共享目录' : '本端接收目录',
      path: _localDisplayPath,
      entries: _localEntries,
      loading: _localLoading,
      error: _localError,
      isSource: _mode == _TransferMode.send,
      isDestination: _mode == _TransferMode.receive,
      actionIcon: Icons.arrow_forward,
      actionTooltip: '发送到对端',
      onRefresh: _loadLocalDirectory,
      onUp: _localPath.isEmpty
          ? null
          : () => _setLocalPath(_parentPath(_localPath)),
      onOpen: (entry) => _setLocalPath(entry.relativePath),
      onAction: _mode == _TransferMode.send ? _transfer : null,
      onDrop: _mode == _TransferMode.receive ? _transfer : null,
    );
    final remotePane = _FilePane(
      title: _mode == _TransferMode.send ? '对端接收目录' : '对端共享目录',
      path: remoteMatches
          ? widget.session.remoteCurrentDisplayPath
          : _remotePath,
      entries: remoteEntries,
      loading: _remoteLoading,
      error: remoteError,
      isSource: _mode == _TransferMode.receive,
      isDestination: _mode == _TransferMode.send,
      actionIcon: Icons.download,
      actionTooltip: '下载到本端',
      onRefresh: () => _requestRemoteDirectory(_remotePath),
      onUp: _remotePath.isEmpty
          ? null
          : () => _setRemotePath(_parentPath(_remotePath)),
      onOpen: (entry) => _setRemotePath(entry.relativePath),
      onAction: _mode == _TransferMode.receive ? _transfer : null,
      onDrop: _mode == _TransferMode.send ? _transfer : null,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<_TransferMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _TransferMode.send,
                        icon: Icon(Icons.upload),
                        label: Text('发送模式'),
                      ),
                      ButtonSegment(
                        value: _TransferMode.receive,
                        icon: Icon(Icons.download),
                        label: Text('接收模式'),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (value) => _changeMode(value.first),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: _disconnecting ? null : _disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('断开'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: OrientationBuilder(
              builder: (context, orientation) {
                final panes = [localPane, remotePane];
                if (orientation == Orientation.landscape) {
                  return Row(
                    children: [
                      Expanded(child: panes[0]),
                      const VerticalDivider(width: 10),
                      Expanded(child: panes[1]),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(child: panes[0]),
                    const Divider(height: 10),
                    Expanded(child: panes[1]),
                  ],
                );
              },
            ),
          ),
          if (widget.session.transferOverview != null) ...[
            const SizedBox(height: 8),
            _TransferStatusBar(overview: widget.session.transferOverview!),
          ],
        ],
      ),
    );
  }

  static String _parentPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parent = p.posix.dirname(normalized);
    return parent == '.' ? '' : parent;
  }
}

class _FilePane extends StatelessWidget {
  const _FilePane({
    required this.title,
    required this.path,
    required this.entries,
    required this.loading,
    required this.error,
    required this.isSource,
    required this.isDestination,
    required this.actionIcon,
    required this.actionTooltip,
    required this.onRefresh,
    required this.onUp,
    required this.onOpen,
    required this.onAction,
    required this.onDrop,
  });

  final String title;
  final String path;
  final List<FileEntry> entries;
  final bool loading;
  final String? error;
  final bool isSource;
  final bool isDestination;
  final IconData actionIcon;
  final String actionTooltip;
  final VoidCallback onRefresh;
  final VoidCallback? onUp;
  final ValueChanged<FileEntry> onOpen;
  final ValueChanged<FileEntry>? onAction;
  final ValueChanged<FileEntry>? onDrop;

  @override
  Widget build(BuildContext context) => DragTarget<FileEntry>(
    onWillAcceptWithDetails: (_) => isDestination && onDrop != null,
    onAcceptWithDetails: (details) => onDrop?.call(details.data),
    builder: (context, candidates, rejected) {
      final highlighted = candidates.isNotEmpty;
      return Card(
        margin: EdgeInsets.zero,
        color: highlighted
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: highlighted
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: highlighted ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            ListTile(
              dense: true,
              leading: Icon(isSource ? Icons.outbox_outlined : Icons.inbox),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                path.isEmpty ? '/' : path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onUp != null)
                    IconButton(
                      tooltip: '返回上级',
                      onPressed: onUp,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildContents(context)),
          ],
        ),
      );
    },
  );

  Widget _buildContents(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(child: Text(isDestination ? '目录为空，可拖放到这里' : '目录为空'));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final tile = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: entry.isDirectory ? () => onOpen(entry) : null,
          child: ListTile(
            dense: true,
            leading: Icon(
              entry.isDirectory
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
            ),
            title: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(entry.isDirectory ? '文件夹' : formatBytes(entry.size)),
            trailing: onAction == null
                ? null
                : IconButton(
                    tooltip: actionTooltip,
                    onPressed: () => onAction?.call(entry),
                    icon: Icon(actionIcon),
                  ),
          ),
        );
        if (!isSource) return tile;
        Widget feedback() => Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: ListTile(
              leading: Icon(
                entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
              ),
              title: Text(entry.name, overflow: TextOverflow.ellipsis),
            ),
          ),
        );
        final isDesktop = switch (defaultTargetPlatform) {
          TargetPlatform.windows ||
          TargetPlatform.linux ||
          TargetPlatform.macOS => true,
          _ => false,
        };
        if (isDesktop) {
          return Draggable<FileEntry>(
            data: entry,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback(),
            childWhenDragging: Opacity(opacity: .35, child: tile),
            child: tile,
          );
        }
        return LongPressDraggable<FileEntry>(
          data: entry,
          feedback: feedback(),
          childWhenDragging: Opacity(opacity: .35, child: tile),
          child: tile,
        );
      },
    );
  }
}

class _TransferStatusBar extends StatelessWidget {
  const _TransferStatusBar({required this.overview});

  final TransferOverview overview;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            overview.direction == TransferDirection.sending
                ? Icons.upload
                : Icons.download,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  overview.currentFile ?? overview.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 7),
                LinearProgressIndicator(value: overview.progress),
                const SizedBox(height: 5),
                Text(
                  '${formatBytes(overview.transferredBytes)} / ${formatBytes(overview.totalBytes)}  ·  ${formatSpeed(overview.bytesPerSecond)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (overview.error != null)
                  Text(
                    overview.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(switch (overview.state) {
            TransferState.complete => Icons.check_circle,
            TransferState.failed => Icons.error,
            TransferState.cancelled => Icons.cancel,
            _ => Icons.sync,
          }),
        ],
      ),
    ),
  );
}
