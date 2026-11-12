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
    request = json.dumps(dict(cases=cases, warm=warm))
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
