#!/usr/bin/env node
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadConfig } from './src/config.js';
import { describeGitHubError, GitHubClient } from './src/github.js';
import { createChatServer } from './src/server.js';
import { ChatSync } from './src/sync.js';

const CHAT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(CHAT_DIR, 'public');
const EXPECTED_VIEWER = 'sfdutfsaqutfd';

function printHelp() {
  console.log(`本地聊天小工具（GitHub Issue 版）

用法：
  node server.js [--open]

选项：
  --open   启动后尝试用默认浏览器打开聊天页面
  --help   显示这份帮助

环境变量：
  GITHUB_TOKEN        访问令牌（优先于令牌文件）
  CHAT_TOKEN_FILE     令牌文件路径，默认 ${path.join(CHAT_DIR, 'token.txt')}
  CHAT_REPO           仓库，默认 ggddbyfnjff/NEW-ONE
  CHAT_ISSUE          固定对话 Issue 编号，默认 7
  CHAT_PORT           本地端口，默认 3210
  CHAT_POLL_MS        页面轮询间隔（毫秒），默认 4000
  CHAT_GITHUB_API     GitHub API 地址（仅开发/测试用）

服务只监听 127.0.0.1，不会把令牌发送给浏览器。`);
}

function openBrowser(url) {
  const platform = process.platform;
  const command = platform === 'win32' ? 'cmd' : platform === 'darwin' ? 'open' : 'xdg-open';
  const args = platform === 'win32' ? ['/c', 'start', '', url] : [url];

  return new Promise((resolve) => {
    try {
      const child = spawn(command, args, { detached: true, stdio: 'ignore' });
      child.once('error', () => resolve(false));
      child.once('spawn', () => {
        child.unref();
        resolve(true);
      });
    } catch {
      resolve(false);
    }
  });
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off('listening', onListening);
      reject(error);
    };
    const onListening = () => {
      server.off('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, '127.0.0.1');
  });
}

async function main() {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    printHelp();
    return;
  }

  if (typeof fetch !== 'function' || typeof AbortSignal.timeout !== 'function') {
    console.error('启动失败：需要 Node.js 18 或更高版本，请升级后重试。');
    process.exitCode = 1;
    return;
  }

  let config;
  try {
    config = loadConfig();
  } catch (error) {
    console.error(`启动失败：${error.message}`);
    process.exitCode = 1;
    return;
  }

  const client = new GitHubClient({
    token: config.token,
    repo: config.repo,
    issue: config.issue,
    apiBase: config.apiBase,
  });
  const sync = new ChatSync({
    client,
    mention: config.mention,
    pollMs: config.pollMs,
  });

  console.log('正在连接 GitHub…');
  try {
    await sync.initialize();
  } catch (error) {
    console.error(`启动失败：${describeGitHubError(error)}`);
    process.exitCode = 1;
    return;
  }

  console.log(`已连接：${sync.repo}#${sync.issue}（${sync.issueTitle || '固定对话 Issue'}）`);
  console.log(`发消息使用的账号：@${sync.viewer}（令牌来自${config.tokenSource}）`);
  if (sync.viewer.toLowerCase() !== EXPECTED_VIEWER) {
    console.log(`注意：当前令牌不属于 @${EXPECTED_VIEWER}，消息会以 @${sync.viewer} 的身份发出。`);
  }

  const server = createChatServer({ sync, publicDir: PUBLIC_DIR });
  try {
    await listen(server, config.port);
  } catch (error) {
    if (error.code === 'EADDRINUSE') {
      console.error(`启动失败：端口 ${config.port} 已被占用。请关闭占用该端口的程序，或设置 CHAT_PORT 使用其他端口。`);
    } else {
      console.error(`启动失败：无法监听 127.0.0.1:${config.port}（${error.message}）。`);
    }
    process.exitCode = 1;
    return;
  }

  const url = `http://127.0.0.1:${config.port}/`;
  console.log('');
  console.log(`聊天窗口：${url}`);
  if (sync.issueUrl) console.log(`对话 Issue：${sync.issueUrl}`);
  console.log('保持此窗口开启；按 Ctrl+C 或关闭窗口即可停止服务。');
  console.log('');

  if (process.argv.includes('--open')) {
    const opened = await openBrowser(url);
    if (!opened) {
      console.log('未能自动打开浏览器，请手动打开上面的聊天窗口地址。');
    }
  }

  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((error) => {
  console.error(`启动失败：${error.message}`);
  process.exitCode = 1;
});
