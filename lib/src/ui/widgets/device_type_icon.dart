import 'package:flutter/material.dart';

import '../../models/device_platform.dart';

class DeviceTypeIcon extends StatelessWidget {
  const DeviceTypeIcon({
    super.key,
    required this.platform,
    required this.isLan,
  });

  final DevicePlatform platform;
  final bool isLan;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 46,
      height: 38,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 1,
            child: CircleAvatar(
              radius: 18,
              backgroundColor: colors.secondaryContainer,
              foregroundColor: colors.onSecondaryContainer,
              child: Icon(_platformIcon(platform), size: 21),
            ),
          ),
          Positioned(
            right: 0,
            top: 6,
            child: CircleAvatar(
              radius: 14,
              backgroundColor: colors.primaryContainer,
              foregroundColor: colors.onPrimaryContainer,
              child: Icon(isLan ? Icons.lan_outlined : Icons.public, size: 17),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _platformIcon(DevicePlatform platform) => switch (platform) {
    DevicePlatform.android => Icons.android,
    DevicePlatform.ios => Icons.phone_iphone,
    DevicePlatform.windows => Icons.desktop_windows,
    DevicePlatform.linux => Icons.computer,
    DevicePlatform.macos => Icons.laptop_mac,
    DevicePlatform.unknown => Icons.devices_other,
  };
}
