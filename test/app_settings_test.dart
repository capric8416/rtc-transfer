import 'package:flutter_test/flutter_test.dart';
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

      await settings.addPairedDevice('lanPeer', isLan: true);
      await settings.addPairedDevice('publicPeer');
      await settings.rememberLanDevices(['publicPeer', 'unpairedPeer']);

      expect(settings.pairedDevices, ['lanPeer', 'publicPeer']);
      expect(settings.lanPairedDevices, ['lanPeer', 'publicPeer']);

      await settings.removePairedDevice('lanPeer');

      expect(settings.pairedDevices, ['publicPeer']);
      expect(settings.lanPairedDevices, ['publicPeer']);
    },
  );
}
