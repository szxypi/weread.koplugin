#!/usr/bin/env python3
"""Independent ZIP/member validation for synthetic EPUB record recovery."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zipfile


def local_payload(raw, entry):
    offset = entry.header_offset
    assert raw[offset:offset+4] == b'PK\x03\x04'
    names, extras = struct.unpack_from('<HH', raw, offset+26)
    start = offset+30+names+extras
    return raw[start:start+entry.compress_size], raw[offset+30+names:start]


def compare(source, target):
    before, after = source.read_bytes(), target.read_bytes()
    assert before != after and len(after) >= len(before)
    assert after[:4] == b'PK\x03\x04' and struct.unpack_from('<H', after, 28)[0] == 0
    with zipfile.ZipFile(source) as old, zipfile.ZipFile(target) as new:
        assert old.testzip() is None and new.testzip() is None
        assert old.namelist() == new.namelist() and old.comment == new.comment
        assert new.namelist()[0] == 'mimetype' and new.read('mimetype') == b'application/epub+zip'
        assert new.infolist()[0].compress_type == zipfile.ZIP_STORED
        for a, b in zip(old.infolist(), new.infolist()):
            for field in ('filename', 'CRC', 'compress_size', 'file_size', 'compress_type', 'flag_bits',
                          'create_system', 'create_version', 'extract_version', 'volume', 'internal_attr',
                          'external_attr', 'comment', 'extra', 'date_time'):
                assert getattr(a, field) == getattr(b, field), (a.filename, field)
            assert old.read(a) == new.read(b), a.filename
            compressed, extra = local_payload(before, a)
            copied, current = local_payload(after, b)
            assert compressed == copied, a.filename
            if a.header_offset == sorted(e.header_offset for e in old.infolist())[1]:
                assert current.startswith(struct.pack('<H', 0x5752))
                length = struct.unpack_from('<H', current, 2)[0]
                marker = current[4:4+length]
                assert marker.startswith(b'weread-mp-epub-v1\n') and marker.endswith(b'\n')
                assert marker in after[:1024] and current[4+length:] == extra
            else:
                assert current == extra
        return len(old.infolist())


def check(root):
    descriptor = json.loads((root/'evidence/mp-epub-package.json').read_text())
    assert descriptor['result'] == 'PASS' and descriptor['synthetic_only'] is True
    runtime = Path(descriptor['run_root'])
    def local(path):
        relative = Path(path).relative_to(runtime)
        assert '..' not in relative.parts
        value = (root/relative).resolve()
        assert value.is_relative_to(root.resolve())
        return value
    source = local(descriptor['source'])
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    hashes, counts = set(), set()
    assert len(descriptor['copies']) == 6
    for row in descriptor['copies']:
        assert row['source_html_sha256'] == source_hash
        target = local(row['path'])
        counts.add(compare(source, target))
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        assert digest == row['body_sha256'] and digest not in hashes
        hashes.add(digest)
        with zipfile.ZipFile(target) as archive:
            for name in ('META-INF/container.xml', 'EPUB/package.opf', 'EPUB/nav.xhtml', 'EPUB/one.xhtml', 'EPUB/two.xhtml'):
                ET.fromstring(archive.read(name))
            assert b'EPUBTEXT' in archive.read('EPUB/one.xhtml')
            assert archive.read('EPUB/images/original.png') == local(row['source_image']).read_bytes()
    assert counts == {8}
    for row in descriptor['variants']:
        compare(local(row['source']), local(row['path']))
    assert len(descriptor['variants']) == 6
    return dict(result='PASS', synthetic_only=True, recovered_copies=6, original_members=8,
                zip_crc=True, xml_verified=True, member_names_contents_and_compressed_payloads_identical=True,
                original_zip_metadata_and_comment_preserved=True, unique_copy_digests=True,
                marker_within_first_sample=True, variant_copies=6)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir', type=Path)
    print(json.dumps(check(parser.parse_args().run_dir), indent=2))
