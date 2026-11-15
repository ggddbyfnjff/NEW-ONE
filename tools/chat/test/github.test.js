import assert from 'node:assert/strict';
import test from 'node:test';

import {
  displayText,
  GitHubClient,
  GitHubError,
  lastPageFromLinkHeader,
  normalizeComment,
  parseLinkHeader,
} from '../src/github.js';
import { MockGitHub } from '../test-support/mock-github.js';

const TOKEN = 'test-token';

test('parseLinkHeader reads rel targets', () => {
  const links = parseLinkHeader(
    '<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=9>; rel="last"'
  );
  assert.equal(links.next, 'https://api.github.com/x?page=2');
  assert.equal(links.last, 'https://api.github.com/x?page=9');
  assert.equal(lastPageFromLinkHeader('<https://api.github.com/x?page=9>; rel="last"'), 9);
});

test('displayText removes only the viewer mention and the super-agent marker', () => {
  assert.equal(
    displayText('@ggddbyfnjff 你好，世界', { isMe: true, mention: '@ggddbyfnjff' }),
    '你好，世界'
  );
  assert.equal(
    displayText('@ggddbyfnjff 你好', { isMe: false, mention: '@ggddbyfnjff' }),
    '@ggddbyfnjff 你好'
  );
  assert.equal(
    displayText('收到。\n\n<!-- dsh-superagent:abc123 -->', { isMe: false, mention: '@ggddbyfnjff' }),
    '收到。'
  );
});

test('normalizeComment marks the token owner as me and keeps other authors as you', () => {
  const raw = {
    id: 12,
    body: '@ggddbyfnjff 第一条',
    created_at: '2026-11-15T11:00:00Z',
    updated_at: '2026-11-15T11:00:00Z',
    html_url: 'https://github.com/ggddbyfnjff/NEW-ONE/issues/7#issuecomment-12',
    user: { login: 'sfdutfsaqutfd' },
  };

  const mine = normalizeComment(raw, { viewerLogin: 'sfdutfsaqutfd', mention: '@ggddbyfnjff' });
  assert.equal(mine.isMe, true);
  assert.equal(mine.role, 'me');
  assert.equal(mine.text, '第一条');
  assert.equal(mine.id, '12');

  const peer = normalizeComment(
    { ...raw, id: 13, user: { login: 'ggddbyfnjff' }, body: '回复' },
    { viewerLogin: 'sfdutfsaqutfd', mention: '@ggddbyfnjff' }
  );
  assert.equal(peer.isMe, false);
  assert.equal(peer.role, 'you');
  assert.equal(peer.text, '回复');
});

test('GitHubClient authenticates, posts the exact mention prefix and reports status', async (t) => {
  const mock = new MockGitHub({ token: TOKEN });
  const base = await mock.start();
  t.after(() => mock.stop());

  const client = new GitHubClient({
    token: TOKEN,
    repo: mock.repo,
    issue: mock.issue,
    apiBase: base,
  });

  const viewer = await client.getViewer();
  assert.equal(viewer.login, 'sfdutfsaqutfd');

  const created = await client.createComment('@ggddbyfnjff 测试消息');
  assert.equal(created.body, '@ggddbyfnjff 测试消息');

  const post = mock.requests.find((request) => request.method === 'POST');
  assert.equal(post.headers.authorization, `Bearer ${TOKEN}`);
  assert.equal(post.headers['x-github-api-version'], '2022-11-28');
  assert.equal(JSON.parse(post.body).body, '@ggddbyfnjff 测试消息');

  const comments = await client.listComments();
  assert.equal(comments.comments.length, 1);
});

test('GitHubClient turns an invalid token into a token-free error', async (t) => {
  const mock = new MockGitHub({ token: TOKEN });
  const base = await mock.start();
  t.after(() => mock.stop());

  const client = new GitHubClient({
    token: 'wrong-token',
    repo: mock.repo,
    issue: mock.issue,
    apiBase: base,
  });

  await assert.rejects(() => client.getViewer(), (error) => {
    assert.ok(error instanceof GitHubError);
    assert.equal(error.status, 401);
    assert.equal(error.message.includes('wrong-token'), false);
    return true;
  });
});
