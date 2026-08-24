# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [日本語](README.ja.md) | [Português](README.pt.md) | **한국어** | [العربية](README.ar.md)

RTC Transfer는 Flutter, WebRTC DataChannel, Rust Cloudflare Worker로 만든 크로스 플랫폼 P2P 파일 전송 앱입니다. Windows, Linux, macOS, Android, iOS를 지원합니다.

## 기능

- 보호된 루트 안에서 상대의 공유 파일을 탐색합니다.
- 파일, 빈 폴더, 전체 폴더 트리를 진행률과 속도 표시와 함께 송수신합니다.
- LAN 기기를 자동 검색하거나 인터넷 시그널링으로 연결합니다.
- 영구 식별자와 Base32 TOTP 비밀 키로 상대를 인증합니다.
- 파일 데이터는 암호화된 WebRTC DataChannel로만 전송하며 Worker는 연결만 조정합니다.
- 시스템 언어를 따르거나 9개 언어 중 하나를 선택합니다.

## 실행 및 설정

```bash
flutter pub get
flutter run -d linux
```

**설정**에서 `wss://` Worker 주소, 공유 폴더, 수신 폴더, 언어를 선택합니다. 수신 파일은 기본적으로 다운로드의 `RTC Transfer`에 저장됩니다.

## Worker 배포

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health`는 상태 확인, `/signal`은 WebSocket 엔드포인트입니다. TOTP 비밀 키는 Worker에 전송되지 않습니다. 시그널링은 WSS, 파일은 WebRTC SCTP/DTLS로 암호화됩니다. 제한적인 NAT에서는 TURN이 필요할 수 있습니다.
