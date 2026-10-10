// Free replacement for the Cloud Function + Cloud KMS: releases a per-user 32-byte data key to a caller who
// presents a valid Firebase ID token. Stateless: key = HKDF-SHA256(MASTER_KEY, info = "face-dek|" + uid).
// Runs on Cloudflare Workers (free plan) and, unchanged, on Node 22 (that is how it is tested).

const CERTS_URL = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
const ENC = new TextEncoder();
const HKDF_SALT = ENC.encode('face-key-service-v1');
const CLOCK_SKEW_S = 300;

// ---------- small helpers ----------
const b64ToBytes = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const bytesToB64 = (b) => btoa(String.fromCharCode(...b));
const b64urlToBytes = (s) => b64ToBytes(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '='));
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });

// ---------- X.509 -> public key (Firebase publishes PEM certificates, not bare keys) ----------
function readTlv(buf, off) {
  const tag = buf[off];
  let len = buf[off + 1];
  let hdr = 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[off + 2 + i];
    hdr = 2 + n;
  }
  return { tag, start: off, hdr, end: off + hdr + len };
}
function children(buf, tlv) {
  const out = [];
  for (let o = tlv.start + tlv.hdr; o < tlv.end; ) {
    const c = readTlv(buf, o);
    out.push(c);
    o = c.end;
  }
  return out;
}
/** Returns the DER of the certificate's SubjectPublicKeyInfo. */
export function spkiFromCertPem(pem) {
  const der = b64ToBytes(pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, '').replace(/\s+/g, ''));
  const cert = readTlv(der, 0);
  const tbs = children(der, cert)[0];
  const fields = children(der, tbs);
  const base = fields[0].tag === 0xa0 ? 1 : 0; // optional [0] version
  // serial, signatureAlg, issuer, validity, subject, subjectPublicKeyInfo
  const spki = fields[base + 5];
  return der.slice(spki.start, spki.end);
}

// ---------- Firebase ID token verification ----------
let certCache = { keys: null, expires: 0 };

async function loadKeys(fetchImpl, nowS, force) {
  if (!force && certCache.keys && nowS < certCache.expires) return certCache.keys;
  const res = await fetchImpl(CERTS_URL);
  if (!res.ok) throw new Error('cert fetch failed');
  const certs = await res.json();
  const keys = {};
  for (const [kid, pem] of Object.entries(certs)) {
    keys[kid] = await crypto.subtle.importKey(
      'spki', spkiFromCertPem(pem), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  }
  const m = /max-age=(\d+)/.exec(res.headers.get('cache-control') || '');
  certCache = { keys, expires: nowS + Math.max(60, m ? Number(m[1]) : 3600) };
  return keys;
}

/** Throws unless [token] is a currently valid ID token for [projectId]; returns the user id. */
export async function verifyFirebaseIdToken(token, { projectId, fetchImpl = fetch, nowS }) {
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('malformed');
  const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
  const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  if (header.alg !== 'RS256' || typeof header.kid !== 'string') throw new Error('bad header');

  let keys = await loadKeys(fetchImpl, nowS, false);
  if (!keys[header.kid]) keys = await loadKeys(fetchImpl, nowS, true); // key rotation: refresh once
  const key = keys[header.kid];
  if (!key) throw new Error('unknown kid');
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5', key, b64urlToBytes(parts[2]), ENC.encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new Error('bad signature');

  if (payload.aud !== projectId) throw new Error('bad aud');
  if (payload.iss !== `https://securetoken.google.com/${projectId}`) throw new Error('bad iss');
  if (!(payload.exp > nowS)) throw new Error('expired');
  if (!(payload.iat <= nowS + CLOCK_SKEW_S)) throw new Error('iat in future');
  if (payload.auth_time !== undefined && !(payload.auth_time <= nowS + CLOCK_SKEW_S)) throw new Error('auth_time in future');
  if (typeof payload.sub !== 'string' || payload.sub.length === 0 || payload.sub.length > 128) throw new Error('bad sub');
  return payload.sub;
}

// ---------- key derivation ----------
export async function deriveDek(masterB64, uid) {
  const master = b64ToBytes(masterB64);
  if (master.length < 32) throw new Error('MASTER_KEY must be at least 32 bytes');
  const ikm = await crypto.subtle.importKey('raw', master, 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: HKDF_SALT, info: ENC.encode(`face-dek|${uid}`) }, ikm, 256);
  return new Uint8Array(bits);
}

// ---------- HTTP entry ----------
export async function handle(request, env, { fetchImpl = fetch, nowS = Math.floor(Date.now() / 1000) } = {}) {
  const url = new URL(request.url);
  if (url.pathname === '/health') return json({ ok: true });
  if (url.pathname !== '/key' || request.method !== 'POST') return json({ error: 'not found' }, 404);
  if (!env.MASTER_KEY || !env.FIREBASE_PROJECT_ID) return json({ error: 'server not configured' }, 500);

  const m = /^Bearer (.+)$/.exec(request.headers.get('Authorization') || '');
  if (!m) return json({ error: 'unauthorized' }, 401);
  let uid;
  try {
    uid = await verifyFirebaseIdToken(m[1], { projectId: env.FIREBASE_PROJECT_ID, fetchImpl, nowS });
  } catch {
    return json({ error: 'unauthorized' }, 401); // never say WHY (no oracle for attackers)
  }
  try {
    return json({ key: bytesToB64(await deriveDek(env.MASTER_KEY, uid)) });
  } catch {
    return json({ error: 'server not configured' }, 500);
  }
}

export function _resetCertCacheForTests() {
  certCache = { keys: null, expires: 0 };
}

export default { fetch: (request, env) => handle(request, env) };
