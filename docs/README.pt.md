# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [日本語](README.ja.md) | **Português** | [한국어](README.ko.md) | [العربية](README.ar.md)

RTC Transfer é uma aplicação P2P multiplataforma criada com Flutter, WebRTC DataChannel e um Cloudflare Worker em Rust. Suporta Windows, Linux, macOS, Android e iOS.

## Funcionalidades

- Navegar pelos ficheiros partilhados do par dentro de uma raiz protegida.
- Enviar e receber ficheiros, pastas vazias e árvores completas com progresso e velocidade.
- Descobrir dispositivos LAN automaticamente ou ligar por sinalização na Internet.
- Autenticar pares com identificador persistente e segredo TOTP Base32.
- Transferir dados apenas por WebRTC DataChannel cifrado; o Worker só coordena a ligação.
- Seguir o idioma do sistema ou escolher um dos nove idiomas.

## Executar e configurar

```bash
flutter pub get
flutter run -d linux
```

Em **Definições**, introduza o endereço `wss://` do Worker e escolha as pastas partilhada e de receção e o idioma. Os ficheiros recebidos são guardados por predefinição em `RTC Transfer` dentro de Transferências.

## Implementar o Worker

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health` verifica o serviço e `/signal` é o endpoint WebSocket. O segredo TOTP nunca é enviado ao Worker. WSS protege a sinalização e WebRTC SCTP/DTLS cifra os ficheiros. Redes NAT restritas podem exigir TURN.
