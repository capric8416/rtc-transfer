import 'dart:io';

enum DevicePlatform {
  android,
  ios,
  windows,
  linux,
  macos,
  unknown;

  static DevicePlatform get current {
    if (Platform.isAndroid) return android;
    if (Platform.isIOS) return ios;
    if (Platform.isWindows) return windows;
    if (Platform.isLinux) return linux;
    if (Platform.isMacOS) return macos;
    return unknown;
  }

  static DevicePlatform fromWire(Object? value) {
    final name = value?.toString().toLowerCase();
    return DevicePlatform.values.firstWhere(
      (platform) => platform.name == name,
      orElse: () => unknown,
    );
  }
}
