#!/usr/bin/env python3
"""Check internal HTTPS routes and the WebSocket upgrade without creating users."""
import base64
import hashlib
import json
import os
import socket
import ssl
import urllib.request

host = 'plane.internal.prakash.com.br'
base = 'https://' + host
for path in ['/', '/god-mode/', '/spaces/']:
    with urllib.request.urlopen(base + path, timeout=30) as response:
        assert response.status == 200, f'{path}: HTTP {response.status}'
        assert 'text/html' in response.headers.get('Content-Type', ''), f'{path}: expected HTML'
    print('PASS: HTTPS route', path)
with urllib.request.urlopen(base + '/api/instances/', timeout=30) as response:
    instance = json.load(response)
assert instance['instance']['edition'] == 'PLANE_COMMUNITY', 'Unexpected edition'
assert not instance['config']['enable_signup'], 'Public self-registration is enabled'
print('PASS: Community API and disabled self-registration')
with urllib.request.urlopen(base + '/auth/get-csrf-token/', timeout=30) as response:
    assert json.load(response).get('csrf_token'), 'Missing CSRF token'
print('PASS: authentication CSRF endpoint')
with urllib.request.urlopen(base + '/live/health/', timeout=30) as response:
    assert json.load(response)['status'] == 'OK', 'Collaboration health check failed'
print('PASS: collaboration health endpoint')

nonce = base64.b64encode(os.urandom(16)).decode()
with socket.create_connection((host, 443), timeout=15) as raw:
    with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as conn:
        conn.sendall((
            'GET /live/collaboration/ HTTP/1.1\r\n'
            f'Host: {host}\r\nOrigin: {base}\r\n'
            'Upgrade: websocket\r\nConnection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {nonce}\r\nSec-WebSocket-Version: 13\r\n\r\n'
        ).encode())
        headers = b''
        while b'\r\n\r\n' not in headers:
            part = conn.recv(4096)
            assert part, 'WebSocket closed before handshake'
            headers += part
            assert len(headers) < 65536, 'Oversized WebSocket headers'
        lines = headers.split(b'\r\n\r\n')[0].decode().split('\r\n')
        assert lines[0].split()[1] == '101', 'WebSocket upgrade rejected: ' + lines[0]
        expected = base64.b64encode(hashlib.sha1((nonce + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        # Header names are case insensitive, but the encoded accept value is not.
        accept = next(line.split(':', 1)[1].strip() for line in lines[1:] if line.lower().startswith('sec-websocket-accept:'))
        assert accept == expected, 'Invalid WebSocket accept response'
print('PASS: WebSocket upgrade through TLS ingress')
