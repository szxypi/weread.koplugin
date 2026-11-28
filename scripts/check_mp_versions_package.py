#!/usr/bin/env python3
"""Independently inspect the two synthetic version-export EPUBs; no account I/O."""
import argparse
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zipfile
import zlib

from check_mp_export_package import NS


def bitmap(data):
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    offset = 8
    compressed, kinds = [], []
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        assert zlib.crc32(kind + body) & 0xffffffff == crc
        if kind == b'IHDR':
            assert struct.unpack('>IIBBBBB', body) == (64, 96, 8, 2, 0, 0, 0)
        if kind == b'IDAT':
            compressed.append(body)
        kinds.append(kind)
        offset += length + 12
    assert offset == len(data) and kinds == [b'IHDR', b'IDAT', b'IEND']
    pixels = zlib.decompress(b''.join(compressed))
    assert len(pixels) == 96 * (1 + 64 * 3)
    for row in range(96):
        assert pixels[row * 193:(row + 1) * 193] == b'\0' + bytes((60 + row, 120, 90)) * 64


def check(path, version):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'ZIP CRC failure'
        entries = archive.infolist()
        assert len({entry.filename for entry in entries}) == len(entries)
        assert entries[0].filename == 'mimetype' and entries[0].compress_type == zipfile.ZIP_STORED and not entries[0].extra
        assert archive.read('mimetype') == b'application/epub+zip'
        assert all(not entry.filename.startswith('/') and '..' not in entry.filename.split('/') for entry in entries)
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        rootfile = container.find('container:rootfiles/container:rootfile', NS)
        package = ET.fromstring(archive.read(rootfile.attrib['full-path']))
        assert package.attrib['version'] == '3.0'
        items = {entry.attrib['id']: entry.attrib for entry in package.find('opf:manifest', NS)}
        spine = package.find('opf:spine', NS)
        assert len(spine) == 1 and items[spine[0].attrib['idref']]['href'] == 'article.xhtml'
        article = ET.fromstring(archive.read('EPUB/article.xhtml'))
        text = ''.join(article.itertext())
        assert f'合成版本 {version}' in text
        assert all(f'合成版本 {other}' not in text for other in (1, 2, 3) if other != version)
        images = [entry for entry in items.values() if entry['media-type'].startswith('image/')]
        assert len(images) == 1 and images[0]['media-type'] == 'image/png'
        bitmap(archive.read('EPUB/' + images[0]['href']))
        for image in article.findall('.//html:img', NS):
            assert image.attrib['src'] == images[0]['href']
        for entry in items.values():
            assert 'EPUB/' + entry['href'] in archive.namelist()
            if entry['media-type'] == 'application/xhtml+xml':
                ET.fromstring(archive.read('EPUB/' + entry['href']))
    return dict(zip_crc=True, first_stored_mimetype=True, xml_manifest_spine=True,
                expected_revision_text=True, png_crc_pixels=True, images_inside_archive=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir', type=Path)
    args = parser.parse_args()
    root = args.run_dir / 'profile/weread-mock'
    current = list((root / 'mp-versions-export').glob('*.epub'))
    previous = list((root / 'mp-versions-context/exports/articles').glob('*.epub'))
    assert len(current) == len(previous) == 1, 'expected one new and one historical version export'
    report = dict(result='PASS', synthetic_only=True, exported_files=2,
                  new_version=check(current[0], 2), historical_version=check(previous[0], 1))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
