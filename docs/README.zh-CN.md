# RTC Transfer

[English](../README.md) | **中文** | [Français](README.fr.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [日本語](README.ja.md) | [Português](README.pt.md) | [한국어](README.ko.md) | [العربية](README.ar.md)

RTC Transfer 是使用 Flutter、WebRTC DataChannel 和 Rust Cloudflare Worker 构建的跨平台 P2P 文件传输应用，支持 Windows、Linux、macOS、Android 和 iOS。

## 功能

- 在受限根目录内浏览对端共享文件和目录。
- 发送或接收文件、空目录及完整目录树，并显示总进度与实时速度。
- 自动发现局域网设备，或通过公网信令连接。
- 使用持久化唯一标识和 Base32 TOTP 密钥验证对端。
- 文件数据仅通过加密的 WebRTC DataChannel 传输；Worker 只负责连接协调。
- 默认跟随系统语言，也可手动选择九种语言。

## 本地运行与设置

```bash
flutter pub get
flutter run -d linux # 或 windows / macos / android / ios
```

首次启动后打开“设置”，填写 `wss://` Worker 地址，确认唯一标识和 TOTP 密钥，并选择共享目录、接收目录及语言。接收文件默认保存到系统下载目录下的 `RTC Transfer`。

## 部署 Worker

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health` 用于健康检查，`/signal` 是 WebSocket 信令入口。TOTP 密钥不会发送给 Worker；Worker 只把动态码转发给主机本地验证。信令使用 WSS，文件数据使用 WebRTC SCTP/DTLS 加密。严格 NAT 环境可能需要配置 TURN。

推送 tag 会触发 `.github/workflows/release.yml`，构建 Android、Linux、Windows、macOS 和未签名 iOS 产物。
