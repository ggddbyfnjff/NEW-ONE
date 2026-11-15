import http from 'node:http';

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function parsePage(value, fallback = 1) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

/**
 * A tiny in-memory stand-in for the handful of GitHub REST endpoints this tool
 * uses. It keeps tests offline and lets us assert exactly what gets posted.
 */
export class MockGitHub {
  constructor({
    token = 'test-token',
    viewer = 'sfdutfsaqutfd',
    repo = 'ggddbyfnjff/NEW-ONE',
    issue = 7,
    comments = [],
  } = {}) {
    this.token = token;
    this.viewer = viewer;
    this.repo = repo;
    this.issue = issue;
    this.issueTitle = '本地聊天工具 · 固定对话区';
    this.comments = [];
    this.nextId = 1000;
    this.requests = [];
    this.rejectPost = false;
    this.server = http.createServer((req, res) => {
      this.handle(req, res).catch((error) => {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ message: error.message }));
      });
    });

    for (const comment of comments) this.addComment(comment);
  }

  addComment({ author = this.viewer, body = '', createdAt } = {}) {
    const id = this.nextId++;
    const time = createdAt || new Date(Date.now() + id).toISOString();
    const comment = {
      id,
      body,
      created_at: time,
      updated_at: time,
      html_url: `https://github.com/${this.repo}/issues/${this.issue}#issuecomment-${id}`,
      user: { login: author },
    };
    this.comments.push(comment);
    return comment;
  }

  async start() {
    await new Promise((resolve) => this.server.listen(0, '127.0.0.1', resolve));
    this.port = this.server.address().port;
    this.baseUrl = `http://127.0.0.1:${this.port}`;
    return this.baseUrl;
  }

  async stop() {
    if (!this.server.listening) return;
    await new Promise((resolve) => this.server.close(resolve));
  }

  json(res, status, payload, headers = {}) {
    const body = JSON.stringify(payload);
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
      ...headers,
    });
    res.end(body);
  }

  commentsUrl(requestUrl, page) {
    const url = new URL(requestUrl, this.baseUrl);
    url.searchParams.set('page', String(page));
    return url.toString();
  }

  async handle(req, res) {
    const requestUrl = new URL(req.url, this.baseUrl || 'http://127.0.0.1');
    const auth = req.headers.authorization || '';
    this.requests.push({
      method: req.method,
      path: requestUrl.pathname,
      search: requestUrl.search,
      headers: req.headers,
    });

    if (auth !== `Bearer ${this.token}`) {
      this.json(res, 401, { message: 'Bad credentials' });
      return;
    }

    const prefix = `/repos/${this.repo}/issues/${this.issue}`;

    if (req.method === 'GET' && requestUrl.pathname === '/user') {
      this.json(res, 200, { login: this.viewer });
      return;
    }

    if (req.method === 'GET' && requestUrl.pathname === `/repos/${this.repo}`) {
      this.json(res, 200, { full_name: this.repo });
      return;
    }

    if (req.method === 'GET' && requestUrl.pathname === prefix) {
      this.json(res, 200, {
        number: this.issue,
        title: this.issueTitle,
        html_url: `https://github.com/${this.repo}/issues/${this.issue}`,
      });
      return;
    }

    if (req.method === 'GET' && requestUrl.pathname === `${prefix}/comments`) {
      const perPage = Math.min(parsePage(requestUrl.searchParams.get('per_page'), 100), 100);
      const page = parsePage(requestUrl.searchParams.get('page'), 1);
      const since = requestUrl.searchParams.get('since');

      let comments = [...this.comments];
      if (since) {
        const sinceTime = Date.parse(since);
        if (!Number.isNaN(sinceTime)) {
          comments = comments.filter((comment) => Date.parse(comment.updated_at) > sinceTime);
        }
      }
      comments.sort((a, b) => a.id - b.id);

      const totalPages = Math.max(1, Math.ceil(comments.length / perPage));
      const start = (page - 1) * perPage;
      const pageComments = comments.slice(start, start + perPage);

      const headers = {};
      if (page < totalPages) {
        const links = [];
        links.push(`<${this.commentsUrl(req.url, page + 1)}>; rel="next"`);
        links.push(`<${this.commentsUrl(req.url, totalPages)}>; rel="last"`);
        headers.Link = links.join(', ');
      }

      this.json(res, 200, pageComments, headers);
      return;
    }

    if (req.method === 'POST' && requestUrl.pathname === `${prefix}/comments`) {
      const rawBody = await readRequestBody(req);
      this.requests.at(-1).body = rawBody;

      if (this.rejectPost) {
        this.json(res, 403, { message: 'Resource not accessible by integration' });
        return;
      }

      let parsed;
      try {
        parsed = JSON.parse(rawBody);
      } catch {
        this.json(res, 400, { message: 'Problems parsing JSON' });
        return;
      }

      const comment = this.addComment({ body: parsed.body });
      this.json(res, 201, comment);
      return;
    }

    this.json(res, 404, { message: 'Not Found' });
  }
}
