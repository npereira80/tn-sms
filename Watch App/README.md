# TN Watch (Wear OS)

A standalone Wear OS 3.0+ client that reads and replies to your messages over
Wi-Fi. Like the no-SIM Android app, it holds no SIM: SMS/MMS go through the sync
server's relay (your primary phone sends them), and iMessage goes straight to
your BlueBubbles server. Both are merged into one chat list, exactly like the
Android main app.

## What it does

- **Chat list** merged from both backends (a contact reachable on both shows a
  `••` marker).
- **Tap a chat** to read its thread (SMS/MMS + iMessage, oldest→newest, with
  photo thumbnails).
- **Reply only** (no new-conversation / new-contact flow). Compose with Gboard
  (or voice / handwriting) via the standard Wear input.
- **SMS or iMessage** per reply: on a contact reachable on both, a chip switches
  the send service (defaults to iMessage). SMS-only or iMessage-only chats send
  on their one service.

## Architecture

```
          ┌─────────────── Wear OS watch (this app) ───────────────┐
          │  ChatListScreen / ThreadScreen (Compose for Wear)      │
          │  Repository  ── merges by normalized address ──┐       │
          │     │                                          │       │
          │  SyncClient (REST + /stream WS)         BlueBubblesClient (REST) │
          └─────┼──────────────────────────────────────────┼───────┘
                │ Wi-Fi                                      │ Wi-Fi
        SMS sync server (/delta, /send relay)        BlueBubbles server
                │                                     (iMessage list/read/send)
         primary phone sends SMS/MMS
```

Credentials for both backends are **provisioned from the phone** over the Wear
Data Layer — the watch never asks you to type them.

## Config provisioning (phone → watch)

- Phone (the Flutter app): `MainActivity` exposes a `tnwatch/provision`
  MethodChannel; `WatchProvisioner` (Dart) pushes `{syncUrl, syncSecret, bbUrl,
  bbPassword}` at startup. Native `WatchProvisioner.kt` caches it and publishes a
  `/tnwatch/config` DataItem. `WatchConfigListenerService` re-pushes on request.
  The phone advertises the `tnwatch_config_provider` capability (`wear.xml`).
- Watch: `ConfigRequester` asks for a push on launch; `ConfigListenerService`
  stores whatever arrives. The watch then registers itself with the sync server
  (using the secret) and connects to BlueBubbles.

**Requirement:** the Wear Data Layer only delivers between apps signed with the
**same key**. Sign the watch app and the phone app with the same keystore (debug
builds already share the default debug key, so a debug watch + debug phone pair
works out of the box).

## Build & run

1. Open `Watch App/` in Android Studio (it's a standalone Gradle project) and let
   it sync. Min SDK 30 (Wear OS 3.0), target 34.
2. Build the phone app (the Flutter fork) with the new Wear provisioning code and
   run it on the paired phone at least once so it caches + pushes config.
3. Run the watch app on a Wear OS 3.0+ device/emulator paired with that phone.
4. Grant the contacts permission when prompted (names for SMS chats; iMessage
   names come from BlueBubbles).
5. The chat list should populate within a few seconds. Tap a chat, then **Reply**.

## Notes / limits (v1)

- Reply-only by design; no new-conversation or group-create flow.
- Live updates: SMS is effectively live (the `/stream` WebSocket nudges a
  refresh); iMessage and the open thread poll every few seconds while visible.
- Group chats appear (iMessage) and are replyable, but aren't merged with SMS.
- Read receipts / delete-from-watch are not implemented in v1.
- Gradle dependency versions are conservative; Android Studio may prompt to
  align them with your installed SDK/AGP.
