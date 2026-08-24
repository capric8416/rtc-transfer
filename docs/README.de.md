# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | **Deutsch** | [日本語](README.ja.md) | [Português](README.pt.md) | [한국어](README.ko.md) | [العربية](README.ar.md)

RTC Transfer ist eine plattformübergreifende P2P-Dateiübertragung mit Flutter, WebRTC DataChannel und einem Rust Cloudflare Worker. Unterstützt werden Windows, Linux, macOS, Android und iOS.

## Funktionen

- Freigegebene Dateien des Peers innerhalb eines geschützten Stammordners durchsuchen.
- Dateien, leere Ordner und vollständige Verzeichnisbäume mit Fortschritt und Geschwindigkeit übertragen.
- LAN-Geräte automatisch erkennen oder über Internet-Signalisierung verbinden.
- Peers mit dauerhafter Kennung und Base32-TOTP-Geheimnis authentifizieren.
- Dateidaten ausschließlich über einen verschlüsselten WebRTC DataChannel übertragen; der Worker koordiniert nur die Verbindung.
- Systemsprache verwenden oder eine von neun Sprachen auswählen.

## Ausführen und einrichten

```bash
flutter pub get
flutter run -d linux
```

Tragen Sie unter **Einstellungen** die `wss://`-Worker-Adresse ein und wählen Sie Freigabeordner, Empfangsordner und Sprache. Empfangene Dateien landen standardmäßig unter Downloads in `RTC Transfer`.

## Worker bereitstellen

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health` prüft den Dienst, `/signal` ist der WebSocket-Endpunkt. Das TOTP-Geheimnis verlässt den Host nie. WSS schützt die Signalisierung und WebRTC SCTP/DTLS verschlüsselt Dateien. Bei strengem NAT kann TURN erforderlich sein.
