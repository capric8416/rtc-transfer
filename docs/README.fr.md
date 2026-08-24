# RTC Transfer

[English](../README.md) | [中文](README.zh-CN.md) | **Français** | [Español](README.es.md) | [Deutsch](README.de.md) | [日本語](README.ja.md) | [Português](README.pt.md) | [한국어](README.ko.md) | [العربية](README.ar.md)

RTC Transfer est une application multiplateforme de transfert P2P créée avec Flutter, WebRTC DataChannel et un Cloudflare Worker en Rust. Elle fonctionne sous Windows, Linux, macOS, Android et iOS.

## Fonctionnalités

- Parcourir les fichiers partagés du pair dans une racine protégée.
- Envoyer et recevoir fichiers, dossiers vides et arborescences complètes avec progression et débit.
- Détecter automatiquement les appareils LAN ou utiliser la signalisation Internet.
- Authentifier les pairs par identifiant persistant et secret TOTP Base32.
- Transférer les données uniquement sur un DataChannel WebRTC chiffré ; le Worker ne coordonne que la connexion.
- Suivre la langue du système ou choisir l’une des neuf langues prises en charge.

## Exécution et configuration

```bash
flutter pub get
flutter run -d linux
```

Dans **Paramètres**, indiquez l’adresse `wss://` du Worker, puis choisissez les dossiers partagé et de réception ainsi que la langue. Les fichiers reçus vont par défaut dans `RTC Transfer` sous Téléchargements.

## Déployer le Worker

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

`/health` vérifie le service et `/signal` fournit la signalisation WebSocket. Le secret TOTP ne quitte jamais l’hôte. WSS protège la signalisation et WebRTC SCTP/DTLS chiffre les fichiers. Un serveur TURN peut être nécessaire derrière un NAT strict.
