import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { ConfigError, DEFAULTS, loadConfig } from '../src/config.js';

test('loadConfig applies defaults and environment overrides', () => {
  const config = loadConfig({
    GITHUB_TOKEN: 'test-token',
    CHAT_ISSUE: '12',
    CHAT_PORT: '4000',
    CHAT_POLL_MS: '2000',
  });

  assert.equal(config.token, 'test-token');
  assert.equal(config.repo, DEFAULTS.repo);
  assert.equal(config.issue, 12);
  assert.equal(config.port, 4000);
  assert.equal(config.pollMs, 2000);
  assert.equal(config.apiBase, 'https://api.github.com');
  assert.equal(config.mention, '@ggddbyfnjff');
});

test('loadConfig reads a trimmed token from a file', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chat-config-'));
  const tokenFile = path.join(directory, 'token.txt');
  writeFileSync(tokenFile, '\uFEFFsecret-from-file\n', 'utf8');

  try {
    const config = loadConfig({ CHAT_TOKEN_FILE: tokenFile });
    assert.equal(config.token, 'secret-from-file');
    assert.equal(config.tokenSource, '令牌文件');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('loadConfig reports missing tokens without printing a token', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chat-config-'));
  try {
    assert.throws(
      () => loadConfig({ CHAT_TOKEN_FILE: path.join(directory, 'missing.txt') }),
      (error) => {
        assert.ok(error instanceof ConfigError);
        assert.match(error.message, /未找到 GitHub 访问令牌/);
        return true;
      }
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('loadConfig rejects invalid values', () => {
  assert.throws(() => loadConfig({ GITHUB_TOKEN: 't', CHAT_ISSUE: '0' }), ConfigError);
  assert.throws(() => loadConfig({ GITHUB_TOKEN: 't', CHAT_PORT: 'abc' }), ConfigError);
  assert.throws(() => loadConfig({ GITHUB_TOKEN: 't', CHAT_REPO: 'not-a-repo' }), ConfigError);
  assert.throws(() => loadConfig({ GITHUB_TOKEN: 't', CHAT_GITHUB_API: 'ftp://x' }), ConfigError);
});
