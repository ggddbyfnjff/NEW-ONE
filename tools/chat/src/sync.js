import {
  describeGitHubError,
  normalizeComment,
  ValidationError,
} from './github.js';

const INITIAL_PAGE_SIZE = 100;
const MAX_CACHED_MESSAGES = 500;
const MAX_MESSAGES_IN_SNAPSHOT = 200;
const MAX_MESSAGE_CHARS = 8000;
const REFRESH_CACHE_MS = 1500;

function compareMessages(a, b) {
  const aTime = Date.parse(a.createdAt) || 0;
  const bTime = Date.parse(b.createdAt) || 0;
  if (aTime !== bTime) return aTime - bTime;
  return String(a.id).localeCompare(String(b.id), 'en', { numeric: true });
}

/**
 * Owns the local cache of issue comments and talks to GitHub on behalf of the
 * browser. Polling is coalesced so multiple windows do not multiply API calls.
 */
export class ChatSync {
  constructor({
    client,
    mention,
    pollMs = 4000,
    maxMessages = MAX_MESSAGES_IN_SNAPSHOT,
    logger = console,
  }) {
    this.client = client;
    this.mention = mention;
    this.pollMs = pollMs;
    this.maxMessages = maxMessages;
    this.logger = logger;

    this.messages = new Map();
    this.viewer = '';
    this.issueTitle = '';
    this.issueUrl = '';
    this.initialized = false;
    this.lastSeenAt = '';
    this.lastRefreshAt = 0;
    this.lastError = null;
    this.initPromise = null;
    this.refreshPromise = null;
  }

  get repo() {
    return this.client.repo;
  }

  get issue() {
    return this.client.issue;
  }

  async initialize() {
    if (this.initialized) return this.snapshot();
    if (this.initPromise) return this.initPromise;

    this.initPromise = (async () => {
      const viewer = await this.client.getViewer();
      this.viewer = viewer.login;

      const issue = await this.client.getIssue();
      this.issueTitle = typeof issue?.title === 'string' ? issue.title : '';
      this.issueUrl = typeof issue?.html_url === 'string' ? issue.html_url : '';

      await this.loadInitialMessages();
      this.initialized = true;
      this.lastRefreshAt = Date.now();
      return this.snapshot();
    })().catch((error) => {
      this.initPromise = null;
      throw error;
    });

    return this.initPromise;
  }

  async loadInitialMessages() {
    const firstPage = await this.client.listComments({
      page: 1,
      perPage: INITIAL_PAGE_SIZE,
    });

    const lastPage = firstPage.lastPage || 1;
    const pagesToLoad = lastPage > 2
      ? [lastPage - 1, lastPage]
      : Array.from({ length: lastPage }, (_, index) => index + 1);

    for (const page of pagesToLoad) {
      if (page === 1) {
        this.merge(firstPage.comments);
        continue;
      }
      const result = await this.client.listComments({
        page,
        perPage: INITIAL_PAGE_SIZE,
      });
      this.merge(result.comments);
    }
  }

  trimCache() {
    if (this.messages.size <= MAX_CACHED_MESSAGES) return;

    const sorted = [...this.messages.values()].sort(compareMessages);
    const excess = sorted.length - MAX_CACHED_MESSAGES;
    for (const message of sorted.slice(0, excess)) {
      this.messages.delete(message.id);
    }
  }

  merge(rawComments) {
    if (!Array.isArray(rawComments)) return 0;

    let added = 0;
    let newest = this.lastSeenAt;

    for (const raw of rawComments) {
      const message = normalizeComment(raw, {
        viewerLogin: this.viewer,
        mention: this.mention,
      });
      if (!message.id) continue;

      if (!this.messages.has(message.id)) added += 1;
      this.messages.set(message.id, message);

      if (message.updatedAt) {
        const currentTime = Date.parse(newest || '') || 0;
        const messageTime = Date.parse(message.updatedAt) || 0;
        if (messageTime > currentTime) newest = message.updatedAt;
      }
    }

    this.lastSeenAt = newest;
    this.trimCache();
    return added;
  }

  snapshot(added = 0) {
    const messages = [...this.messages.values()]
      .sort(compareMessages)
      .slice(-this.maxMessages);

    return {
      messages,
      added,
      viewer: this.viewer,
      repo: this.repo,
      issue: this.issue,
      issueTitle: this.issueTitle,
      issueUrl: this.issueUrl,
      mention: this.mention,
      pollIntervalMs: this.pollMs,
      maxMessageChars: MAX_MESSAGE_CHARS,
      lastError: this.lastError ? describeGitHubError(this.lastError) : null,
    };
  }

  async getMessages() {
    if (!this.initialized) return this.initialize();
    return this.refresh();
  }

  async refresh() {
    if (!this.initialized) return this.initialize();
    if (this.refreshPromise) return this.refreshPromise;
    if (Date.now() - this.lastRefreshAt < REFRESH_CACHE_MS) {
      if (this.lastError) throw this.lastError;
      return this.snapshot();
    }

    this.refreshPromise = this.performRefresh().finally(() => {
      this.refreshPromise = null;
    });
    return this.refreshPromise;
  }

  async performRefresh() {
    try {
      const since = this.lastSeenAt
        ? new Date((Date.parse(this.lastSeenAt) || Date.now()) - 2000).toISOString()
        : undefined;

      let page = 1;
      let pages = 0;
      let added = 0;

      while (pages < 10) {
        const result = await this.client.listComments({
          since,
          page,
          perPage: INITIAL_PAGE_SIZE,
        });
        added += this.merge(result.comments);
        pages += 1;

        const lastPage = result.lastPage || 1;
        if (page >= lastPage || result.comments.length < INITIAL_PAGE_SIZE) break;
        page += 1;
      }

      this.lastRefreshAt = Date.now();
      this.lastError = null;
      return this.snapshot(added);
    } catch (error) {
      this.lastError = error;
      // Do not hammer a failing API from every browser poll.
      this.lastRefreshAt = Date.now();
      throw error;
    }
  }

  async sendMessage(rawText) {
    if (!this.initialized) await this.initialize();

    if (typeof rawText !== 'string') {
      throw new ValidationError('消息内容必须是文字。');
    }
    const text = rawText.trim();
    if (!text) throw new ValidationError('消息不能为空。');

    const charCount = [...text].length;
    if (charCount > MAX_MESSAGE_CHARS) {
      throw new ValidationError(`消息不能超过 ${MAX_MESSAGE_CHARS} 个字符。`);
    }

    const created = await this.client.createComment(`${this.mention} ${text}`);
    const message = normalizeComment(created, {
      viewerLogin: this.viewer,
      mention: this.mention,
    });

    if (!message.id) {
      throw new Error('GitHub 没有返回新评论的编号。');
    }

    this.messages.set(message.id, message);
    if (message.updatedAt) {
      const currentTime = Date.parse(this.lastSeenAt || '') || 0;
      const messageTime = Date.parse(message.updatedAt) || 0;
      if (messageTime > currentTime) this.lastSeenAt = message.updatedAt;
    }
    this.trimCache();
    this.lastRefreshAt = Date.now();
    this.lastError = null;

    return {
      message,
      snapshot: this.snapshot(1),
    };
  }
}
