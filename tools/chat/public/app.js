'use strict';

const els = {
  messages: document.getElementById('messages'),
  emptyState: document.getElementById('emptyState'),
  template: document.getElementById('messageTemplate'),
  subtitle: document.getElementById('subtitle'),
  status: document.getElementById('status'),
  statusText: document.getElementById('statusText'),
  issueLink: document.getElementById('issueLink'),
  notice: document.getElementById('notice'),
  composer: document.getElementById('composer'),
  input: document.getElementById('input'),
  send: document.getElementById('send'),
  counter: document.getElementById('counter'),
  meName: document.getElementById('meName'),
};

const state = {
  messages: new Map(),
  nodes: new Map(),
  viewer: '',
  pollMs: 4000,
  maxChars: 8000,
  failures: 0,
  initialized: false,
  refreshing: false,
  sending: false,
  pollTimer: null,
  noticeKind: null,
};

function setStatus(kind, text) {
  els.status.dataset.state = kind;
  els.statusText.textContent = text;
}

function showNotice(text, kind = 'info') {
  els.notice.textContent = text;
  els.notice.hidden = false;
  state.noticeKind = kind;
}

function hideNotice() {
  els.notice.hidden = true;
  els.notice.textContent = '';
  state.noticeKind = null;
}

function isNearBottom() {
  const element = els.messages;
  return element.scrollHeight - element.scrollTop - element.clientHeight < 100;
}

function formatTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';

  const now = new Date();
  const sameDay = date.getFullYear() === now.getFullYear()
    && date.getMonth() === now.getMonth()
    && date.getDate() === now.getDate();

  if (sameDay) {
    return date.toLocaleTimeString('zh-CN', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });
  }
  return date.toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
}

function formatFullTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleString('zh-CN');
}

function createMessageNode(message) {
  const node = els.template.content.firstElementChild.cloneNode(true);
  node.dataset.id = message.id;
  node.classList.add(message.isMe ? 'me' : 'you');

  const role = node.querySelector('.role');
  const author = node.querySelector('.author');
  const time = node.querySelector('time');
  const text = node.querySelector('.message-text');

  role.textContent = message.isMe ? '我' : '你';
  author.textContent = message.isMe ? '' : `@${message.author}`;
  text.textContent = message.text || '';
  time.textContent = formatTime(message.createdAt);
  time.dateTime = message.createdAt || '';
  time.title = formatFullTime(message.createdAt);

  return node;
}

function updateMessageNode(node, message) {
  node.classList.toggle('me', Boolean(message.isMe));
  node.classList.toggle('you', !message.isMe);
  node.querySelector('.role').textContent = message.isMe ? '我' : '你';
  node.querySelector('.author').textContent = message.isMe ? '' : `@${message.author}`;

  const text = node.querySelector('.message-text');
  if (text.textContent !== (message.text || '')) {
    text.textContent = message.text || '';
  }

  const time = node.querySelector('time');
  time.textContent = formatTime(message.createdAt);
  time.dateTime = message.createdAt || '';
  time.title = formatFullTime(message.createdAt);
}

function scrollToBottom(behavior = 'auto') {
  const element = els.messages;
  if (behavior === 'smooth') {
    element.scrollTo({ top: element.scrollHeight, behavior: 'smooth' });
  } else {
    element.scrollTop = element.scrollHeight;
  }
}

function applySnapshot(snapshot, { initial = false, forceScroll = false } = {}) {
  if (!snapshot || !Array.isArray(snapshot.messages)) return;

  const wasNearBottom = isNearBottom();
  const incomingIds = new Set();
  let newPeerMessage = false;

  if (typeof snapshot.viewer === 'string' && snapshot.viewer) {
    state.viewer = snapshot.viewer;
    els.meName.textContent = `@${snapshot.viewer}`;
  }
  if (Number.isInteger(snapshot.pollIntervalMs) && snapshot.pollIntervalMs > 0) {
    state.pollMs = snapshot.pollIntervalMs;
  }
  if (Number.isInteger(snapshot.maxMessageChars) && snapshot.maxMessageChars > 0) {
    state.maxChars = snapshot.maxMessageChars;
    els.input.maxLength = state.maxChars;
  }

  if (typeof snapshot.repo === 'string' && Number.isInteger(snapshot.issue)) {
    const issueLabel = snapshot.issueTitle ? ` · ${snapshot.issueTitle}` : '';
    els.subtitle.textContent = `${snapshot.repo} #${snapshot.issue}${issueLabel}`;
    els.subtitle.title = els.subtitle.textContent;
  }

  if (typeof snapshot.issueUrl === 'string' && /^https?:\/\//i.test(snapshot.issueUrl)) {
    els.issueLink.href = snapshot.issueUrl;
    els.issueLink.hidden = false;
  }

  for (const message of snapshot.messages) {
    if (!message || !message.id) continue;
    incomingIds.add(message.id);

    const existingNode = state.nodes.get(message.id);
    if (existingNode) {
      updateMessageNode(existingNode, message);
    } else {
      const node = createMessageNode(message);
      state.nodes.set(message.id, node);
      els.messages.append(node);
      if (!initial && !message.isMe) newPeerMessage = true;
    }
    state.messages.set(message.id, message);
  }

  for (const [id, node] of state.nodes) {
    if (!incomingIds.has(id)) {
      node.remove();
      state.nodes.delete(id);
      state.messages.delete(id);
    }
  }

  els.emptyState.hidden = state.messages.size > 0;

  if (initial || forceScroll || wasNearBottom || newPeerMessage) {
    requestAnimationFrame(() => {
      scrollToBottom(initial ? 'auto' : 'smooth');
    });
  }

  if (!initial) state.initialized = true;
}

function updateComposer() {
  const value = els.input.value;
  const length = [...value].length;
  els.counter.textContent = `${length} / ${state.maxChars}`;
  els.counter.dataset.over = String(length > state.maxChars);
  els.send.disabled = state.sending || !value.trim() || length > state.maxChars;
  els.send.textContent = state.sending ? '发送中…' : '发送';
}

function resizeInput() {
  els.input.style.height = 'auto';
  els.input.style.height = `${Math.min(els.input.scrollHeight, 168)}px`;
}

function scheduleNextPoll(delay) {
  clearTimeout(state.pollTimer);
  state.pollTimer = setTimeout(() => {
    if (document.hidden) {
      scheduleNextPoll(state.pollMs);
      return;
    }
    refreshMessages();
  }, delay);
}

async function parseResponse(response) {
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const message = data && typeof data.error === 'string'
      ? data.error
      : `请求失败（HTTP ${response.status}）`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return data;
}

async function refreshMessages({ initial = false } = {}) {
  if (state.refreshing) return;
  state.refreshing = true;

  try {
    const response = await fetch('/api/messages', {
      headers: { Accept: 'application/json' },
      cache: 'no-store',
    });
    const snapshot = await parseResponse(response);
    applySnapshot(snapshot, { initial });
    setStatus('online', '已连接');
    if (state.noticeKind !== 'send') hideNotice();
    state.failures = 0;
    if (!state.initialized) state.initialized = true;
    scheduleNextPoll(state.pollMs);
  } catch (error) {
    state.failures += 1;
    setStatus('error', '刷新失败');
    showNotice(`${error.message} 将自动重试。`, 'refresh');
    const delay = Math.min(state.pollMs * (2 ** Math.min(state.failures, 3)), 15000);
    scheduleNextPoll(delay);
  } finally {
    state.refreshing = false;
  }
}

async function sendMessage() {
  const text = els.input.value.trim();
  if (!text || state.sending) return;

  if ([...text].length > state.maxChars) {
    showNotice(`消息不能超过 ${state.maxChars} 个字符。`);
    return;
  }

  state.sending = true;
  updateComposer();
  els.input.disabled = true;

  try {
    const response = await fetch('/api/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({ text }),
    });
    const result = await parseResponse(response);

    els.input.value = '';
    resizeInput();
    hideNotice();
    setStatus('online', '已连接');
    state.failures = 0;

    if (result && result.snapshot) {
      applySnapshot(result.snapshot, { forceScroll: true });
    } else if (result && result.message) {
      applySnapshot({
        messages: [...state.messages.values(), result.message],
        viewer: state.viewer,
      }, { forceScroll: true });
    }

    scheduleNextPoll(state.pollMs);
  } catch (error) {
    setStatus('error', '发送失败');
    showNotice(`${error.message} 消息没有发出去，请重试。`, 'send');
  } finally {
    state.sending = false;
    els.input.disabled = false;
    updateComposer();
    els.input.focus();
  }
}

els.input.addEventListener('input', () => {
  updateComposer();
  resizeInput();
});

els.input.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    els.composer.requestSubmit();
  }
});

els.composer.addEventListener('submit', (event) => {
  event.preventDefault();
  void sendMessage();
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) {
    refreshMessages({ initial: !state.initialized });
  }
});

window.addEventListener('focus', () => {
  if (state.initialized) refreshMessages();
});

updateComposer();
resizeInput();
refreshMessages({ initial: true });
