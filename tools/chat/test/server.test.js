import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { GitHubClient } from '../src/github.js';
import { createChatServer } from '../src/server.js';
import { ChatSync } from '../src/sync.js';
import { MockGitHub } from '../test-support/mock-github.js';

const TOKEN = 'test-token';
const PUBLIC_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');

function rawRequest(url, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const request = http.request({
      hostname: parsed.hostname,
      port: parsed.port,
      path: `${parsed.pathname}${parsed.search}`,
      method,
      headers,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        text: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    request.on('error', reject);
    if (body !== undefined) request.write(body);
    request.end();
  });
}

async function setupApp(t, comments = []) {
  const mock = new MockGitHub({ token: TOKEN, comments });
  const apiBase = await mock.start();
  const client = new GitHubClient({
    token: TOKEN,
    repo: mock.repo,
    issue: mock.issue,
    apiBase,
  });
  const sync = new ChatSync({ client, mention: '@ggddbyfnjff' });
  await sync.initialize();

  const logs = [];
  const logger = {
    error: (...args) => logs.push(args.join(' ')),
    log: () => {},
  };
  const server = createChatServer({ sync, publicDir: PUBLIC_DIR, logger });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  t.after(async () => {
    await new Promise((resolve) => server.close(resolve));
    await mock.stop();
  });

  return { mock, sync, server, baseUrl, logs };
}

test('serves the chat page with a strict CSP and without a token', async (t) => {
  const { baseUrl } = await setupApp(t);
  const response = await fetch(`${baseUrl}/`);
  const html = await response.text();

  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/html/);
  assert.match(response.headers.get('content-security-policy'), /default-src 'self'/);
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.match(html, /本地聊天/);
  assert.equal(html.includes(TOKEN), false);
});

test('GET /api/messages returns both sides with roles and cleaned text', async (t) => {
  const { baseUrl } = await setupApp(t, [
    { author: 'sfdutfsaqutfd', body: '@ggddbyfnjff 你好' },
    { author: 'ggddbyfnjff', body: '收到。\n<!-- dsh-superagent:abc -->' },
  ]);

  const response = await fetch(`${baseUrl}/api/messages`);
  const data = await response.json();

  assert.equal(response.status, 200);
  assert.equal(data.viewer, 'sfdutfsaqutfd');
  assert.equal(data.messages.length, 2);
  assert.equal(data.messages[0].role, 'me');
  assert.equal(data.messages[0].text, '你好');
  assert.equal(data.messages[1].role, 'you');
  assert.equal(data.messages[1].text, '收到。');
  assert.equal(JSON.stringify(data).includes(TOKEN), false);
});

test('POST /api/messages posts the exact mention-prefixed comment', async (t) => {
  const { mock, baseUrl } = await setupApp(t);

  const response = await fetch(`${baseUrl}/api/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: '你好，测试一下' }),
  });
  const data = await response.json();

  assert.equal(response.status, 201);
  assert.equal(data.message.text, '你好，测试一下');
  assert.equal(data.message.isMe, true);

  const post = mock.requests.find((request) => request.method === 'POST');
  assert.equal(JSON.parse(post.body).body, '@ggddbyfnjff 你好，测试一下');

  const after = await (await fetch(`${baseUrl}/api/messages`)).json();
  assert.equal(after.messages.at(-1).text, '你好，测试一下');
});

test('rejects cross-origin and rebinding-style requests', async (t) => {
  const { mock, baseUrl } = await setupApp(t);
  const payload = JSON.stringify({ text: '不应发出' });

  const crossOrigin = await rawRequest(`${baseUrl}/api/messages`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Origin: 'http://evil.example',
    },
    body: payload,
  });
  assert.equal(crossOrigin.status, 403);
  assert.equal(mock.requests.some((request) => request.method === 'POST'), false);

  const rebinding = await rawRequest(`${baseUrl}/api/messages`, {
    headers: { Host: 'evil.example' },
  });
  assert.equal(rebinding.status, 403);
});

test('rejects non-JSON, empty and oversized messages without calling GitHub', async (t) => {
  const { mock, baseUrl } = await setupApp(t);

  const wrongType = await rawRequest(`${baseUrl}/api/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: JSON.stringify({ text: 'hello' }),
  });
  assert.equal(wrongType.status, 415);

  const empty = await rawRequest(`${baseUrl}/api/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: '   ' }),
  });
  assert.equal(empty.status, 400);

  const oversized = await rawRequest(`${baseUrl}/api/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: 'a'.repeat(8001) }),
  });
  assert.equal(oversized.status, 400);

  assert.equal(mock.requests.some((request) => request.method === 'POST'), false);
});

test('GitHub failures are reported and the token never appears in logs or responses', async (t) => {
  const { mock, baseUrl, logs } = await setupApp(t);
  mock.rejectPost = true;

  const response = await fetch(`${baseUrl}/api/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: '会失败' }),
  });
  const text = await response.text();

  assert.equal(response.status, 502);
  assert.equal(text.includes(TOKEN), false);
  assert.equal(logs.join('\n').includes(TOKEN), false);
});
