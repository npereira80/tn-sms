# Bubbles for Mac (SMS TN)

Native macOS client for the self-hosted SMS sync server, with iMessage
alongside it through BlueBubbles. SMS and MMS arrive from the Android
phone via the server; iMessage is received directly from a BlueBubbles
server; both render in one inbox.

It began as a Google Messages client built on Beeper's `libgm`. That
protocol layer was removed in September 2026 (see `REFACTOR-v3.md` and
the "Google Messages" commits); nothing here speaks to Google any more.

## Architecture

```
┌───────────────────── Bubbles.app (Swift/SwiftUI) ────────────────────┐
│  UI (SwiftUI)  ←  AppModel (@Observable, MainActor)                  │
│                     │              │                                 │
│                OTPCenter     MediaStore (cache-all)                  │
│                     │              │                                 │
│            AppDatabase (GRDB/SQLite mirror, no tombstones)           │
│                     │                          │                     │
│            ServerClient (REST + WebSocket)  BlueBubblesClient (poll) │
└──────────────────────────────────────────────────────────────────────┘
             │                                    │
   SMS sync server (Mac mini)            BlueBubbles server
             │
   Android phone with the SIM
```

Key decisions:

- **Transport:** REST for registration, history (`/delta`) and outbound
  send (`/send`), plus a reconnecting WebSocket (`/stream`) surfaced as
  an AsyncStream. A 60s delta poll runs alongside it so a dropped frame
  cannot leave the Mac stale.
- **Identity:** a number is keyed in one canonical form, full
  international. The server defines it and every client mirrors it,
  because the content hash built from it is how a delete on one device is
  matched on another. See ADR-015 in the Android repo.
- **Storage:** SQLite via GRDB. The local database mirrors current state:
  deletions are hard deletes, with no archive (spec §3.2).
- **Media:** cache-all. Every attachment downloads at sync time into
  `~/Library/Containers/macDroid.SMS-TN/…/Application Support/SMS TN/Media`.
- **Secrets:** the server token and the BlueBubbles password live in the
  macOS Keychain only. OTP codes stay in memory and expire after three
  minutes.

## Building

Prerequisites: Xcode 26+.

Open `Mac App/SMS TN/SMS TN.xcodeproj` and build. Xcode resolves the GRDB
package on first open. There is no longer a framework to build first.

On first run, sign in with the email on your sync server account. The
code is delivered as an SMS to the phone holding the SIM, and history
imports straight after.

## Sync behaviour

- **Realtime:** new messages, read state and deletions arrive on the
  WebSocket while the app is open.
- **Delta poll:** every 60 seconds the app re-pulls `/delta` from its
  cursor, which also carries the full read-state snapshot, so it
  converges even after a missed event. ⌘R forces a pull.
- **Deletes:** deleting on the Mac removes the message from the server
  and broadcasts a tombstone to the other clients. It does not touch the
  phone's own SMS store, which keeps its copy.
- **Offline:** the local copy is readable with no network. The app opens
  straight into `ready` and connects in the background.

## Known limitations

1. Phone off or offline means nothing new flows: it holds the SIM.
2. Sending attachments from the Mac is not implemented. The app says so
   rather than appearing to send. Receiving them works.
3. Reactions render but nothing writes them since the Google protocol
   went away. BlueBubbles tapbacks would be the way back in.
4. Deleted messages are not archived, by design.

## Layout

```
Mac App/
└── SMS TN/                   Xcode project
    └── SMS TN/
        ├── SMS_TNApp.swift   entry, menu commands, notification actions
        ├── AppModel.swift    coordinator: sync, send path, selection, state
        ├── Server/           ServerClient, BlueBubblesClient, models
        ├── Store/            AppDatabase (GRDB), Records, MediaStore, Keychain
        ├── OTP/OTPCenter.swift
        └── UI/               Root/ConversationList/Thread/Compose views
```
