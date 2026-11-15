export const GITHUB_API_VERSION = '2022-11-28';
const USER_AGENT = 'new-one-local-chat/1.0';

export class GitHubError extends Error {
  constructor(status, message, { rateLimitRemaining = null, rateLimitReset = null } = {}) {
    super(message);
    this.name = 'GitHubError';
    this.status = status;
    this.rateLimitRemaining = rateLimitRemaining;
    this.rateLimitReset = rateLimitReset;
  }
}

export class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ValidationError';
  }
}

export function parseLinkHeader(header) {
  const links = {};
  if (!header || typeof header !== 'string') return links;

  for (const part of header.split(',')) {
    const match = part.match(/<([^>]+)>\s*;\s*rel="([^"]+)"/);
    if (match) links[match[2]] = match[1];
  }
  return links;
}

export function pageFromUrl(value) {
  try {
    const page = Number(new URL(value).searchParams.get('page'));
    return Number.isInteger(page) && page > 0 ? page : null;
  } catch {
    return null;
  }
}

export function lastPageFromLinkHeader(header) {
  const links = parseLinkHeader(header);
  return pageFromUrl(links.last || '') || pageFromUrl(links.next || '') || null;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Turn a GitHub issue comment into the small, browser-safe shape the UI needs.
 * The viewer's own leading mention is removed so the chat does not repeat it on
 * every outgoing bubble. A super-agent bookkeeping marker at the end is hidden.
 */
export function displayText(body, { isMe = false, mention = '' } = {}) {
  let text = typeof body === 'string' ? body : '';

  if (isMe && mention) {
    text = text.replace(new RegExp(`^\\s*${escapeRegExp(mention)}\\b[ \\t]*`, 'i'), '');
  }
  text = text.replace(/\n*<!--\s*dsh-superagent:[^>]*-->\s*$/i, '');
  return text.trim();
}

export function normalizeComment(raw, { viewerLogin = '', mention = '' } = {}) {
  const author = raw?.user?.login || 'unknown';
  const isMe = Boolean(viewerLogin) && author.toLowerCase() === viewerLogin.toLowerCase();

  return {
    id: String(raw?.id ?? ''),
    author,
    isMe,
    role: isMe ? 'me' : 'you',
    text: displayText(raw?.body, { isMe, mention }),
    createdAt: raw?.created_at || '',
    updatedAt: raw?.updated_at || raw?.created_at || '',
    url: raw?.html_url || '',
  };
}

function repoPath(repo) {
  const [owner, name] = repo.split('/');
  return `${encodeURIComponent(owner)}/${encodeURIComponent(name)}`;
}

export function describeGitHubError(error) {
  if (!(error instanceof GitHubError)) {
    return '发生未知错误，请查看启动窗口中的日志。';
  }
  if (error.status === 0) return error.message;
  if (error.status === 401) return 'GitHub 令牌无效或已过期，请检查令牌。';
  if (error.status === 403) {
    if (error.rateLimitRemaining === '0') {
      return 'GitHub API 速率已达上限，请稍后重试。';
    }
    return `GitHub 拒绝了请求，请确认令牌拥有该仓库的 Issue 读写权限（${error.message}）。`;
  }
  if (error.status === 404) {
    return '找不到仓库或对话 Issue，请检查 CHAT_REPO 和 CHAT_ISSUE。';
  }
  if (error.status === 422) {
    return `GitHub 拒绝了这条消息：${error.message}`;
  }
  return `GitHub API 错误（${error.status}）：${error.message}`;
}

export class GitHubClient {
  constructor({
    token,
    repo,
    issue,
    apiBase = 'https://api.github.com',
    fetchImpl = globalThis.fetch,
    userAgent = USER_AGENT,
  }) {
    if (!token) throw new ValidationError('GitHub 令牌不能为空。');
    if (typeof fetchImpl !== 'function') {
      throw new ValidationError('需要 Node.js 18 或更高版本（内置 fetch）。');
    }

    this.token = token;
    this.repo = repo;
    this.issue = issue;
    this.apiBase = apiBase.replace(/\/+$/, '');
    this.fetchImpl = fetchImpl;
    this.userAgent = userAgent;
    this.issueApiPath = `/repos/${repoPath(repo)}/issues/${issue}`;
  }

  headers(extra = {}) {
    return {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${this.token}`,
      'X-GitHub-Api-Version': GITHUB_API_VERSION,
      'User-Agent': this.userAgent,
      ...extra,
    };
  }

  async request(pathname, { method = 'GET', body, headers = {} } = {}) {
    const url = /^https?:\/\//i.test(pathname) ? pathname : `${this.apiBase}${pathname}`;
    let response;

    try {
      response = await this.fetchImpl(url, {
        method,
        headers: this.headers(headers),
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(15000),
      });
    } catch (error) {
      throw new GitHubError(0, `无法连接 GitHub API：${error.message}`);
    }

    const raw = await response.text();
    let data = null;
    if (raw) {
      try {
        data = JSON.parse(raw);
      } catch {
        data = raw;
      }
    }

    if (!response.ok) {
      const message = data && typeof data === 'object' && data.message
        ? data.message
        : `请求失败（HTTP ${response.status}）`;
      throw new GitHubError(response.status, message, {
        rateLimitRemaining: response.headers.get('x-ratelimit-remaining'),
        rateLimitReset: response.headers.get('x-ratelimit-reset'),
      });
    }

    return { data, headers: response.headers };
  }

  async getViewer() {
    const { data } = await this.request('/user');
    if (!data || typeof data.login !== 'string' || !data.login) {
      throw new GitHubError(0, 'GitHub 没有返回当前账号信息。');
    }
    return data;
  }

  async getIssue() {
    const { data } = await this.request(this.issueApiPath);
    return data;
  }

  async listComments({ since, page = 1, perPage = 100 } = {}) {
    const params = new URLSearchParams({
      per_page: String(perPage),
      page: String(page),
    });
    if (since) params.set('since', since);

    const { data, headers } = await this.request(
      `${this.issueApiPath}/comments?${params.toString()}`
    );
    if (!Array.isArray(data)) {
      throw new GitHubError(0, 'GitHub 返回的评论列表格式不正确。');
    }
    return {
      comments: data,
      lastPage: lastPageFromLinkHeader(headers.get('link')),
    };
  }

  async createComment(body) {
    if (typeof body !== 'string' || !body.trim()) {
      throw new ValidationError('评论内容不能为空。');
    }
    const { data } = await this.request(`${this.issueApiPath}/comments`, {
      method: 'POST',
      body: { body },
      headers: { 'Content-Type': 'application/json' },
    });
    return data;
  }
}
