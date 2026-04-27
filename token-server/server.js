import 'dotenv/config';
import { createServer } from 'node:http';
import { AccessToken } from 'livekit-server-sdk';

const {
  LIVEKIT_URL,
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
  PORT = '8787',
  CORS_ORIGIN = '*',
} = process.env;

if (!LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
  console.error(
    'Missing LIVEKIT_API_KEY / LIVEKIT_API_SECRET. Copy .env.example to .env.'
  );
  process.exit(1);
}

// Pairing-code registry: room -> { code, expiresAt }
const pairings = new Map();
const PAIRING_TTL_MS = 10 * 60 * 1000;

function checkPairing(room, code) {
  const now = Date.now();
  const existing = pairings.get(room);
  if (existing && existing.expiresAt > now) {
    if (existing.code !== code) return false;
    return true;
  }
  pairings.set(room, { code, expiresAt: now + PAIRING_TTL_MS });
  return true;
}

function applyCors(res) {
  res.setHeader('Access-Control-Allow-Origin', CORS_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'content-type');
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  applyCors(res);
  if (req.method === 'OPTIONS') {
    res.writeHead(204).end();
    return;
  }
  if (req.method !== 'POST' || req.url !== '/token') {
    res.writeHead(404).end();
    return;
  }
  try {
    const { room, identity, role, code } = await readJson(req);
    if (!room || !identity || !role || !code) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'room, identity, role, code required' }));
      return;
    }
    if (!/^\d{6}$/.test(code)) {
      res.writeHead(400).end(JSON.stringify({ error: 'invalid code' }));
      return;
    }
    if (!checkPairing(room, code)) {
      res.writeHead(403).end(JSON.stringify({ error: 'pairing code mismatch' }));
      return;
    }

    const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity,
      ttl: '10m',
    });
    at.addGrant({
      roomJoin: true,
      room,
      // Both roles need data publishing; only host needs to publish video.
      canPublish: role === 'host',
      canSubscribe: true,
      canPublishData: true,
    });
    const token = await at.toJwt();
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ token, url: LIVEKIT_URL }));
  } catch (e) {
    console.error(e);
    res.writeHead(500).end(JSON.stringify({ error: String(e) }));
  }
});

server.listen(Number(PORT), () => {
  console.log(`Token server listening on :${PORT}`);
});
