# Mac App Refactor — v2 (libgm) → v3 (server client)

> **Status (implemented):** Read + text-send against the self-hosted server is done.
> New files: `Server/ServerConfig.swift`, `Server/ServerModels.swift`, `Server/ServerClient.swift`.
> `KeychainStore.serverToken` added; `AppDatabase.applyServerMessages(_:)` maps server
> messages into the existing `conversation`/`message` tables; `AppModel` now registers,
> pulls `/delta`, streams `/stream`, and sends via `/send` (optimistic row + `send_status`).
> `ThreadView` title resolves via Contacts. The libgm `BridgeClient`/GmBridge/pairing code
> is left in place but **dormant** (never constructed). Not yet wired: brand-new-conversation
> compose ("New Message"), attachment/MMS send, media rendering.



The Mac app currently talks **directly** to Google Messages' web protocol via
`GMessages/BridgeClient.swift` + the GmBridge Go/`libgm` framework. Under v3 it
becomes a **client of the self-hosted SMS Sync server** instead. Keep everything
above the network layer; replace only the transport.

## Keep as-is

- `Store/AppDatabase.swift`, `Store/Records.swift`, `Store/MediaStore.swift` — GRDB mirror.
- `Sync/SyncEngine.swift` — reconcile logic (re-point its source from bridge events to server delta/stream).
- `UI/*` — conversation list, thread, compose.
- `OTP/OTPCenter.swift` — OTP detection + (future) browser extensions.
- `GMessages/GMEvent.swift`, `ProtoModels.swift` — reuse as the internal event/record shape; map server payloads into these so downstream code barely changes.
- `GMessages/KeychainStore.swift` — now stores the **server device token** instead of Google pairing session.

## Remove / retire

- `GMessages/BridgeClient.swift` — the `libgm` async wrapper.
- GmBridge Go framework dependency: `GmBridge/` (bridge.go, events.go), `Scripts/build-gmbridge.sh`, and the `Gmbridge.xcframework` reference in the Xcode project.
- Google web-pairing UI: `UI/PairingView.swift`, `UI/GoogleLoginView.swift` (replace with a simple "server URL + registration" screen).

## Add

- `Server/ServerClient.swift`
  - REST: `POST /devices/register` (once, store token in Keychain), `GET /delta?since=` for catch-up, `POST /send` from `ComposeView`.
  - WebSocket `/stream`: inbound `message` / `conversation` / `primary_changed` / `send_status`, mapped into `GMEvent` and fed to `SyncEngine` exactly like the old bridge events.
  - Base URL: `http://localhost:8787` when running on the Mac mini itself; the Cloudflare hostname otherwise.
- `Server/ServerModels.swift` — Codable structs matching the server JSON (mirror of `Server App/src` wire shapes).

## Sequencing

Do this **after** the server's `/delta` + `/stream` are solid (server build order steps 1–5), so `ServerClient` targets a stable API. `SyncEngine` and the UI should require only the swap of their event source, not a rewrite.

## Note on send

`ComposeView` send now returns a `requestId`; reflect `send_status` transitions
(`queued → sent → delivered/failed`) in the thread. Remember sends won't appear
in Google Messages on the phone (non-default app can't write the provider) —
surface them from our own store so the Mac thread stays complete.
