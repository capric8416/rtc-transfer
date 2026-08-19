# RTC Transfer

一个使用 Flutter + WebRTC DataChannel + Rust Cloudflare Worker 构建的跨平台 P2P 文件工具，支持 Windows、Linux、macOS、Android 和 iOS。

## 能力

- 双方可选择一个共享根目录，远程逐级浏览文件和目录。
- 下载远端文件/目录，或主动向对端发送多个文件/整个目录。
- 显示文件/目录大小、逐文件传输进度、已传字节数和实时速度。
- 唯一标识和 Base32 TOTP 密钥持久化保存，均可在设置中重新生成。
- 显示 6 位动态安全码、密钥文本和兼容身份验证器的 `otpauth://` 二维码。
- 对端提交唯一标识和当前安全码后，由持有密钥的主机本地验证；密钥不会发送给 Worker。
- 左侧持久化展示已配对设备并定时标记在线/离线；双击在线设备即可弹出 TOTP 验证并连接。
- 每个安装持久化独立的 32 位主机实例令牌；应用重启可安全接管残留 WebSocket，不同安装不能仅凭复制唯一标识抢占房间。
- Cloudflare Worker 只转发 SDP/ICE 信令，文件内容通过 WebRTC 点对点传输。

## 本地运行

```bash
flutter pub get
flutter run -d linux # 或 windows / macos / android / ios
```

首次启动后进入“设置”：

1. 填写部署后的 Worker 地址，例如 `wss://rtc-transfer-signaling.example.workers.dev`。应用拒绝非 TLS 的信令地址。
2. 可修改自动生成的本机唯一标识。
3. 选择希望允许对端浏览的共享目录。

接收文件默认保存在系统下载目录下的 `RTC Transfer`；若平台不提供下载目录，则使用应用文档目录。

## 部署 Rust Worker

需要 Rust、Node.js、Wrangler 和 Cloudflare 账户（Durable Objects 需已在账户中启用）：

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

Wrangler 会把 `worker-build 0.1.x` 安装在 `worker/.worker-build/` 后再构建，不受全局已安装版本影响。项目按参考工程锁定为 `worker 0.6.x`、`wasm-bindgen 0.2.105` 和 `worker-build 0.1.x`；不要把 `wrangler.toml` 中的版本约束移除。

部署后的 `/health` 返回服务状态，`/signal` 是 WebSocket 信令入口。Durable Object 使用免费计划兼容的 SQLite namespace（`new_sqlite_classes`），以唯一标识分片房间，最多接受一个 host 和一个 peer。未认证 peer 的消息只允许 TOTP 认证请求；Worker 将动态码通过 WSS 转发给 host，本地验证通过后才会转发 SDP/ICE。

## 网络说明

默认 STUN 配置适合多数家庭网络，但对称 NAT、严格企业防火墙或部分移动网络可能无法建立直连。生产环境应在 `PeerSession._iceServers` 中增加带临时凭证的 TURN 服务。信令强制使用 TLS（WSS）；文件 DataChannel 按 WebRTC 标准使用 SCTP/DTLS 加密。WebRTC 数据面不能改用普通 TLS，DTLS 是其面向 UDP 的标准 TLS 安全层。即便经过 TURN，中继的仍是加密的 WebRTC 数据，Cloudflare Worker 不会接触文件内容。

当前协议一次串行发送一个文件，以 64 KiB 分块并根据 DataChannel 缓冲区施加背压；目录会递归展开为保持相对路径的文件序列。接收端会清理 `..` 等路径片段，发送端也把远程浏览限制在所选共享根目录内。

## 发布

推送任意 tag 会触发 `.github/workflows/release.yml`：

- 校验 Rust Worker 的格式和 wasm32 编译；
- 在 Ubuntu 构建 Android APK 和 Linux bundle；
- 在 Windows 构建 zip；
- 在 macOS 构建未签名 iOS/macOS 包；
- 汇总产物并创建 GitHub Release。

iOS/macOS 的商店或正式分发仍需在自己的 Apple Developer 账户中签名；Android 正式发布应替换示例 debug signingConfig。
