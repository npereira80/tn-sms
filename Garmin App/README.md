# Bubbles for Garmin (Connect IQ)

Read your merged **SMS + iMessage** inbox on a Garmin watch (Venu 4 and friends)
and answer with preset replies. Monkey C, Connect IQ.

**Not a port of the Wear OS app.** Garmin doesn't run Android, so none of the
Kotlin/Compose code applies, and the platform genuinely can't do everything the
Wear OS app does. Honest list below.

## Where the data comes from

The watch talks **only to the Bubbles Android app over Bluetooth** — no server, no
internet, no credentials on the watch.

```
Garmin watch  ──Bluetooth (Connect IQ)──►  Bubbles Android app
   PhoneApi.mc                               GarminBridge.kt
                                                  ▲
                                                  │ snapshot (20 chats × 15 msgs)
                                             garmin_snapshot.dart
                                                  ▲
                                        SMS (SIM + sync server) + iMessage (BlueBubbles)
```

The phone app already merges both services, so this is the only path that gives
the watch iMessage at all. It also avoids the sync server's HTTP API, which the
watch can't use: Connect IQ fails near 32KB of JSON and needs more than double
that in memory to parse it.

Requests can arrive while the Flutter engine is asleep, so Kotlin answers from a
**pre-built snapshot** Dart hands over (first sync), refreshed as messages arrive
(then only what's new). Replies are sliced into small messages, because one
Bluetooth message carries only a couple of KB.

## What it does

- Inbox: 20 most recent conversations with contact names resolved by the phone,
  unread marked `•`.
- Thread: last 15 messages, oldest first, short timestamp, `→` on your own, MMS
  shown as `[foto]`.
- Reply: **Responder por iMessage** and/or **Responder por SMS**, whichever the
  thread supports, then pick a preset. The phone sends it over the SIM or
  BlueBubbles using its normal send path.
- One-way senders (OTP codes, banks) show "Não é possível responder", same rule as
  the phone, Mac and Wear OS apps.
- Small cache: last inbox and last thread persist, so the list appears instantly
  and stays readable when the phone is out of range.

## Platform limits (why features are missing)

| Wear OS app | Garmin | Why |
|---|---|---|
| Free-text replies (Gboard, voice) | Preset replies only | Connect IQ exposes **no keyboard and no dictation** to third-party apps. Garmin's own quick replies are system-level and off-limits to us. |
| Photos, avatars | `[foto]` marker | Image transfer is heavily constrained and there's no contacts access on-watch. |
| Full offline history | Last snapshot only | No SQLite; app storage is tiny. |
| Live push | Nudge + refresh | The phone signals "something arrived" and the watch re-asks; there's no socket, and background runs are short with little memory. |
| Works away from the phone | Needs the phone in Bluetooth range | The phone *is* the data source here. |
| Delete messages/chats | Not implemented | Could be added to the protocol later. |

## Setup

1. Build and side-load the watch app (below), and install the phone app built from
   this repo (it contains `GarminBridge.kt`).
2. Garmin Connect Mobile must be installed and paired — it carries the Bluetooth
   channel.
3. In **Garmin Connect Mobile ▸ Connect IQ ▸ Bubbles ▸ Settings**, edit **Resposta
   1…6**. Blank ones are skipped. Defaults: OK, Obrigado!, Estou a caminho, Ligo
   já, Não posso falar agora.
4. Open the phone app once, then open the watch app.

## Build

Needs the Connect IQ SDK and the VS Code Monkey C extension.

```bash
monkeyc -f monkey.jungle -d venu4 -o bin/Bubbles.prg -y <your-developer-key.der>
```

Then run in the simulator (`connectiq`, then `monkeydo bin/Bubbles.prg venu4`) or
copy the `.prg` to `GARMIN/APPS` over USB.

Check two things first:

- **Device id** — `venu4` is current at time of writing; if your SDK disagrees,
  adjust `-d` and `<iq:products>` in `manifest.xml`.
- **Developer key** — generate one in VS Code (*Connect IQ: Generate a Developer
  Key*) if you don't have a `.der`.

The app id in `manifest.xml` must stay in sync with `WATCH_APP_ID` in
`GarminBridge.kt` — that's how the phone addresses this app.

## Phone-side pieces

- `android/…/garmin/GarminBridge.kt` — Connect IQ Mobile SDK: registers for app
  events, answers `chats` / `msgs` / `send`, slices replies.
- `lib/services/backend/watch/garmin_snapshot.dart` — builds the snapshot, pushes
  it over a MethodChannel, and performs replies with the app's normal send path.
- Dependency: `com.garmin.connectiq:ciq-companion-app-sdk` (Maven Central).

## Not done yet

- Delete from the watch.
- Marking a thread read from the watch.
- Sending photos (no picker, and outbound MMS from a watch isn't worth the memory).
