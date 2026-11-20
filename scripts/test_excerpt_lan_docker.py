#!/usr/bin/env python3
"""Synthetic excerpt transfer across two isolated Docker network namespaces.

Requires the existing weread-validation runtime container with /source and
/validation mounts, plus a locally available python:3.12-bookworm image.
No account credentials, production data or external endpoints are used.
"""
import argparse
import base64
import http.client
import ipaddress
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aP8AAAAASUVORK5CYII=')


def client(shared, closed):
    url = (shared/'url').read_text()
    parsed = urlsplit(url)
    address = ipaddress.ip_address(parsed.hostname)
    assert parsed.scheme == 'http' and address.version == 4 and address.is_private and not address.is_loopback
    own_address = socket.gethostbyname(socket.gethostname())
    assert own_address != str(address), 'client is not in a different network namespace'
    if closed:
        conn = http.client.HTTPConnection(str(address), parsed.port, timeout=2)
        try:
            conn.request('GET', parsed.path)
        except OSError:
            print('WEREAD_LAN_CLOSED=PASS')
            return
        finally:
            conn.close()
        raise AssertionError('listener accepted connection after close')
    def request(method, path):
        conn = http.client.HTTPConnection(str(address), parsed.port, timeout=5)
        conn.request(method, path)
        response = conn.getresponse()
        status, headers, body = response.status, response.headers, response.read()
        conn.close()
        return status, headers, body
    status, headers, page = request('GET', parsed.path)
    assert status == 200 and parsed.path.encode()+b'card.png' in page and headers['Cache-Control']=='no-store'
    status, headers, image = request('GET', parsed.path+'card.png')
    assert status == 200 and headers['Content-Type']=='image/png' and image==PNG
    status, headers, body = request('HEAD', parsed.path+'card.png')
    assert status == 200 and int(headers['Content-Length'])==len(PNG) and not body
    status, _, body = request('GET', '/wrong/card.png')
    assert status == 404 and PNG not in body
    print('WEREAD_LAN_CLIENT=PASS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared-dir', type=Path, help='Host path mounted at /validation in the runtime container')
    parser.add_argument('--client-dir', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--closed', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--container', default='weread-validation')
    parser.add_argument('--image', default='python:3.12-bookworm')
    args = parser.parse_args()
    if args.client_dir:
        client(args.client_dir, args.closed)
        return
    if not args.shared_dir:
        parser.error('--shared-dir is required')
    shared = args.shared_dir.resolve()
    repo = Path(__file__).resolve().parent.parent
    temporary = Path(tempfile.mkdtemp(prefix='excerpt-lan-', dir=shared))
    process = None
    try:
        server_dir = '/validation/'+temporary.name
        process = subprocess.Popen(['docker','exec','-e','WEREAD_LAN_DIR='+server_dir,
            '-e','WEREAD_LAN_INTERFACE=eth0',args.container,'sh','-c',
            'cd /validation/runtime/lib/koreader && ./luajit /source/spec/koreader/excerpt_lan_server.lua'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic()+15
        while not (temporary/'url').is_file():
            if process.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('server failed to start')
            time.sleep(.05)
        def run_client(closed=False):
            command = ['docker','run','--rm','--pull=never','--network','bridge',
                '-v',str(temporary)+':/test:ro','-v',str(repo)+':/source:ro',args.image,
                'python3','/source/scripts/test_excerpt_lan_docker.py','--client-dir','/test']
            if closed:
                command.append('--closed')
            result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=True)
            expected = 'WEREAD_LAN_CLOSED=PASS' if closed else 'WEREAD_LAN_CLIENT=PASS'
            assert expected in result.stdout
        run_client()
        (temporary/'stop').touch()
        output, _ = process.communicate(timeout=10)
        assert process.returncode == 0 and 'WEREAD_LAN_SERVER=PASS' in output
        run_client(closed=True)
        print(json.dumps({'result':'PASS','separate_network_namespaces':True,'interface_detection':True,
            'png_download':True,'invalid_url':True,'head':True,'closed_port':True}))
    finally:
        (temporary/'stop').touch(exist_ok=True)
        if process and process.poll() is None:
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill();process.communicate()
        shutil.rmtree(temporary)


if __name__ == '__main__':
    main()
