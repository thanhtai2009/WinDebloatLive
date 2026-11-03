"""Local HTTP server for tests/Test-Rules.ps1: serves the files of one folder.
A file named .mode in that folder changes the behaviour: 'slow' waits 15 s before answering,
'redirect' answers 302, '404' answers 404. Prints the port on the first line."""
import http.server
import os
import sys
import time

ROOT = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        mode = ''
        try:
            with open(os.path.join(ROOT, '.mode'), encoding='utf-8') as f:
                mode = f.read().strip()
        except OSError:
            pass
        if mode == 'slow':
            time.sleep(15)
        if mode == 'redirect':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:1/x')
            self.end_headers()
            return
        name = os.path.basename(self.path.split('?')[0])
        path = os.path.join(ROOT, name)
        if mode == '404' or not name or not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        with open(path, 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
