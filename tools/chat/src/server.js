import { readFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';

import {
  describeGitHubError,
  GitHubError,
  ValidationError,
} from './github.js';

const MAX_BODY_BYTES = 128 * 1024;

const STATIC_FILES = new Map([
  ['/', { file: 'index.html', type: 'text/html; charset=utf-8' }],
  ['/app.js', { file: 'app.js', type: 'text/javascript; charset=utf-8' }],
  ['/styles.css', { file: 'styles.css', type: 'text/css; charset=utf-8' }],
]);

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  "img-src 'self' data:",
  "style-src 'self'",
  "script-src 'self'",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join('; ');

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
  }
}

export function isLoopbackHostname(hostname) {
  return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]';
}

function hostnameFromHostHeader(host) {
  if (!host) return '';
  try {
    return new URL(`http://${host}`).hostname;
  } catch {
    return '';
  }
}

function isTrustedHost(req) {
  return isLoopbackHostname(hostnameFromHostHeader(req.headers.host));
}

/**
 * Require a state-changing browser request to come from the exact origin that
 * served the page. Together with the Host check this blocks DNS rebinding and
 * cross-site POSTs against the local server.
 */
function originMatchesHost(req) {
  const origin = req.headers.origin;
  if (!origin) return true;

  try {
    const parsedOrigin = new URL(origin);
    const host = req.headers.host;
    if (!host) return false;

    const parsedHost = new URL(`http://${host}`);
    const originPort = parsedOrigin.port
      || (parsedOrigin.protocol === 'https:' ? '443' : '80');
    const hostPort = parsedHost.port
      || (parsedHost.protocol === 'https:' ? '443' : '80');

    return parsedOrigin.protocol === parsedHost.protocol
      && parsedOrigin.hostname === parsedHost.hostname
      && originPort === hostPort;
  } catch {
    return false;
  }
}

function setSecurityHeaders(res) {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    res.setHeader(name, value);
  }
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  setSecurityHeaders(res);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function sendText(res, status, text) {
  setSecurityHeaders(res);
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': Buffer.byteLength(text),
    'Cache-Control': 'no-store',
  });
  res.end(text);
}

function sendStatic(res, type, body) {
  setSecurityHeaders(res);
  res.writeHead(200, {
    'Content-Type': type,
    'Content-Length': body.length,
    'Cache-Control': 'no-cache',
    'Content-Security-Policy': CONTENT_SECURITY_POLICY,
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;

    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooLarge) {
        reject(new HttpError(413, '请求内容过大。'));
        return;
      }
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', reject);
  });
}

async function readJsonBody(req) {
  const raw = await readBody(req);
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError(400, '请求内容不是有效的 JSON。');
  }
}

function publicErrorMessage(error) {
  if (error instanceof HttpError || error instanceof ValidationError) {
    return error.message;
  }
  if (error instanceof GitHubError) {
    return describeGitHubError(error);
  }
  return '服务器内部错误，请查看启动窗口中的日志。';
}

function statusForError(error) {
  if (error instanceof HttpError) return error.status;
  if (error instanceof ValidationError) return 400;
  if (error instanceof GitHubError) return 502;
  return 500;
}

async function handleStatic(url, req, res, publicDir) {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    throw new HttpError(405, '只支持 GET 请求。');
  }

  const asset = STATIC_FILES.get(url.pathname);
  if (!asset) {
    if (url.pathname === '/favicon.ico') {
      res.writeHead(204, { 'Cache-Control': 'public, max-age=86400' });
      res.end();
      return;
    }
    throw new HttpError(404, '页面不存在。');
  }

  let content;
  try {
    content = await readFile(path.join(publicDir, asset.file));
  } catch (error) {
    throw new HttpError(500, `无法读取页面资源：${error.message}`);
  }
  sendStatic(res, asset.type, content);
}

async function handleApiMessages(sync, req, res) {
  if (req.method === 'GET') {
    const snapshot = await sync.getMessages();
    sendJson(res, 200, snapshot);
    return;
  }

  if (req.method !== 'POST') {
    res.setHeader('Allow', 'GET, POST');
    throw new HttpError(405, '只支持 GET 或 POST 请求。');
  }

  if (!originMatchesHost(req)) {
    throw new HttpError(403, '请求来源不受信任。');
  }

  const contentType = String(req.headers['content-type'] || '');
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    throw new HttpError(415, '请求内容必须使用 application/json。');
  }

  const body = await readJsonBody(req);
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new HttpError(400, '请求格式不正确。');
  }
  if (typeof body.text !== 'string') {
    throw new HttpError(400, '缺少 text 字段。');
  }

  const result = await sync.sendMessage(body.text);
  sendJson(res, 201, result);
}

async function handleRequest({ req, res, sync, publicDir, logger }) {
  if (!isTrustedHost(req)) {
    sendText(res, 403, 'Forbidden');
    return;
  }
  if (req.headers['sec-fetch-site'] === 'cross-site') {
    sendText(res, 403, 'Forbidden');
    return;
  }

  const url = new URL(req.url || '/', 'http://127.0.0.1');

  try {
    if (url.pathname.startsWith('/api/')) {
      if (url.pathname === '/api/messages') {
        await handleApiMessages(sync, req, res);
        return;
      }
      throw new HttpError(404, '接口不存在。');
    }

    await handleStatic(url, req, res, publicDir);
  } catch (error) {
    if (res.headersSent) {
      res.destroy();
      return;
    }
    logger.error(`[chat] ${req.method} ${url.pathname}：${error.message}`);
    sendJson(res, statusForError(error), { error: publicErrorMessage(error) });
  }
}

export function createChatServer({ sync, publicDir, logger = console }) {
  return http.createServer((req, res) => {
    handleRequest({ req, res, sync, publicDir, logger }).catch((error) => {
      if (!res.headersSent) {
        sendJson(res, 500, { error: '服务器内部错误。' });
      } else {
        res.destroy();
      }
      logger.error(`[chat] 未处理的请求错误：${error.message}`);
    });
  });
}
