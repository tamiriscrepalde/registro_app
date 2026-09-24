// Integração com um PostgreSQL descartável: migrations, persistência e fluxo completo.
// Requer DATABASE_URL apontando para um banco de teste (no CI, o service container).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

assert.ok(process.env.DATABASE_URL, 'DATABASE_URL precisa apontar para um banco de teste');
process.env.JWT_SECRET = 'segredo-de-teste';

const app = require('../src/index');
const pool = require('../src/db');

const migrate = () =>
  execFileSync(process.execPath, [path.join(__dirname, '..', 'src', 'migrate.js')], { encoding: 'utf8' });

const email = `teste-${Date.now()}-${process.pid}@example.com`;
let base;
let server;

test.before(async () => {
  migrate();
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await pool.end();
});

const post = (p, body) =>
  fetch(`${base}${p}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('migrations são registradas e uma nova execução não reaplica nada', async () => {
  const { rows } = await pool.query('SELECT name FROM schema_migrations ORDER BY name');
  assert.ok(rows.some((r) => r.name === '001_init.sql'));
  const output = migrate();
  assert.doesNotMatch(output, /Aplicando/);
  const again = await pool.query('SELECT count(*)::int AS n FROM schema_migrations');
  assert.equal(again.rows[0].n, rows.length);
});

test('cadastro persiste o usuário com a senha em hash', async () => {
  const res = await post('/api/register', { name: '  Ana  ', email: email.toUpperCase(), password: 'segredo1' });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.equal(body.user.email, email);
  assert.equal(body.user.name, 'Ana');
  assert.ok(body.token);

  const { rows } = await pool.query('SELECT name, password_hash FROM users WHERE email = $1', [email]);
  assert.equal(rows.length, 1);
  assert.notEqual(rows[0].password_hash, 'segredo1');
  assert.match(rows[0].password_hash, /^\$2[aby]\$/);
});

test('cadastro com e-mail repetido retorna 409', async () => {
  const res = await post('/api/register', { name: 'Outra', email, password: 'segredo2' });
  assert.equal(res.status, 409);
  assert.equal((await res.json()).error, 'E-mail já cadastrado');
});

test('login com senha errada é recusado', async () => {
  const res = await post('/api/login', { email, password: 'errada' });
  assert.equal(res.status, 401);
});

test('login devolve token que consulta o usuário persistido', async () => {
  const res = await post('/api/login', { email: email.toUpperCase(), password: 'segredo1' });
  assert.equal(res.status, 200);
  const { token, user } = await res.json();
  assert.equal(user.password_hash, undefined);

  const me = await fetch(`${base}/api/me`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(me.status, 200);
  const body = await me.json();
  assert.equal(body.user.email, email);
  assert.equal(body.user.id, user.id);
});
