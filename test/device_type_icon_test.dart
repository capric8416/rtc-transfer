import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtc_transfer/src/models/device_platform.dart';
import 'package:rtc_transfer/src/ui/widgets/device_type_icon.dart';

void main() {
  testWidgets('shows overlapping operating system and network icons', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DeviceTypeIcon(platform: DevicePlatform.windows, isLan: true),
        ),
      ),
    );

    expect(find.byIcon(Icons.desktop_windows), findsOneWidget);
    expect(find.byIcon(Icons.lan_outlined), findsOneWidget);

    final stack = tester.widget<Stack>(
      find.descendant(
        of: find.byType(DeviceTypeIcon),
        matching: find.byType(Stack),
      ),
    );
    final systemLayer = stack.children[0] as Positioned;
    final networkLayer = stack.children[1] as Positioned;
    expect(systemLayer.left, 0);
    expect(networkLayer.right, 0);
  });
}
