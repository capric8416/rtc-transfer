import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtc_transfer/src/l10n/app_localizations.dart';

void main() {
  test('unsupported system languages fall back to English', () {
    expect(
      AppLocalizations.resolveLocale(
        const Locale('it'),
        AppLocalizations.supportedLocales,
      ),
      const Locale('en'),
    );
  });

  testWidgets('Arabic translations use right-to-left layout', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => Directionality(
            textDirection: Directionality.of(context),
            child: Text(context.tr('设置')),
          ),
        ),
      ),
    );

    expect(find.text('الإعدادات'), findsOneWidget);
    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).last)
          .textDirection,
      TextDirection.rtl,
    );
  });
}
