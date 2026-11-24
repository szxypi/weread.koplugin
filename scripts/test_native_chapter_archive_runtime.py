#!/usr/bin/env python3
"""Exercise native ZIP decryption in the actual KOReader Lua runtime."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

from test_native_chapter_package import ENCRYPTED, archive

REPO = Path(__file__).resolve().parent.parent
MARKER = b'\nWEREAD_NATIVE_ARCHIVE_RESULT='
ENVELOPE = 'vwSvXMONEDngLYTAXw3olg=='
VID = '12345678'


def digest(value):
    return hashlib.sha256(value).hexdigest()


def sample(data, uid='37', envelope=ENVELOPE):
    return {'archive': base64.b64encode(data).decode(), 'chapter_uid': uid, 'vid': VID, 'envelope': envelope}


def fixtures():
    first = b'<p>one</p>'
    second = b'<p>two</p>'
    css = b'p{color:black}'
    png = b'\x89PNG\r\n\x1a\n' + b'synthetic bytes'
    manifest = json.dumps({'chapters': [{'chapterUid': 37, 'files': ['two.html', 'one.html']}]})
    good = archive([('info.txt', manifest), ('one.html', first), ('two.html', second),
                    ('shared.css', css), ('../images/common.png', png)])
    missing = archive([('info.txt', json.dumps({'chapters': [{'chapterUid': 37, 'files': ['absent.html']}]})),
                       ('37.html', first)])
    bad_crc = bytearray(good)
    index = bad_crc.find(b'PK\x01\x02')
    assert index >= 0
    bad_crc[index + 16] ^= 1
    bad_encrypted = bytearray(base64.b64decode(ENCRYPTED))
    name_size, extra_size = struct.unpack_from('<HH', bad_encrypted, 26)
    payload = 30 + name_size + extra_size
    bad_encrypted[payload + 13] ^= 1  # Keep the password check byte intact.
    fallback = sample(base64.b64decode(ENCRYPTED))
    fallback['buffer_fallback'] = True
    entries = [sample(base64.b64decode(ENCRYPTED)), fallback, sample(good), sample(good, uid='38'), sample(missing),
               sample(archive([('../escape.txt', 'unsafe')])), sample(b'bad zip'),
               sample(base64.b64decode(ENCRYPTED), envelope='AAAAAAAAAAAAAAAAAAAAAA=='),
               sample(archive([('37.html', first), ('unused.png', 'not-an-image')])),
               sample(archive([('37.html', first), ('diagram.svg', '<svg/>')])),
               sample(archive([('info.txt', '{"chapters":[],"chapters":[]}'), ('37.html', first)])),
               sample(archive([('info.txt', '{"chapters":[{"chapterUid":9007199254740992,"files":["37.html"]}]}'),
                               ('37.html', first)])), sample(bytes(bad_crc)), sample(bytes(bad_encrypted))]
    expected = [dict(ok=True, body_sha256=digest(b'<p>Synthetic</p>'), css_sha256=digest(b''), is_text=False,
                     web_coordinate_authority=False, assets=[], image_signatures_recognized=True, unusable_resources=0),
                dict(ok=True, body_sha256=digest(b'<p>Synthetic</p>'), css_sha256=digest(b''), is_text=False,
                     web_coordinate_authority=False, assets=[], image_signatures_recognized=True, unusable_resources=0),
                dict(ok=True, body_sha256=digest(second + b'\n' + first), css_sha256=digest(css), is_text=False,
                     web_coordinate_authority=False, image_signatures_recognized=True, unusable_resources=0,
                     assets=[dict(digest=digest(png), mime='image/png', safe_href=True, parent_source=True)]),
                *[dict(ok=False) for _ in range(5)],
                dict(ok=True, body_sha256=digest(first), css_sha256=digest(b''), is_text=False,
                     web_coordinate_authority=False, assets=[], image_signatures_recognized=False, unusable_resources=1),
                dict(ok=True, body_sha256=digest(first), css_sha256=digest(b''), is_text=False,
                     web_coordinate_authority=False, assets=[], image_signatures_recognized=False, unusable_resources=1),
                dict(ok=False), dict(ok=False), dict(ok=False), dict(ok=False)]
    return entries, expected


def run(runtime):
    samples, expected = fixtures()
    env = dict(os.environ, LD_LIBRARY_PATH=str(runtime / 'libs'))
    result = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_chapter_archive_probe.lua'), str(REPO)],
                            cwd=runtime, env=env, input=json.dumps({'samples': samples}).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or result.stdout.count(MARKER) != 1:
        raise RuntimeError('native archive probe failed')
    actual = json.loads(result.stdout.split(MARKER, 1)[1])
    if actual.get('samples') != expected:
        raise RuntimeError('native archive output mismatch')
    print('PASS: encrypted package, manifest order, parent image isolation and rejection cases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())


if __name__ == '__main__':
    main()
