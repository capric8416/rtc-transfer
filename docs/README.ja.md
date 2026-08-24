# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | [Deutsch](README.de.md) | **日本語** | [Português](README.pt.md) | [한국어](README.ko.md) | [العربية](README.ar.md)

RTC Transfer は Flutter、WebRTC DataChannel、Rust Cloudflare Worker で構築されたクロスプラットフォーム P2P ファイル転送アプリです。Windows、Linux、macOS、Android、iOS に対応します。

## 機能

- 保護されたルート内で相手の共有ファイルを閲覧。
- ファイル、空フォルダー、完全なフォルダーツリーを進捗と速度付きで送受信。
- LAN デバイスを自動検出し、またはインターネットシグナリングで接続。
- 永続的な識別子と Base32 TOTP シークレットで認証。
- ファイルは暗号化 WebRTC DataChannel のみで転送し、Worker は接続調整だけを担当。
- システム言語に従うか、9 言語から手動選択。

## 実行と設定

```bash
flutter pub get
flutter run -d linux
```

**設定**で `wss://` Worker アドレス、共有フォルダー、受信フォルダー、言語を指定します。受信ファイルは既定でダウンロード内の `RTC Transfer` に保存されます。

## Worker のデプロイ

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health` はヘルスチェック、`/signal` は WebSocket エンドポイントです。TOTP シークレットは Worker に送信されません。シグナリングは WSS、ファイルは WebRTC SCTP/DTLS で暗号化されます。厳しい NAT では TURN が必要な場合があります。
