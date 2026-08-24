import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/l10n/app_localizations.dart';
import 'src/services/app_settings.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(RtcTransferApp(settings: settings));
}

class RtcTransferApp extends StatefulWidget {
  const RtcTransferApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<RtcTransferApp> createState() => _RtcTransferAppState();
}

class _RtcTransferAppState extends State<RtcTransferApp> {
  Locale? get _locale {
    final code = widget.settings.languageCode;
    return code == null ? null : Locale(code);
  }

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
    locale: _locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    localeResolutionCallback: AppLocalizations.resolveLocale,
    home: HomePage(
      settings: widget.settings,
      onLocaleChanged: (_) => setState(() {}),
    ),
  );
}
