// Comportamentos da API que não dependem do banco: validação, autenticação e CORS.
const test = require('node:test');
const assert = require('node:assert/strict');

const SITE = 'http://site.example';
process.env.JWT_SECRET = 'segredo-de-teste';
process.env.CORS_ORIGIN = SITE;
process.env.APP_VERSION = 'abc123';

const app = require('../src/index');
const pool = require('../src/db');

let base;
let server;

test.before(async () => {
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await pool.end();
});

const post = (path, body, headers = {}) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });

test('health informa a versão publicada', async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, version: 'abc123' });
});

test('cadastro exige nome, e-mail e senha', async () => {
  const res = await post('/api/register', { email: 'a@b.com', password: '123456' });
  assert.equal(res.status, 400);
  assert.match((await res.json()).error, /obrigatórios/);
});

test('cadastro rejeita e-mail inválido', async () => {
  const res = await post('/api/register', { name: 'A', email: 'sem-arroba', password: '123456' });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).error, 'E-mail inválido');
});

test('cadastro rejeita senha curta', async () => {
  const res = await post('/api/register', { name: 'A', email: 'a@b.com', password: '123' });
  assert.equal(res.status, 400);
  assert.match((await res.json()).error, /6 caracteres/);
});

test('login exige e-mail e senha', async () => {
  const res = await post('/api/login', { email: 'a@b.com' });
  assert.equal(res.status, 400);
});

test('/api/me recusa requisição sem token', async () => {
  const res = await fetch(`${base}/api/me`);
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error, 'Token ausente');
});

test('/api/me recusa token assinado com outro segredo', async () => {
  const jwt = require('jsonwebtoken');
  const forged = jwt.sign({ sub: 1, email: 'a@b.com' }, 'outro-segredo');
  const res = await fetch(`${base}/api/me`, { headers: { Authorization: `Bearer ${forged}` } });
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error, 'Token inválido ou expirado');
});

test('preflight CORS libera a origem do site com os cabeçalhos usados pelo front', async () => {
  const res = await fetch(`${base}/api/register`, {
    method: 'OPTIONS',
    headers: {
      Origin: SITE,
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'content-type,authorization',
    },
  });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), SITE);
  assert.match(res.headers.get('access-control-allow-headers'), /Authorization/);
  assert.match(res.headers.get('access-control-allow-methods'), /POST/);
});

test('respostas para a origem do site trazem o cabeçalho CORS', async () => {
  const res = await fetch(`${base}/api/health`, { headers: { Origin: SITE } });
  assert.equal(res.headers.get('access-control-allow-origin'), SITE);
});

test('outras origens não recebem cabeçalho CORS', async () => {
  const res = await fetch(`${base}/api/health`, { headers: { Origin: 'http://intruso.example' } });
  assert.equal(res.headers.get('access-control-allow-origin'), null);
});
