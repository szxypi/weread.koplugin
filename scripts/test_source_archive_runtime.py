#!/usr/bin/env python3
"""Exercise bounded source archive I/O with the real KOReader libarchive binding."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
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
    request = json.dumps(dict(cases=cases, warm=warm,metadata_cases=metadata_cases))
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
