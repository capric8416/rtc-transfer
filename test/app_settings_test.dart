import 'package:flutter_test/flutter_test.dart';
import 'package:rtc_transfer/src/models/device_platform.dart';
import 'package:rtc_transfer/src/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'persists LAN origin for paired devices and clears it on removal',
    () async {
      SharedPreferences.setMockInitialValues({
        'identifier': 'localDevice',
        'totpSecret': 'JBSWY3DPEHPK3PXP',
        'hostToken': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ123456',
      });
      final settings = await AppSettings.load();

      await settings.addPairedDevice(
        'lanPeer',
        isLan: true,
        platform: DevicePlatform.linux,
      );
      await settings.addPairedDevice('publicPeer');
      await settings.rememberLanDevices(['publicPeer', 'unpairedPeer']);
      await settings.rememberDevicePlatforms({
        'publicPeer': DevicePlatform.android,
        'unpairedPeer': DevicePlatform.windows,
      });

      expect(settings.pairedDevices, ['lanPeer', 'publicPeer']);
      expect(settings.lanPairedDevices, ['lanPeer', 'publicPeer']);
      expect(settings.pairedDevicePlatforms, {
        'lanPeer': DevicePlatform.linux,
        'publicPeer': DevicePlatform.android,
      });

      await settings.removePairedDevice('lanPeer');

      expect(settings.pairedDevices, ['publicPeer']);
      expect(settings.lanPairedDevices, ['publicPeer']);
      expect(settings.pairedDevicePlatforms, {
        'publicPeer': DevicePlatform.android,
      });
    },
  );
}
