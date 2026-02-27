import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOST = '0.0.0.0'
PORT = 8080
BASE_DIR = Path(__file__).resolve().parent
PUBLIC_DIR = BASE_DIR / 'public'

reports = []


class CivicHandler(BaseHTTPRequestHandler):
    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, file_path: Path):
        if not file_path.exists() or not file_path.is_file():
            self.send_error(404, 'Not found')
            return

        content = file_path.read_bytes()
        if file_path.suffix == '.html':
            content_type = 'text/html; charset=utf-8'
        elif file_path.suffix == '.js':
            content_type = 'application/javascript; charset=utf-8'
        elif file_path.suffix == '.css':
            content_type = 'text/css; charset=utf-8'
        else:
            content_type = 'application/octet-stream'

        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()

    def do_GET(self):
        if self.path == '/api/reports':
            self._send_json(reports)
            return

        if self.path == '/health':
            self._send_json({'ok': True, 'service': 'civic-issue-server'})
            return

        if self.path in ('/', '/index.html'):
            self._send_file(PUBLIC_DIR / 'index.html')
            return

        file_path = (PUBLIC_DIR / self.path.lstrip('/')).resolve()
        if str(file_path).startswith(str(PUBLIC_DIR.resolve())):
            self._send_file(file_path)
            return

        self.send_error(404, 'Not found')

    def do_POST(self):
        if self.path != '/report':
            self.send_error(404, 'Not found')
            return

        length = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(length)

        try:
            payload = json.loads(body.decode('utf-8'))
        except json.JSONDecodeError:
            self._send_json({'success': False, 'message': 'Invalid JSON payload.'}, 400)
            return

        required = ['issueType', 'description', 'timestamp']
        if not all(payload.get(k) for k in required):
            self._send_json(
                {
                    'success': False,
                    'message': 'Invalid report payload. issueType, description, timestamp are required.',
                },
                400,
            )
            return

        report = {
            'id': len(reports) + 1,
            **payload,
        }
        reports.insert(0, report)

        self._send_json(
            {'success': True, 'message': 'Report received by authority server.', 'id': report['id']},
            201,
        )


if __name__ == '__main__':
    server = HTTPServer((HOST, PORT), CivicHandler)
    print(f'Civic issue desktop server running on http://{HOST}:{PORT}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
