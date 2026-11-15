import assert from 'node:assert/strict';
import test from 'node:test';

import { GitHubClient } from '../src/github.js';
import { ChatSync } from '../src/sync.js';
import { MockGitHub } from '../test-support/mock-github.js';

const TOKEN = 'test-token';

async function setup(t, comments = []) {
  const mock = new MockGitHub({ token: TOKEN, comments });
  const base = await mock.start();
  t.after(() => mock.stop());

  const client = new GitHubClient({
    token: TOKEN,
    repo: mock.repo,
    issue: mock.issue,
    apiBase: base,
  });
  const sync = new ChatSync({ client, mention: '@ggddbyfnjff' });
  return { mock, client, sync };
}

test('ChatSync loads recent comments and classifies sender roles', async (t) => {
  const { sync } = await setup(t, [
    { author: 'sfdutfsaqutfd', body: '@ggddbyfnjff 你好' },
    { author: 'ggddbyfnjff', body: '你好，我在。' },
  ]);

  const snapshot = await sync.initialize();
  assert.equal(snapshot.messages.length, 2);
  assert.equal(snapshot.messages[0].role, 'me');
  assert.equal(snapshot.messages[0].text, '你好');
  assert.equal(snapshot.messages[1].role, 'you');
  assert.equal(snapshot.viewer, 'sfdutfsaqutfd');
  assert.equal(snapshot.issue, 7);
  assert.match(snapshot.issueUrl, /issues\/7$/);
});

test('ChatSync keeps the newest two pages when history is long', async (t) => {
  const comments = Array.from({ length: 250 }, (_, index) => ({
    author: index % 2 === 0 ? 'sfdutfsaqutfd' : 'ggddbyfnjff',
    body: `消息 ${index}`,
  }));
  const { sync } = await setup(t, comments);

  const snapshot = await sync.initialize();
  assert.equal(snapshot.messages.length, 150);
  assert.equal(snapshot.messages[0].id, '1100');
  assert.equal(snapshot.messages.at(-1).id, '1249');
});

test('ChatSync refresh picks up newly added comments', async (t) => {
  const { mock, sync } = await setup(t, [
    { author: 'ggddbyfnjff', body: '先说明一下。' },
  ]);
  await sync.initialize();

  mock.addComment({ author: 'ggddbyfnjff', body: '新的回复' });
  sync.lastRefreshAt = 0;

  const snapshot = await sync.refresh();
  assert.equal(snapshot.added, 1);
  assert.equal(snapshot.messages.length, 2);
  assert.equal(snapshot.messages.at(-1).text, '新的回复');
});

test('ChatSync sends the mention prefix and merges its own comment immediately', async (t) => {
  const { mock, sync } = await setup(t);
  await sync.initialize();

  const result = await sync.sendMessage('  测试发送  ');
  assert.equal(result.message.role, 'me');
  assert.equal(result.message.text, '测试发送');
  assert.equal(result.snapshot.messages.at(-1).text, '测试发送');

  const post = mock.requests.find((request) => request.method === 'POST');
  assert.equal(JSON.parse(post.body).body, '@ggddbyfnjff 测试发送');
});

test('ChatSync rejects empty and oversized messages', async (t) => {
  const { sync } = await setup(t);
  await sync.initialize();

  await assert.rejects(() => sync.sendMessage('   '), /不能为空/);
  await assert.rejects(() => sync.sendMessage('a'.repeat(8001)), /不能超过/);
});
