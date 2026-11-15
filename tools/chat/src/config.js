import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC_DIR = path.dirname(fileURLToPath(import.meta.url));
export const CHAT_DIR = path.resolve(SRC_DIR, '..');

export const DEFAULTS = Object.freeze({
  repo: 'ggddbyfnjff/NEW-ONE',
  issue: 7,
  port: 3210,
  mention: '@ggddbyfnjff',
  pollMs: 4000,
  apiBase: 'https://api.github.com',
});

export class ConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigError';
  }
}

function positiveInteger(raw, name, fallback, max = Number.MAX_SAFE_INTEGER) {
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return fallback;
  }
  const value = Number(String(raw).trim());
  if (!Number.isInteger(value) || value <= 0 || value > max) {
    throw new ConfigError(`${name} 必须是 1 到 ${max} 之间的整数。`);
  }
  return value;
}

function normalizeRepo(raw) {
  const value = String(raw ?? '').trim() || DEFAULTS.repo;
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value)) {
    throw new ConfigError('CHAT_REPO 的格式应为 owner/repo，例如 ggddbyfnjff/NEW-ONE。');
  }
  return value;
}

function validateApiBase(raw) {
  const value = String(raw ?? '').trim() || DEFAULTS.apiBase;
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new ConfigError('CHAT_GITHUB_API 必须是有效的 http(s) 地址。');
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new ConfigError('CHAT_GITHUB_API 只支持 http 或 https。');
  }
  return value.replace(/\/+$/, '');
}

function loadToken(env) {
  const fromEnvironment = String(env.GITHUB_TOKEN || env.CHAT_GITHUB_TOKEN || '').trim();
  if (fromEnvironment) {
    return { token: fromEnvironment, tokenSource: '环境变量' };
  }

  const tokenFile = env.CHAT_TOKEN_FILE
    ? path.resolve(String(env.CHAT_TOKEN_FILE).trim())
    : path.join(CHAT_DIR, 'token.txt');

  let raw;
  try {
    raw = readFileSync(tokenFile, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') {
      throw new ConfigError(
        `未找到 GitHub 访问令牌。\n` +
        `请将令牌写入 ${tokenFile}（文件内仅放一行令牌），\n` +
        `或设置环境变量 GITHUB_TOKEN。\n` +
        `详细步骤见 ${path.join(CHAT_DIR, 'README.md')}。`
      );
    }
    throw new ConfigError(`无法读取令牌文件 ${tokenFile}：${error.message}`);
  }

  const token = raw.replace(/^\uFEFF/, '').trim();
  if (!token) {
    throw new ConfigError(`令牌文件 ${tokenFile} 是空的。`);
  }
  return { token, tokenSource: '令牌文件' };
}

/**
 * Read runtime settings from environment variables.
 * The returned object contains the secret token and must never be sent to a browser.
 */
export function loadConfig(env = process.env) {
  const { token, tokenSource } = loadToken(env);

  return {
    repo: normalizeRepo(env.CHAT_REPO),
    issue: positiveInteger(env.CHAT_ISSUE, 'CHAT_ISSUE', DEFAULTS.issue),
    port: positiveInteger(env.CHAT_PORT, 'CHAT_PORT', DEFAULTS.port, 65535),
    mention: String(env.CHAT_MENTION || DEFAULTS.mention).trim() || DEFAULTS.mention,
    pollMs: positiveInteger(env.CHAT_POLL_MS, 'CHAT_POLL_MS', DEFAULTS.pollMs, 300000),
    apiBase: validateApiBase(env.CHAT_GITHUB_API),
    token,
    tokenSource,
  };
}
