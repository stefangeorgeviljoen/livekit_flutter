# Token Server (Node.js)

Tiny HTTP service that mints LiveKit access tokens for the Flutter app.
Deploy this anywhere that can run Node 18+ (Vercel, Cloudflare Worker with the
`livekit-server-sdk` package, Cloud Run, Fly, a VPS, etc.).

**Why this is its own service:** the LiveKit API secret must NEVER ship inside
the mobile/desktop client. It signs JWTs that grant publish/subscribe rights to
a room, and anyone with the secret can mint admin tokens.

## Run locally

```bash
cd token-server
cp .env.example .env
# edit .env and set the three TODO values
npm install
npm start
```

Then in the Flutter app's Settings screen, set
`Token endpoint URL = http://YOUR-LAN-IP:8787/token`.

## Endpoint

`POST /token`
```json
{
  "room": "remote-desk",
  "identity": "user-abc",
  "role": "host" | "controller",
  "code": "123456"
}
```

Returns: `{ "token": "<jwt>" }`

## Pairing model

The first request (host or controller) for a given room records the supplied
`code`. Any subsequent request with a different `code` is rejected. The record
expires after 10 minutes. This is intentionally simple — replace with a proper
DB / Redis if you need multi-instance deployments.

## TODO before deploying

- Set `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` in `.env`.
- Lock down CORS / origin in `server.js` if exposing publicly.
- Add rate limiting and authentication (e.g. signed device attestation).
