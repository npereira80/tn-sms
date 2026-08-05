# Bubbles for Garmin (Connect IQ)

Read your SMS inbox on a Garmin watch (Venu 4 and friends) and answer with preset
replies. Written in Monkey C for Connect IQ.

**This is not a port of the Wear OS app.** Garmin doesn't run Android, so none of
the Kotlin/Compose code applies — this is a separate, deliberately small app, and
the platform can't do everything the Wear OS one does. The honest list is below.

## What it does

- Inbox: the 20 most recent conversations from the sync server, unread marked `•`.
- Thread: the 20 most recent messages, oldest first, each with a short timestamp
  and `→` for the ones you sent. MMS shows as `[foto]`.
- Reply: pick from **preset replies** you define in Garmin Connect Mobile (so they
  can be Portuguese). Sent through the sync server, which hands it to the phone
  holding the SIM — exactly like the Wear OS app's SMS path.
- One-way senders (OTP codes, banks) show "Não é possível responder" instead of a
  reply option, same rule as the phone and Wear apps.
- Small cache: the last inbox and last thread are persisted, so the list appears
  instantly and you can still read something out of Bluetooth range.

## Platform limits (why features are missing)

| Wear OS app | Garmin | Why |
|---|---|---|
| Free-text replies (Gboard, voice) | Preset replies only | Connect IQ exposes **no keyboard and no dictation** to third-party apps. Garmin's own quick replies are system-level and not available to us. |
| iMessage send/receive | Not included | BlueBubbles' `chat/query` returns everything at once; a response that size can't be parsed on-watch. It needs a compact server-side proxy first (see below). |
| Photos, contact avatars | `[foto]` marker | Image fetching goes through Garmin's proxy with tight constraints, and there's no contacts access on the watch. |
| Full offline history | Last snapshot only | No SQLite, and app storage is small. |
| Live updates (WebSocket) | On open + manual refresh | No sockets, and background runs are short with very little memory. |
| Works on Wi-Fi without the phone | Needs the phone in range | Every request goes out through Garmin Connect over Bluetooth (`-104` when it's away). |
| Contact names | Phone numbers | The watch can't read contacts, and the sync server stores numbers. |

Server URL must be **HTTPS** — the watch refuses plain HTTP. The Cloudflare tunnel
already satisfies this.

## Setup

1. Build and side-load (see below), then open the app once.
2. In **Garmin Connect Mobile ▸ Connect IQ ▸ Bubbles ▸ Settings**, fill in:
   - **Servidor SMS (https)** — e.g. `https://sms.tn-services.net`
   - **Segredo de registo** — the server's registration secret (same one the
     phone app uses). The watch registers itself and stores a token.
   - **Resposta 1…6** — your preset replies. Blank ones are skipped.
3. Reopen the app. The inbox loads.

## Build

Needs the Connect IQ SDK and the VS Code Monkey C extension.

```bash
# from this directory, with the SDK's bin on PATH
monkeyc -f monkey.jungle -d venu4 -o bin/Bubbles.prg -y <your-developer-key.der>
```

Then either run it in the simulator (`connectiq` + `monkeydo bin/Bubbles.prg venu4`)
or copy the `.prg` to the watch's `GARMIN/APPS` folder over USB.

Two things to check first:

- **Device id.** `venu4` is what the Venu 4 uses at time of writing; if your SDK
  disagrees, adjust `-d` and the `<iq:products>` list in `manifest.xml`.
- **Developer key.** Generate one in VS Code (*Connect IQ: Generate a Developer
  Key*) if you don't have a `.der` yet.

## Server API used

Compact, short-key endpoints added for this app (see `Server App/src/watch.ts`),
because Connect IQ fails at roughly 32KB of JSON and parsing costs more than
double that in memory:

- `GET /watch/chats?limit=20` → `{ c: [ {i,a,s,t,u} ] }`
- `GET /watch/messages?conversationId=…&limit=20` → `{ m: [ {i,d,b,t,p} ] }`
- `POST /send`, `POST /delete`, `POST /devices/register` — shared with the other clients.

## Possible next steps

- **iMessage**: add a compact proxy on the sync server (it already runs beside
  BlueBubbles on the Mac mini) exposing `/watch/imessage/*` in the same shape.
  Then the Garmin app can offer "Reply · iMessage" too.
- **Delete**: `Api.deleteConversation` is implemented but not yet wired to a menu
  action.
- **Mark read**: `POST /read` is not called yet.
