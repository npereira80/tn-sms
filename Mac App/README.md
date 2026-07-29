# SMS TN — Mac Google Messages Client

Native macOS client for Google Messages, implementing
`Mac-GMessages-Client-Specs-v2-Simplified.md` build-order steps 1-5:
protocol layer (pairing + realtime receive), local offline store,
conversation UI, send path, delta sync with hard-delete mirroring, and
OTP detection. Browser extensions (steps 6-7) are a later phase; the
OTP detection layer they will consume is already in place.

## Architecture

```
┌──────────────────────── SMS TN.app (Swift/SwiftUI) ───────────────────────┐
│  UI (SwiftUI)  ←  AppModel (@Observable, MainActor)                       │
│                     │            │              │                         │
│               SyncEngine    OTPCenter      MediaStore (cache-all)         │
│                     │                           │                         │
│               AppDatabase (GRDB/SQLite mirror, no tombstones)             │
│                     │                                                     │
│               BridgeClient (async wrapper, AsyncStream of events)         │
│                     │                                                     │
│  Gmbridge.xcframework  ←  gomobile bind of GmBridge/ (Go)                 │
│                     │                                                     │
│  libgm (Beeper's reverse-engineered Google Messages web protocol)         │
└───────────────────────────────────────────────────────────────────────────┘
                       │  TLS (ATS fully enabled)
              Google's servers  ←──  paired Android phone (stock Messages)
```

Key decisions (from spec + kickoff):

- **Protocol layer:** embeds `libgm` from mautrix-gmessages via gomobile,
  pinned to a known-working commit (see `Scripts/build-gmbridge.sh`).
  Rebuild with `--update` if Google changes the protocol and upstream
  has adapted.
- **Storage:** SQLite via GRDB. The local DB is a mirror of current
  Google Messages state: deletions are hard-deleted, no archive
  (spec §3.2). Dedup by protocol message ID with a
  timestamp+sender+content-hash fallback.
- **Media:** cache-all. Every attachment downloads at receive/sync time
  into `~/Library/Containers/macDroid.SMS-TN/…/Application Support/SMS TN/Media`.
- **Secrets:** pairing session lives in the macOS Keychain only. OTP
  codes stay in memory and expire after 3 minutes.

## Building

Prerequisites: Xcode 26+, Go 1.25+ (`brew install go`).

1. Build the protocol framework (first time and after protocol updates):

   ```bash
   cd "Mac App/Scripts"
   ./build-gmbridge.sh
   ```

   This produces `Mac App/GmBridge/build/Gmbridge.xcframework`, which the
   Xcode project already references.

2. Open `Mac App/SMS TN/SMS TN.xcodeproj` and build/run. Xcode resolves
   the GRDB package on first open.

3. On first run, scan the QR code with Google Messages on the phone
   (profile picture → Device pairing). Initial full-history import runs
   after pairing; progress shows in the window banner.

If the Swift compiler reports a signature mismatch against the
generated `Gmbridge` module (gomobile occasionally shifts parameter
labels between versions), check the generated header:
`Gmbridge.xcframework/macos-*/Gmbridge.framework/Headers/Gmbridge.objc.h`
and adjust the call in `GMessages/BridgeClient.swift` accordingly.

## Sync behavior (spec §3.2)

- **Realtime:** messages arrive over libgm's long-poll while the phone
  is on and connected; they are upserted by message ID (never
  duplicated).
- **Reconnect delta:** on every successful connect, the conversation
  list is mirrored (conversations deleted remotely are hard-deleted
  locally, cascading), and each conversation's recent window (last
  synced timestamp minus 7 days) is reconciled: new remote messages
  imported, local messages missing remotely hard-deleted.
- **Deep verify:** the web protocol does not push realtime deletion
  events, so a full-history reconciliation ("Verify Full Sync" in the
  app menu) walks every conversation and removes anything deleted
  remotely. It runs automatically as the initial import after pairing.
- **Offline:** the full local copy is readable with no network; the app
  opens straight into `ready` state and connects in the background.

## Known limitations (accepted, spec §4)

1. Phone off/offline → nothing flows (protocol relays through phone).
2. Unofficial protocol; Google can break it. Mitigation: pinned libgm
   commit + `--update` rebuild path.
3. Single Mac client, one paired phone.
4. Deleted messages are not archived, by design.
5. Older deletions are mirrored on deep verify (menu/post-pairing pass),
   not on every reconnect; recent-window deletions mirror every
   reconnect.

## Layout

```
Mac App/
├── GmBridge/                 Go module wrapping libgm (gomobile API)
│   ├── bridge.go             client calls (pairing, list, send, media)
│   └── events.go             libgm events → JSON for Swift
├── Scripts/build-gmbridge.sh xcframework build (pinned protocol commit)
└── SMS TN/                   Xcode project
    └── SMS TN/
        ├── SMS_TNApp.swift   entry, notification actions
        ├── AppModel.swift    coordinator: events, send path, state
        ├── GMessages/        BridgeClient, GMEvent, ProtoModels, Keychain
        ├── Store/            AppDatabase (GRDB), Records, MediaStore
        ├── Sync/SyncEngine.swift
        ├── OTP/OTPCenter.swift
        └── UI/               Root/Pairing/ConversationList/Thread views
```
