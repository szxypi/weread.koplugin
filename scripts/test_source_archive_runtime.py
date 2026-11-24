#!/usr/bin/env python3
"""Exercise bounded source archive I/O with the real KOReader libarchive binding."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import struct
import subprocess
import warnings
import zipfile

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    args = parser.parse_args()
    root = args.run_dir.resolve()
    root.mkdir(parents=True, exist_ok=False)
    cases = []
    def archive(name, entries, wanted, success, truncate=False):
        path = root / (name + '.zip')
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as output:
                for member, data in entries:
                    output.writestr(member, data)
        if truncate:
            data = path.read_bytes()
            path.write_bytes(data[:max(1, len(data) // 3)])
        hashes = {key: hashlib.sha256(data).hexdigest() for key, data in entries
                  if isinstance(key, str) and key in wanted}
        case = dict(path=str(path), wanted=wanted, success=success, hashes=hashes)
        cases.append(case)
        return case
    wanted = {'body.txt': 64, 'meta.txt': 64}
    warm = archive('valid', [('body.txt', b'safe synthetic body'), ('meta.txt', b'safe metadata')], wanted, True)
    archive('duplicate', [('body.txt', b'safe synthetic body'), ('meta.txt', b'safe metadata'),
                          ('body.txt', b'safe synthetic body')], wanted, False)
    archive('oversize', [('body.txt', b'x' * 65536), ('meta.txt', b'safe metadata')], wanted, False)
    archive('missing', [('body.txt', b'safe synthetic body')], wanted, False)
    archive('truncated', [('body.txt', bytes(range(256)) * 128), ('meta.txt', b'safe metadata')],
            {'body.txt': 65536, 'meta.txt': 64}, False, truncate=True)
    symlink = zipfile.ZipInfo('body.txt')
    symlink.create_system = 3
    symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive('symlink', [(symlink, b'/never/follow/this'), ('meta.txt', b'safe metadata')], wanted, False)
    archive('empty', [('body.txt', b''), ('meta.txt', b'safe metadata')], wanted, True)
    archive('many-headers', [(f'unneeded/{index}.bin', b'') for index in range(5000)] +
            [('body.txt', b'safe synthetic body'), ('meta.txt', b'safe metadata')], wanted, True)
    pattern = bytes((index * 73 + 19) % 256 for index in range(256))
    byte_cases = []
    def byte_archive(name, size, mismatch=None, duplicate=False, bad_crc=False):
        path = root / (name + '.zip')
        body = (pattern * ((size + 255) // 256))[:size]
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as output:
                output.writestr('body.bin', body)
                if duplicate:
                    output.writestr('body.bin', body)
        if bad_crc:
            data = bytearray(path.read_bytes())
            central = data.find(b'PK\x01\x02')
            assert central > 0
            for offset in (14, central + 16):
                struct.pack_into('<I', data, offset, struct.unpack_from('<I', data, offset)[0] ^ 1)
            path.write_bytes(data)
        byte_cases.append(dict(path=str(path), size=size, mismatch=mismatch or 0,
                               success=mismatch is None and not duplicate and not bad_crc,
                               valid_hash=hashlib.sha256(body).hexdigest()))
    for size in (0, 1, 65535, 65536, 65537, 131072, 1048579, 8 * 1024 * 1024):
        byte_archive('byte-size-' + str(size), size)
    for position in (1, 65536, 65537, 131073):
        byte_archive('byte-mismatch-' + str(position), 131073, mismatch=position)
    byte_archive('byte-fallback-mismatch', 65537, mismatch=65537)
    byte_archive('byte-duplicate', 65537, duplicate=True)
    byte_archive('byte-crc', 65537, bad_crc=True)
    metadata_cases=[]
    def metadata_archive(name,entries,success,truncate=False):
        path=root/(name+'.zip')
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED) as output:
                for member,data in entries:output.writestr(member,data)
        if truncate:
            data=path.read_bytes();path.write_bytes(data[:max(1,len(data)//3)])
        hashes={member:hashlib.sha256(data).hexdigest() for member,data in entries if success and isinstance(member,str)
                and member.startswith('OEBPS/weread-position/uid-') and len(member.rsplit('/',1)[1])==73}
        metadata_cases.append(dict(path=str(path),success=success,count=len(hashes),hashes=hashes))
    meta=lambda index: 'OEBPS/weread-position/uid-'+format(index,'064x')+'.meta'
    metadata_archive('metadata-valid',[(meta(1),b'first'),(meta(2),b'second'),('other',b'ignored')],True)
    metadata_archive('metadata-empty',[('other',b'ignored')],True)
    metadata_archive('metadata-duplicate',[(meta(1),b'first'),(meta(1),b'first')],False)
    metadata_archive('metadata-oversize',[(meta(1),b'x'*4097)],False)
    link=zipfile.ZipInfo(meta(1));link.create_system=3;link.external_attr=(stat.S_IFLNK|0o777)<<16
    metadata_archive('metadata-symlink',[(link,b'/never/follow/this')],False)
    metadata_archive('metadata-many',[(meta(index),b'x') for index in range(10001)],False)
    metadata_archive('metadata-total',[(meta(index),b'x'*4096) for index in range(2049)],False)
    metadata_archive('metadata-truncated',[(meta(1),bytes(range(256))*16)],False,truncate=True)
    request = json.dumps(dict(cases=cases, warm=warm,metadata_cases=metadata_cases,byte_cases=byte_cases))
    result = subprocess.run(['./luajit', str(REPO / 'spec/koreader/source_archive_probe.lua'), str(REPO)],
                            cwd=args.koreader.resolve(), input=request, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise SystemExit('FAIL: native archive boundary probe')
    report = json.loads(result.stdout)
    report.update(runtime='KOReader native libarchive', status='PASS')
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
