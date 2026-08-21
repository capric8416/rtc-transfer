import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_platform.dart';
import 'totp_service.dart';

class AppSettings {
  AppSettings._(this._preferences);

  static const defaultSignalingUrl =
      'wss://rtc-transfer-signaling.example.workers.dev';
  static const _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  final SharedPreferences _preferences;

  String get signalingUrl =>
      _preferences.getString('signalingUrl') ?? defaultSignalingUrl;
  String get identifier => _preferences.getString('identifier') ?? '';
  String get totpSecret => _preferences.getString('totpSecret') ?? '';
  String get hostToken => _preferences.getString('hostToken') ?? '';
  String? get sharedRoot => _preferences.getString('sharedRoot');
  String? get sharedRootLabel => _preferences.getString('sharedRootLabel');
  String? get receiveDirectory => _preferences.getString('receiveDirectory');
  String? get receiveDirectoryLabel =>
      _preferences.getString('receiveDirectoryLabel');
  List<String> get pairedDevices =>
      _preferences.getStringList('pairedDevices') ?? const [];
  List<String> get lanPairedDevices =>
      _preferences.getStringList('lanPairedDevices') ?? const [];
  Map<String, DevicePlatform> get pairedDevicePlatforms {
    final encoded = _preferences.getString('pairedDevicePlatforms');
    if (encoded == null) return const {};
    try {
      final values = jsonDecode(encoded) as Map<String, dynamic>;
      return values.map(
        (identifier, platform) =>
            MapEntry(identifier, DevicePlatform.fromWire(platform)),
      );
    } catch (_) {
      return const {};
    }
  }

  static Future<AppSettings> load() async {
    final settings = AppSettings._(await SharedPreferences.getInstance());
    if (settings.identifier.isEmpty) {
      await settings.setIdentifier(_randomString(16));
    }
    if (settings.totpSecret.isEmpty) {
      await settings.regenerateTotpSecret();
    }
    if (settings.hostToken.isEmpty) {
      await settings._preferences.setString('hostToken', _randomString(32));
    }
    if (Platform.isAndroid &&
        settings.sharedRoot != null &&
        !settings.sharedRoot!.startsWith('content://')) {
      await settings.setSharedRoot(null);
    }
    return settings;
  }

  Future<void> setSignalingUrl(String value) => _preferences.setString(
    'signalingUrl',
    value.trim().replaceAll(RegExp(r'/$'), ''),
  );

  Future<void> setIdentifier(String value) =>
      _preferences.setString('identifier', value.trim());

  Future<void> regenerateIdentifier() => setIdentifier(_randomString(16));

  static String randomIdentifier() => _randomString(16);

  Future<void> regenerateTotpSecret() =>
      _preferences.setString('totpSecret', TotpService.generateSecret());

  Future<void> setTotpSecret(String value) =>
      _preferences.setString('totpSecret', value.trim().toUpperCase());

  Future<void> setSharedRoot(String? value, [String? label]) async {
    if (value == null) {
      await _preferences.remove('sharedRoot');
      await _preferences.remove('sharedRootLabel');
    } else {
      await _preferences.setString('sharedRoot', value);
      await _preferences.setString('sharedRootLabel', label ?? value);
    }
  }

  Future<void> setReceiveDirectory(String? value, String? label) async {
    if (value == null) {
      await _preferences.remove('receiveDirectory');
      await _preferences.remove('receiveDirectoryLabel');
    } else {
      await _preferences.setString('receiveDirectory', value);
      await _preferences.setString('receiveDirectoryLabel', label ?? value);
    }
  }

  Future<void> addPairedDevice(
    String identifier, {
    bool isLan = false,
    DevicePlatform platform = DevicePlatform.unknown,
  }) async {
    final devices = pairedDevices.toSet()..add(identifier);
    await _preferences.setStringList('pairedDevices', devices.toList()..sort());
    if (isLan) await rememberLanDevices([identifier]);
    await rememberDevicePlatforms({identifier: platform});
  }

  Future<void> rememberDevicePlatforms(
    Map<String, DevicePlatform> platforms,
  ) async {
    final paired = pairedDevices.toSet();
    final known = Map<String, DevicePlatform>.from(pairedDevicePlatforms);
    for (final entry in platforms.entries) {
      if (paired.contains(entry.key) && entry.value != DevicePlatform.unknown) {
        known[entry.key] = entry.value;
      }
    }
    known.removeWhere((identifier, _) => !paired.contains(identifier));
    await _preferences.setString(
      'pairedDevicePlatforms',
      jsonEncode(known.map((key, value) => MapEntry(key, value.name))),
    );
  }

  Future<void> rememberLanDevices(Iterable<String> identifiers) async {
    final paired = pairedDevices.toSet();
    final lanDevices = lanPairedDevices.toSet()
      ..addAll(identifiers.where(paired.contains));
    await _preferences.setStringList(
      'lanPairedDevices',
      lanDevices.toList()..sort(),
    );
  }

  Future<void> removePairedDevice(String identifier) async {
    final devices = pairedDevices.toSet()..remove(identifier);
    await _preferences.setStringList('pairedDevices', devices.toList()..sort());
    final lanDevices = lanPairedDevices.toSet()..remove(identifier);
    await _preferences.setStringList(
      'lanPairedDevices',
      lanDevices.toList()..sort(),
    );
    final platforms = Map<String, DevicePlatform>.from(pairedDevicePlatforms)
      ..remove(identifier);
    await _preferences.setString(
      'pairedDevicePlatforms',
      jsonEncode(platforms.map((key, value) => MapEntry(key, value.name))),
    );
  }

  static String _randomString(int length) {
    final random = Random.secure();
    return List.generate(
      length,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    ).join();
  }
}
