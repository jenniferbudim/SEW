import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { handle, deriveDek, spkiFromCertPem, _resetCertCacheForTests } from '../src/index.mjs';

const PROJECT = 'demo-project';
const MASTER = Buffer.alloc(32, 7).toString('base64');
const ENV = { MASTER_KEY: MASTER, FIREBASE_PROJECT_ID: PROJECT };
const NOW = 1_800_000_000;

// A REAL self-signed X.509 certificate (made with OpenSSL), like the ones Firebase publishes.
function makeCert(cn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cert-'));
  const r = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', `${dir}/k.pem`,
    '-out', `${dir}/c.pem`, '-subj', `/CN=${cn}`, '-days', '2'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('openssl failed: ' + r.stderr);
  return { cert: fs.readFileSync(`${dir}/c.pem`, 'utf8'), priv: fs.readFileSync(`${dir}/k.pem`, 'utf8') };
}
const A = makeCert('a'), B = makeCert('b');

const b64u = (b) => Buffer.from(b).toString('base64url');
function token({ kid = 'kidA', priv = A.priv, alg = 'RS256', claims = {}, header = {} } = {}) {
  const h = b64u(JSON.stringify({ alg, kid, typ: 'JWT', ...header }));
  const p = b64u(JSON.stringify({
    aud: PROJECT, iss: `https://securetoken.google.com/${PROJECT}`, sub: 'uid-123',
    iat: NOW - 10, auth_time: NOW - 10, exp: NOW + 3000, ...claims }));
  const sig = alg === 'RS256' ? crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), priv) : Buffer.from('x');
  return `${h}.${p}.${b64u(sig)}`;
}
function certsFetch(map, counter = { n: 0 }) {
  return async () => { counter.n++; return new Response(JSON.stringify(map), { headers: { 'cache-control': 'max-age=3600' } }); };
}
const call = (tok, { env = ENV, map = { kidA: A.cert }, counter, method = 'POST', path: p = '/key' } = {}) => {
  const headers = tok ? { Authorization: `Bearer ${tok}` } : {};
  return handle(new Request(`https://x.test${p}`, { method, headers }), env,
    { fetchImpl: certsFetch(map, counter), nowS: NOW });
};
test.beforeEach(() => _resetCertCacheForTests());

test('parses the public key out of a real X.509 certificate', async () => {
  const spki = spkiFromCertPem(A.cert);
  const expected = crypto.createPublicKey(A.cert).export({ type: 'spki', format: 'der' });
  assert.deepEqual(Buffer.from(spki), expected);
});

test('valid token -> 32-byte key, stable per user, different per user and per master key', async () => {
  const r1 = await call(token());
  assert.equal(r1.status, 200);
  const k1 = (await r1.json()).key;
  assert.equal(Buffer.from(k1, 'base64').length, 32);
  assert.equal((await (await call(token())).json()).key, k1);
  assert.notEqual((await (await call(token({ claims: { sub: 'uid-999' } }))).json()).key, k1);
  const other = { ...ENV, MASTER_KEY: Buffer.alloc(32, 8).toString('base64') };
  assert.notEqual((await (await call(token(), { env: other })).json()).key, k1);
  assert.equal(r1.headers.get('cache-control'), 'no-store');
});

test('rejects: missing header, wrong method/path', async () => {
  assert.equal((await call(null)).status, 401);
  assert.equal((await call(token(), { method: 'GET' })).status, 404);
  assert.equal((await call(token(), { path: '/other' })).status, 404);
});

const bad = {
  'expired token': () => token({ claims: { exp: NOW - 1 } }),
  'wrong audience': () => token({ claims: { aud: 'other-project' } }),
  'wrong issuer': () => token({ claims: { iss: 'https://securetoken.google.com/other' } }),
  'issued in the future': () => token({ claims: { iat: NOW + 3600 } }),
  'empty subject': () => token({ claims: { sub: '' } }),
  'signed by a different key': () => token({ priv: B.priv }),
  'alg none / HS256': () => token({ alg: 'HS256' }),
  'unknown kid': () => token({ kid: 'nope' }),
  'garbage': () => 'not.a.jwt',
};
for (const [name, mk] of Object.entries(bad)) {
  test(`rejects ${name} with a bare 401`, async () => {
    const r = await call(mk());
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: 'unauthorized' });
  });
}

test('tampered payload (uid swapped, signature kept) is rejected', async () => {
  const [h, , s] = token().split('.');
  const p = b64u(JSON.stringify({ aud: PROJECT, iss: `https://securetoken.google.com/${PROJECT}`,
    sub: 'victim', iat: NOW - 10, exp: NOW + 3000 }));
  assert.equal((await call(`${h}.${p}.${s}`)).status, 401);
});

test('key rotation: an unknown kid triggers one refetch and then works', async () => {
  const counter = { n: 0 };
  await call(token(), { counter });                                  // primes cache with kidA only
  const r = await call(token({ kid: 'kidB', priv: B.priv }), { map: { kidA: A.cert, kidB: B.cert }, counter });
  assert.equal(r.status, 200);
  assert.equal(counter.n, 2);                                        // 1 fetch to prime + exactly 1 refetch for the new kid
});

test('certificates are cached (one fetch for many requests)', async () => {
  const counter = { n: 0 };
  for (let i = 0; i < 5; i++) await call(token(), { counter });
  assert.equal(counter.n, 1);
});

test('missing / short MASTER_KEY is a 500, never a weak key', async () => {
  assert.equal((await call(token(), { env: { FIREBASE_PROJECT_ID: PROJECT } })).status, 500);
  assert.equal((await call(token(), { env: { ...ENV, MASTER_KEY: Buffer.alloc(8).toString('base64') } })).status, 500);
  await assert.rejects(deriveDek(Buffer.alloc(8).toString('base64'), 'u'));
});
