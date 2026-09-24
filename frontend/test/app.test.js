// Executa o app.js real sobre o index.html real (jsdom), com a API simulada.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(root, 'app.js'), 'utf8');

const USER = { id: 7, name: 'Ana', email: 'ana@example.com', created_at: '2026-09-24T12:00:00Z' };

function load({ config, token, route }) {
  const { window } = new JSDOM(html, { url: 'http://site.example/', runScripts: 'outside-only' });
  const calls = [];
  window.fetch = async (url, options = {}) => {
    calls.push({ url, options });
    const { status, body } = route(url, options);
    return { ok: status < 400, status, json: async () => body };
  };
  if (config) window.APP_CONFIG = config;
  if (token) window.localStorage.setItem('token', token);
  window.eval(appJs);
  return { window, $: (sel) => window.document.querySelector(sel), calls };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function submit(window, form, values) {
  for (const [name, value] of Object.entries(values)) form.elements[name].value = value;
  form.dispatchEvent(new window.Event('submit', { bubbles: true, cancelable: true }));
}

test('cadastro chama a API configurada, guarda o token e mostra o perfil', async () => {
  const { window, $, calls } = load({
    config: { apiUrl: 'http://203.0.113.10:3000', version: 'abc1234' },
    route: () => ({ status: 201, body: { user: USER, token: 'tok-1' } }),
  });

  submit(window, $('#register-form'), { name: 'Ana', email: 'ana@example.com', password: 'segredo1' });
  await flush();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://203.0.113.10:3000/api/register');
  assert.equal(calls[0].options.method, 'POST');
  assert.deepEqual(JSON.parse(calls[0].options.body), { name: 'Ana', email: 'ana@example.com', password: 'segredo1' });
  assert.equal(window.localStorage.getItem('token'), 'tok-1');
  assert.equal($('#profile-name').textContent, 'Ana');
  assert.ok($('#auth-view').classList.contains('hidden'));
  assert.ok(!$('#profile-view').classList.contains('hidden'));
});

test('sem configuração usa caminho relativo (proxy local) e versão local', async () => {
  const { window, $, calls } = load({ route: () => ({ status: 200, body: { user: USER, token: 'tok-2' } }) });

  submit(window, $('#login-form'), { email: 'ana@example.com', password: 'segredo1' });
  await flush();

  assert.equal(calls[0].url, '/api/login');
  assert.equal($('#app-version').textContent, 'local');
});

test('mostra a versão publicada', () => {
  const { $ } = load({ config: { apiUrl: 'http://x', version: 'abc1234' }, route: () => ({ status: 200, body: {} }) });
  assert.equal($('#app-version').textContent, 'abc1234');
});

test('erro de login mostra a mensagem da API e não guarda token', async () => {
  const { window, $ } = load({ route: () => ({ status: 401, body: { error: 'Credenciais inválidas' } }) });

  submit(window, $('#login-form'), { email: 'ana@example.com', password: 'errada' });
  await flush();

  assert.equal($('#message').textContent, 'Credenciais inválidas');
  assert.equal(window.localStorage.getItem('token'), null);
  assert.ok($('#profile-view').classList.contains('hidden'));
});

test('restaura a sessão enviando o token salvo para /api/me', async () => {
  const { $, calls } = load({
    config: { apiUrl: 'http://203.0.113.10:3000' },
    token: 'tok-salvo',
    route: () => ({ status: 200, body: { user: USER } }),
  });
  await flush();

  assert.equal(calls[0].url, 'http://203.0.113.10:3000/api/me');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer tok-salvo');
  assert.equal($('#profile-email').textContent, 'ana@example.com');
});

test('token recusado na restauração é descartado', async () => {
  const { window } = load({ token: 'expirado', route: () => ({ status: 401, body: { error: 'Token inválido' } }) });
  await flush();

  assert.equal(window.localStorage.getItem('token'), null);
});

test('sair remove o token e volta para o login', async () => {
  const { window, $ } = load({ token: 'tok', route: () => ({ status: 200, body: { user: USER } }) });
  await flush();

  $('#logout').click();

  assert.equal(window.localStorage.getItem('token'), null);
  assert.ok(!$('#auth-view').classList.contains('hidden'));
  assert.ok($('#profile-view').classList.contains('hidden'));
});
