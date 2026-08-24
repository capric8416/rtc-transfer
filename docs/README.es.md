# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | [Français](README.fr.md) | **Español** | [Deutsch](README.de.md) | [日本語](README.ja.md) | [Português](README.pt.md) | [한국어](README.ko.md) | [العربية](README.ar.md)

RTC Transfer es una aplicación P2P multiplataforma creada con Flutter, WebRTC DataChannel y un Cloudflare Worker en Rust. Compatible con Windows, Linux, macOS, Android e iOS.

## Funciones

- Explora los archivos compartidos del par dentro de una raíz protegida.
- Envía y recibe archivos, carpetas vacías y árboles completos con progreso y velocidad.
- Descubre automáticamente dispositivos LAN o conecta mediante señalización por Internet.
- Autentica pares con un identificador persistente y un secreto TOTP Base32.
- Los datos viajan solo por un DataChannel WebRTC cifrado; el Worker únicamente coordina la conexión.
- Sigue el idioma del sistema o permite elegir uno de nueve idiomas.

## Ejecución y configuración

```bash
flutter pub get
flutter run -d linux
```

En **Ajustes**, introduce la dirección `wss://` del Worker y elige las carpetas compartida y de recepción, además del idioma. Los archivos recibidos se guardan por defecto en `RTC Transfer` dentro de Descargas.

## Desplegar el Worker

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health` comprueba el servicio y `/signal` ofrece la señalización WebSocket. El secreto TOTP nunca se envía al Worker. WSS protege la señalización y WebRTC SCTP/DTLS cifra los archivos. Una red NAT estricta puede requerir TURN.
