# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [日本語](README.ja.md) | [Português](README.pt.md) | [한국어](README.ko.md) | **العربية**

RTC Transfer تطبيق متعدد المنصات لنقل الملفات من نظير إلى نظير، مبني باستخدام Flutter وWebRTC DataChannel وCloudflare Worker مكتوب بلغة Rust. يدعم Windows وLinux وmacOS وAndroid وiOS.

## الميزات

- تصفح الملفات المشتركة للطرف الآخر ضمن مجلد جذر محمي.
- إرسال واستقبال الملفات والمجلدات الفارغة وأشجار المجلدات كاملة مع عرض التقدم والسرعة.
- اكتشاف أجهزة الشبكة المحلية تلقائيًا أو الاتصال عبر الإشارة على الإنترنت.
- مصادقة الأجهزة بمعرّف دائم وسر TOTP بصيغة Base32.
- نقل البيانات فقط عبر WebRTC DataChannel مشفّر؛ ينسّق Worker الاتصال فحسب.
- اتباع لغة النظام أو اختيار واحدة من تسع لغات.

## التشغيل والإعداد

```bash
flutter pub get
flutter run -d linux
```

من **الإعدادات** أدخل عنوان Worker الذي يبدأ بـ `wss://` واختر المجلد المشترك ومجلد الاستقبال واللغة. تُحفظ الملفات افتراضيًا في `RTC Transfer` داخل التنزيلات.

## نشر Worker

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

يستخدم `/health` لفحص الخدمة و`/signal` لاتصال WebSocket. لا يُرسل سر TOTP إلى Worker. تحمي WSS الإشارة، وتشفّر WebRTC SCTP/DTLS الملفات. قد تتطلب شبكات NAT الصارمة خادم TURN.
