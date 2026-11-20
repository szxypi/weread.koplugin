#!/usr/bin/env python3
"""Independently verify the synthetic title-recovery EPUB and bitmap pixels."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zipfile
import zlib


def png(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    at, parts, header = 8, [], None
    while at < len(data):
        length = struct.unpack_from('>I', data, at)[0]
        kind, raw = data[at+4:at+8], data[at+8:at+8+length]
        assert zlib.crc32(kind+raw) & 0xffffffff == struct.unpack_from('>I', data, at+8+length)[0]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', raw)
        if kind == b'IDAT':
            parts.append(raw)
        at += length+12
    assert at == len(data) and header
    w, h, depth, color, compression, filtering, interlace = header
    assert color in (0, 2, 4, 6) and (depth == 8 or color == 0 and depth in (1, 2, 4))
    assert (compression, filtering, interlace) == (0, 0, 0)
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    stride, pixel_bytes = (w*channels*depth+7)//8, max(1, (channels*depth+7)//8)
    raw = zlib.decompress(b''.join(parts))
    assert len(raw) == h*(stride+1)
    rows, prior, at = [], bytearray(stride), 0
    for _ in range(h):
        method, row = raw[at], bytearray(raw[at+1:at+1+stride]); at += stride+1
        assert 0 <= method <= 4
        for x in range(stride):
            left, up, corner = (row[x-pixel_bytes] if x >= pixel_bytes else 0), prior[x], (prior[x-pixel_bytes] if x >= pixel_bytes else 0)
            if method == 1:
                row[x] = (row[x]+left) & 255
            elif method == 2:
                row[x] = (row[x]+up) & 255
            elif method == 3:
                row[x] = (row[x]+(left+up)//2) & 255
            elif method == 4:
                prediction = left+up-corner
                distances = [abs(prediction-value) for value in (left, up, corner)]
                row[x] = (row[x]+(left, up, corner)[distances.index(min(distances))]) & 255
        prior = row
        if depth < 8:
            mask = (1 << depth)-1
            row = bytearray(((row[x*depth//8] >> (8-depth-x*depth % 8)) & mask)*255//mask for x in range(w))
        rows.append(row)
    return w, h, channels, rows


def check(root):
    descriptor = json.loads((root/'evidence/mp-title-export.json').read_text())
    assert descriptor['result'] == 'PASS' and descriptor['synthetic_only'] is True
    runtime_root = Path(descriptor.get('run_root', Path(descriptor['source_article']).parents[3]))
    def local(path):
        relative = Path(path).relative_to(runtime_root)
        assert '..' not in relative.parts
        mapped = (root/relative).resolve()
        assert mapped.is_relative_to(root.resolve())
        return mapped
    source = local(descriptor['source_image']).read_bytes()
    tiny = local(descriptor['source_tiny']).read_bytes()
    w, h, channels, rows = png(source)
    assert (w, h) == (48, 48) and rows[3][3*channels] == 0 and rows[3][44*channels] == 255
    assert png(tiny)[:2] == (1, 1)
    with zipfile.ZipFile(local(descriptor['path'])) as archive:
        assert archive.testzip() is None
        entries = archive.infolist()
        assert len({e.filename for e in entries}) == len(entries)
        assert entries[0].filename == 'mimetype' and entries[0].compress_type == zipfile.ZIP_STORED and not entries[0].extra
        assert archive.read('mimetype') == b'application/epub+zip'
        with local(descriptor['path']).open('rb') as handle:
            assert struct.unpack_from('<H', handle.read(30), 28)[0] == 0
        assert all(not name.startswith('/') and '..' not in name.split('/') for name in archive.namelist())
        for name in ['META-INF/container.xml', 'EPUB/package.opf', 'EPUB/article.xhtml', 'EPUB/nav.xhtml']:
            ET.fromstring(archive.read(name))
        ns = {'opf': 'http://www.idpf.org/2007/opf', 'html': 'http://www.w3.org/1999/xhtml'}
        package = ET.fromstring(archive.read('EPUB/package.opf'))
        items = {item.attrib['id']: item.attrib for item in package.findall('opf:manifest/opf:item', ns)}
        assert [e.attrib['idref'] for e in package.findall('opf:spine/opf:itemref', ns)] == ['article']
        for item in items.values():
            assert 'EPUB/'+item['href'] in archive.namelist()
        article = ET.fromstring(archive.read('EPUB/article.xhtml'))
        assert 'TITLETEXT' in ''.join(article.itertext()) and ''.join(article.itertext()).count('图片暂不可用') == 2
        images = article.findall('.//html:img', ns)
        assert len(images) == 3 and len({i.attrib['src'] for i in images}) == 2
        actual = [archive.read('EPUB/'+i.attrib['src']) for i in images]
        assert actual.count(source) == 2 and actual.count(tiny) == 1
        for data in actual:
            png(data)
        for element in article.iter():
            assert element.tag.rsplit('}', 1)[-1] not in ('script', 'iframe', 'object', 'svg')
            assert not any(k.lower().startswith('on') for k in element.attrib)
    return dict(result='PASS', synthetic_only=True, zip_crc=True, xml_manifest_spine=True,
                source_bitmap_sha256=hashlib.sha256(source).hexdigest(), png_crc_and_pixels=True,
                copied_bitmap_bytes_identical=True, embedded_bitmap_preserved=True,
                duplicate_images_share_member=True, missing_images=2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir', type=Path)
    print(json.dumps(check(parser.parse_args().run_dir), indent=2))
