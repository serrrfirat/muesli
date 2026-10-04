#!/usr/bin/env python3
"""Launch the real app against explicit external mocks and own server cleanup."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
url = f'http://127.0.0.1:{port}'
server = subprocess.Popen([sys.executable, str(ROOT / 'proxy/server.py'), '--mock', '--port', str(port)], stdout=subprocess.DEVNULL)
try:
    for _ in range(100):
        if server.poll() is not None: raise RuntimeError('Mock service failed to start')
        try:
            with urllib.request.urlopen(url + '/health', timeout=1) as response:
                if response.status == 200: break
        except OSError: time.sleep(.1)
    else: raise RuntimeError('Mock service not ready')
    print('Launching native app with EXPLICIT MOCK external services. No real TEE, inference or staking guarantee.', flush=True)
    environment = dict(os.environ)
    environment.pop('HUSH_UPSTREAM_API_KEY', None)
    app = subprocess.Popen([str(ROOT / 'dist/Hush.app/Contents/MacOS/Hush'), '--mock', '--endpoint', url, *sys.argv[1:]], env=environment)
    try: sys.exit(app.wait())
    except KeyboardInterrupt:
        app.terminate(); app.wait(timeout=10)
finally:
    server.terminate()
    try: server.wait(timeout=5)
    except subprocess.TimeoutExpired: server.kill(); server.wait()
