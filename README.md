# RTC Transfer

**English** | [中文](docs/README.zh-CN.md) | [Français](docs/README.fr.md) | [Español](docs/README.es.md) | [Deutsch](docs/README.de.md) | [日本語](docs/README.ja.md) | [Português](docs/README.pt.md) | [한국어](docs/README.ko.md) | [العربية](docs/README.ar.md)

RTC Transfer is a cross-platform P2P file transfer application built with Flutter, WebRTC DataChannel, and a Rust Cloudflare Worker. It supports Windows, Linux, macOS, Android, and iOS.

## Features

- Browse a peer's shared files and directories from a restricted root.
- Send or receive files, empty directories, and complete directory trees.
- View sizes, current file, total progress, transferred bytes, and live speed.
- Discover devices automatically on a LAN or connect through Internet signaling.
- Authenticate peers using a persistent unique identifier and a Base32 TOTP secret.
- Keep file data on encrypted WebRTC DataChannels; the Worker only coordinates connections.
- Follow the system language or choose English, Chinese, French, Spanish, German, Japanese, Portuguese, Korean, or Arabic.

## Run locally

```bash
flutter pub get
flutter run -d linux # or windows / macos / android / ios
```

Open **Settings** after the first launch:

1. Enter the deployed Worker URL, for example `wss://rtc-transfer-signaling.example.workers.dev`. Non-TLS signaling URLs are rejected.
2. Keep or regenerate the local unique identifier and TOTP secret.
3. Select the shared directory, receive directory, and preferred language.

Received files are saved under `RTC Transfer` in the system downloads directory by default. If that directory is unavailable, the application documents directory is used.

## Deploy the Rust Worker

Rust, Node.js, Wrangler, a Cloudflare account, and Durable Objects are required:

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

Wrangler installs the pinned `worker-build 0.1.x` under `worker/.worker-build/`. The project also pins `worker 0.6.x` and `wasm-bindgen 0.2.105`; keep the constraints in `wrangler.toml`.

`/health` reports service health and `/signal` is the WebSocket endpoint. The Durable Object uses a free-plan-compatible SQLite namespace (`new_sqlite_classes`) and partitions rooms by identifier. The TOTP secret never reaches the Worker: it forwards the submitted code to the host, which verifies it locally before SDP/ICE messages are relayed.

## Networking and security

The default STUN configuration works on many home networks. Symmetric NAT, restrictive enterprise firewalls, and some mobile networks may require a TURN server with temporary credentials in `PeerSession._iceServers`.

Signaling requires WSS. File data uses SCTP over DTLS as required by WebRTC. Data remains encrypted even when relayed through TURN, and Cloudflare Worker never receives file contents. Incoming paths are sanitized, and remote browsing cannot escape the selected root.

## Releases

Pushing a tag triggers `.github/workflows/release.yml`. CI validates the Rust Worker and builds Android/Linux on Ubuntu, Windows archives on Windows, and unsigned iOS/macOS packages on macOS. Apple distribution still requires your Developer signing credentials; production Android releases should replace the sample debug signing configuration.
