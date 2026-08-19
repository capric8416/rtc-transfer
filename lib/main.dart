import 'package:flutter/material.dart';

import 'src/services/app_settings.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(RtcTransferApp(settings: settings));
}

class RtcTransferApp extends StatelessWidget {
  const RtcTransferApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RTC Transfer',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff356859),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff7dc4aa),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    themeMode: ThemeMode.system,
    home: HomePage(settings: settings),
  );
}
