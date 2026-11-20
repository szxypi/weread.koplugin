#!/usr/bin/env python3
"""Exercise MP metadata changes with a packaged native ReaderUI.

All text, notes and account data are synthetic. No real account or Keychain is
used. A second process reopens every version using its saved location.
--legacy-shared selects the explicit shared-record recovery prototype instead
of the default normal-location migration cases. It does not enable a product UI.
--record-recovery exercises the native product dialogs, storage and reader handoff.
--legacy-title checks title-based HTML, bitmap relocation and record recovery.
--legacy-epub checks EPUB identity without changing original member payloads.
--file-manager checks native file rows, providers, callbacks and record choices.
--metadata-preview checks initial list/history reads, preservation failures and recovery.
"""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import struct
import threading
import warnings
import zipfile
import zlib

from mock_weread import MockServer, prepare

REPO = Path(__file__).resolve().parent.parent


def epub_cases(root):
    """Small, synthetic archive failures; never allocate their declared sizes."""
    directory = root / 'evidence/epub-cases'
    directory.mkdir()
    rows = [('mimetype', b'application/epub+zip'), ('META-INF/container.xml', b'<container/>'),
            ('EPUB/one.xhtml', b'<html><body>synthetic chapter</body></html>')]
    def archive(items=rows, comment=b''):
        output = io.BytesIO()
        with warnings.catch_warnings(), zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as package:
            warnings.simplefilter('ignore', UserWarning)
            for name, data in items:
                if name == 'mimetype':
                    package.writestr(name, data, compress_type=zipfile.ZIP_STORED)
                else:
                    package.writestr(name, data)
            package.comment = comment
        return output.getvalue()
    cases = []
    def save(name, raw, allowed=False):
        (directory / (name+'.epub')).write_bytes(raw)
        cases.append(dict(name=name, allowed=allowed))
    raw = archive()
    save('valid', raw, True)
    save('comment', archive(comment=b'preserved synthetic ZIP comment'), True)
    save('unicode', archive(rows+[('EPUB/中文.xhtml', b'<html/>')]), True)
    folder = zipfile.ZipInfo('EPUB/empty/'); folder.external_attr = (0o40755 << 16) | 0x10
    save('directory', archive(rows+[(folder, b'')]), True)
    extra = zipfile.ZipInfo('EPUB/extra.bin'); extra.extra = struct.pack('<HH', 0x1234, 3)+b'abc'
    save('extra', archive(rows+[(extra, b'payload')]), True)
    large = zipfile.ZipInfo('EPUB/large.bin')  # stored, spans several copy/hash chunks
    save('streamed', archive(rows+[(large, bytes(range(256))*1024)]), True)
    save('duplicate', archive(rows+[rows[-1]]))
    for name in ('../private', '/private', 'EPUB/../private', 'EPUB\\private'):
        save('path-'+str(len(cases)), archive(rows+[(name, b'not extracted')]))
    link = zipfile.ZipInfo('EPUB/link'); link.create_system = 3; link.external_attr = 0o120777 << 16
    save('symlink', archive(rows+[(link, b'one.xhtml')]))
    with zipfile.ZipFile(io.BytesIO(raw)) as package:
        entry = package.getinfo('EPUB/one.xhtml')
    local = entry.header_offset
    name_size, extra_size = struct.unpack_from('<HH', raw, local+26)
    bad = bytearray(raw); bad[local+30+name_size+extra_size+2] ^= 0xff
    save('crc', bad)
    bad = bytearray(raw); bad[local+30] = ord('X'); save('local-central-name', bad)
    central = raw.find(b'PK\x01\x02', local+30+name_size+extra_size+entry.compress_size)
    records=[]; at=central
    while raw[at:at+4] == b'PK\x01\x02':
        records.append(at); n,e,c = struct.unpack_from('<HHH', raw, at+28); at += 46+n+e+c
    assert len(records) == 3
    bad = bytearray(raw); struct.pack_into('<H', bad, records[-1]+8, 1); save('encrypted', bad)
    bad = bytearray(raw); struct.pack_into('<H', bad, records[-1]+10, 99); save('compression', bad)
    bad = bytearray(raw); struct.pack_into('<I', bad, records[-1]+24, 64*1024*1024+1); save('member-limit', bad)
    save('truncated', raw[:-1])
    bad = bytearray(raw); struct.pack_into('<I', bad, len(raw)-22+16, 0xffffffff); save('central-offset', bad)
    save('entry-limit', archive(rows+[(f'EPUB/item-{index}', b'') for index in range(4096)]))
    save('bad-container-name', archive([row for row in rows if row[0] != 'META-INF/container.xml']))
    foreign = zipfile.ZipInfo('EPUB/foreign')
    marker = b'weread-mp-epub-v1\n'+b'b'*64+b'\n'+b'0'*16+b'\n'
    foreign.extra = struct.pack('<HH', 0x5752, len(marker))+marker
    save('foreign-identity', archive(rows+[(foreign, b'foreign')]))
    (directory/'cases.json').write_text(json.dumps(cases)+'\n')


def filemanager_seed(root):
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data) & 0xffffffff)
    pixels = (b'\0'+b'\0'*24+b'\xff'*24)*48
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', 48, 48, 8, 0, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(pixels))+chunk(b'IEND', b'')
    (root/'evidence/fm-seed.png').write_bytes(png)
    paragraph = '<p>这是文件管理器打开流程的合成 EPUB。原始章节、图片和阅读记录完整保留，继续阅读山谷中的故事。</p>'
    body = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>文件管理器</title></head><body><h1>FM_EPUB_TEXT</h1><p><img src="image.png" width="48" height="48"/></p>'+paragraph*300+'</body></html>'
    entries = {
        'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        'EPUB/package.opf': '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">synthetic-filemanager</dc:identifier><dc:title>文件管理器 EPUB</dc:title><dc:language>zh-CN</dc:language></metadata><manifest><item id="article" href="article.xhtml" media-type="application/xhtml+xml"/><item id="png" href="image.png" media-type="image/png"/></manifest><spine><itemref idref="article"/></spine></package>',
        'EPUB/article.xhtml': body,
        'EPUB/image.png': png,
    }
    with zipfile.ZipFile(root/'evidence/fm-seed.epub', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        for name, value in entries.items():
            archive.writestr(name, value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--legacy-shared', action='store_true', help='exercise explicit old shared-record recovery prototype')
    parser.add_argument('--record-recovery', action='store_true', help='exercise the native record-recovery product flow')
    parser.add_argument('--legacy-title', action='store_true', help='exercise title-based HTML recovery and images')
    parser.add_argument('--legacy-epub', action='store_true', help='exercise member-preserving EPUB record recovery')
    parser.add_argument('--file-manager', action='store_true', help='exercise native FileManager article opening')
    parser.add_argument('--reader-history', action='store_true', help='exercise native reader history and direct switching')
    parser.add_argument('--metadata-preview', action='store_true', help='protect actual list and history metadata before article opening')
    args = parser.parse_args()
    if sum((args.legacy_shared, args.record_recovery, args.legacy_title, args.legacy_epub, args.file_manager,args.reader_history,args.metadata_preview)) > 1:
        parser.error('select one metadata validation mode')
    if min(args.width, args.height, args.dpi) < 1:
        parser.error('display dimensions must be positive')
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    if not (runtime / 'luajit').is_file():
        parser.error('requires a built KOReader runtime')
    server = MockServer(0)
    thread = None
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        if args.legacy_epub:
            epub_cases(root)
        if args.file_manager or args.reader_history or args.metadata_preview:
            filemanager_seed(root)
        (root / 'xdg').mkdir(mode=0o700)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = dict(os.environ, KO_HOME=str(root / 'profile'), WEREAD_EVIDENCE=str(root / 'evidence'),
                           XDG_RUNTIME_DIR=str(root / 'xdg'), EMULATE_READER='1', EMULATE_BW_SCREEN='1',
                           EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                           EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
        probe = REPO / ('spec/koreader/mp_legacy_metadata.lua' if args.legacy_shared or args.record_recovery or args.legacy_title or args.legacy_epub or args.file_manager or args.reader_history or args.metadata_preview else 'spec/koreader/mp_metadata_migration.lua')
        phases = ('preview','preview-reopen') if args.metadata_preview else ('reader', 'reader-reopen') if args.reader_history else ('manager', 'manager-reopen') if args.file_manager else ('epub', 'epub-reopen') if args.legacy_epub else ('title', 'title-reopen') if args.legacy_title else ('product', 'product-reopen') if args.record_recovery else ('recover', 'reopen') if args.legacy_shared else ('migrate', 'reopen')
        prefix = 'mp-preview-' if args.metadata_preview else 'mp-reader-' if args.reader_history else 'mp-manager-' if args.file_manager else 'mp-epub-' if args.legacy_epub else 'mp-title-' if args.legacy_title else 'mp-records-' if args.record_recovery else 'mp-legacy-' if args.legacy_shared else 'mp-metadata-'
        for phase in phases:
            log = root / 'evidence' / (prefix + phase + '.log')
            with log.open('w') as output:
                result = subprocess.run(['./luajit', str(probe), phase], cwd=runtime, env=environment,
                                        stdout=output, stderr=subprocess.STDOUT, timeout=180)
            if result.returncode:
                print('FAIL: ' + str(log))
                return result.returncode
            assert b'[WeRead] forceRePaint failed:' not in log.read_bytes(), 'native repaint failed'
            assert not server.events, 'offline metadata migration attempted HTTP'
            print('PASS: ' + str(log), flush=True)
        if args.legacy_title:
            subprocess.run([sys.executable, str(REPO / 'scripts/check_mp_title_package.py'), str(root)], check=True)
        if args.legacy_epub:
            subprocess.run([sys.executable, str(REPO / 'scripts/check_mp_epub_records_package.py'), str(root)], check=True)
        return 0
    finally:
        if thread:
            server.shutdown()
            thread.join()
        server.server_close()


if __name__ == '__main__':
    raise SystemExit(main())
