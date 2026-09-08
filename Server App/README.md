# SMS Sync Server

Self-hosted SMS/MMS sync relay for the Mac mini. Android agents ingest messages;
Mac/iPad clients read history and request outbound sends. SQLite is local; nothing
goes to the cloud. See `../SMS-Sync-Platform-v3-Architecture.md` for the full design.

## Run

```bash
cd "Server App"
cp .env.example .env          # set REGISTRATION_SECRET to a long random string
npm install
npm run dev                    # http://localhost:8787
```

Smoke-test it (server running in another terminal):

```bash
npm run harness                # registers phones, dedups, elects primary, dispatches a send
```

## Deploying a change to the Mac mini

The server runs under launchd (see `deploy/`). To pick up new code:

```bash
cd "Server App" && git pull && npm install && npm run redeploy
```

`redeploy` compiles and then restarts the running service in place with
`launchctl kickstart -k`. The LaunchAgent stays loaded and `RunAtLoad` stays
set, so the server still comes back on its own at login. Use `npm install`
only when dependencies changed; `npm run redeploy` alone is enough otherwise.

Watch it come up:

```bash
tail -f ~/Library/Logs/tnsms-server.log
```

## Upgrading an existing single-user install

Each person now gets their own database, and the old `data/sms.sqlite` is adopted
into one account on first start. That move is a rename, not a copy, so back the
directory up before starting, and set `OWNER_EMAIL` in `.env` first. It is read
once and never again.

```bash
cp -R data "data.backup-$(date +%F)"
git pull
npm install                    # better-sqlite3 is native; rebuilds if node moved
npm run build
launchctl kickstart -k "gui/$(id -u)/com.tnsms.server"
tail -f ~/Library/Logs/tnsms-server.log
```

The log names the account and the number of device tokens carried over. Phones
and Macs already paired keep working: their tokens are re-indexed, not reissued.

Isolation between accounts has its own check. Point it at a throwaway data dir,
never the live one:

```bash
DATA_DIR=/tmp/tn-test REGISTRATION_SECRET=test PORT=8799 npm start &
./scripts/smoke-multiuser.sh
```

## Canonical addresses (one-time re-key)

A number is now keyed in one form only: full international, digits and a leading
`+`. Before this, the conversation id and the content hash were built from the
address exactly as it arrived, so texting `916309003` and getting the reply back
as `+351916309003` produced two threads and two hashes for the same message. The
hash is how devices agree on identity, so a delete on the Mac could not be
matched on the phone.

National numbers are resolved with the calling code of the account's own
verified number. Short codes, alphanumeric senders (`MIN.SAUDE`) and emails are
never given one.

Existing rows need re-keying once. Stop the server first, and back up the data
directory: the script rewrites the message table and removes rows that turn out
to be the same message stored twice.

```bash
npm stop 2>/dev/null; launchctl kill TERM "gui/$(id -u)/com.tnsms.server"
cp -R data "data.backup-$(date +%F)"
npm run canonicalise              # dry run: reports what would change
npm run canonicalise -- --apply
launchctl kickstart -k "gui/$(id -u)/com.tnsms.server"
```

Update the Mac app and the Android app before letting them sync afterwards. A
client on an older build computes the previous hash, which is the same mismatch
in reverse.

## API

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET  | `/health` | — | liveness + current primary device |
| POST | `/devices/register` | registration secret | issue `{id, token}` for a device |
| POST | `/devices/heartbeat` | bearer | report `{simPresent, simKey}`; re-elects primary |
| POST | `/ingest` | bearer | batch upsert messages (deduped by content hash) |
| GET  | `/delta?since=<cursor>` | bearer | messages changed since cursor |
| POST | `/send` | bearer | enqueue outbound; dispatched to primary over WS |
| WS   | `/stream?token=<token>` | token | realtime: `message`, `primary_changed`, `send`, `send_status` |

## Expose to phones (Cloudflare Tunnel)

Dynamic home IP, no open ports:

```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create sms-sync
# route a hostname you control, then run:
cloudflared tunnel --url http://localhost:8787 run sms-sync
```

Point the Android agent's server URL at the resulting `https://<hostname>`. The
server still enforces per-device bearer tokens, so the tunnel is not an open door.

## Notes

- `better-sqlite3` is a native module; `npm install` compiles it (needs Xcode CLT).
- Media handling (MMS parts on disk) and `/delta` hard-delete mirroring are stubbed
  for the next pass — schema is already in place.
