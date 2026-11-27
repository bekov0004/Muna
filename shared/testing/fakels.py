# A fake LocalSend device for tests: python3 fakels.py IP ALIAS MODEL FINGERPRINT [accept|decline|notext] [ACCEPT_DELAY]
# Received files go to /tmp/ls-group/<ALIAS>/<fileName>. A text message (one text/plain entry with
# `preview`) is answered with 204 and its words written to message-preview.txt, as LocalSend does;
# 'notext' takes it as an ordinary file instead (an older receiver).
import http.server, json, os, sys, time
ip, alias, model, fp = sys.argv[1:5]
mode = sys.argv[5] if len(sys.argv) > 5 else 'accept'
delay = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
OUT = os.path.join('/tmp/ls-group', alias); os.makedirs(OUT, exist_ok=True)
names = {}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.endswith('/info'):
            self._json(200, {'alias': alias, 'version': '2.0', 'deviceModel': model, 'deviceType': 'desktop', 'fingerprint': fp, 'download': False})
        else: self._json(404, {})
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        if self.path.startswith('/api/localsend/v2/prepare-upload'):
            body = json.loads(self.rfile.read(n)); time.sleep(delay)
            if mode == 'decline':
                self._json(403, {'message': 'declined'}); return
            files = list(body['files'].values())
            if mode != 'notext' and len(files) == 1 and str(files[0].get('fileType', '')).startswith('text/') and 'preview' in files[0]:
                open(os.path.join(OUT, 'message-preview.txt'), 'w').write(files[0]['preview'])
                self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers(); return
            for k, f in body['files'].items(): names[k] = f['fileName']
            self._json(200, {'sessionId': 's-' + alias, 'files': {k: 'tok-' + k for k in body['files']}})
        elif self.path.startswith('/api/localsend/v2/upload'):
            q = dict(x.split('=') for x in self.path.split('?')[1].split('&'))
            data = b''
            while len(data) < n: data += self.rfile.read(min(65536, n - len(data))); time.sleep(0.01)
            open(os.path.join(OUT, names.get(q['fileId'], q['fileId'])), 'wb').write(data)
            self._json(200, {})
        else:
            self.rfile.read(n); self._json(200, {})
http.server.ThreadingHTTPServer((ip, 53317), H).serve_forever()
