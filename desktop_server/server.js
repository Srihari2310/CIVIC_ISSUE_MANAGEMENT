const http = require('http');
const fs = require('fs');
const path = require('path');

const HOST = '0.0.0.0';
const PORT = 8080;
const PUBLIC_DIR = path.join(__dirname, 'public');
const reports = [];

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  });
  res.end(body);
}

function sendFile(res, filePath) {
  fs.readFile(filePath, (err, content) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not found');
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType =
      ext === '.html'
        ? 'text/html; charset=utf-8'
        : ext === '.js'
          ? 'application/javascript; charset=utf-8'
          : ext === '.css'
            ? 'text/css; charset=utf-8'
            : 'application/octet-stream';

    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': content.length,
    });
    res.end(content);
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    });
    res.end();
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/reports') {
    sendJson(res, 200, reports);
    return;
  }

  if (req.method === 'GET' && url.pathname === '/health') {
    sendJson(res, 200, { ok: true, service: 'civic-issue-server' });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/report') {
    let raw = '';

    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 20 * 1024 * 1024) {
        sendJson(res, 413, { success: false, message: 'Payload too large.' });
        req.destroy();
      }
    });

    req.on('end', () => {
      let payload;
      try {
        payload = JSON.parse(raw || '{}');
      } catch {
        sendJson(res, 400, { success: false, message: 'Invalid JSON payload.' });
        return;
      }

      if (!payload.issueType || !payload.description || !payload.timestamp) {
        sendJson(res, 400, {
          success: false,
          message: 'Invalid report payload. issueType, description, timestamp are required.',
        });
        return;
      }

      const savedReport = {
        id: Date.now(),
        receivedAt: new Date().toISOString(),
        ...payload,
      };

      reports.unshift(savedReport);
      console.log(
        `[SERVER] Report received id=${savedReport.id} issueType=${savedReport.issueType}`,
      );
      sendJson(res, 201, {
        success: true,
        message: 'Report received by authority server.',
        id: savedReport.id,
      });
    });

    return;
  }

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    sendFile(res, path.join(PUBLIC_DIR, 'index.html'));
    return;
  }

  if (req.method === 'GET') {
    const safePath = path.normalize(url.pathname).replace(/^[/\\]+/, '');
    const filePath = path.join(PUBLIC_DIR, safePath);

    if (!filePath.startsWith(PUBLIC_DIR)) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Forbidden');
      return;
    }

    sendFile(res, filePath);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

server.listen(PORT, HOST, () => {
  console.log(`Civic issue desktop server running on http://${HOST}:${PORT}`);
});
