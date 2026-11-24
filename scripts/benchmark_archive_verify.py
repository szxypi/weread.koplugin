#!/usr/bin/env python3
"""Compare complete archive byte verification using synthetic 8 MiB content."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_VERIFY_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='5a450064ef13c697d999997dbd48ace8ec77d675')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-verify-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        old = root / 'source_archive_old.lua'
        old.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/lib/source_archive.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
        size = 8 * 1024 * 1024
        body = hashlib.shake_256(b'synthetic archive verification').digest(size)
        expected = root / 'expected.bin'
        expected.write_bytes(body)
        fixture = root / 'fixture.zip'
        with zipfile.ZipFile(fixture, 'w', compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr('body.bin', body)
        result = {}
        for mode in ('baseline', 'optimized'):
            rows = []
            for _ in range(3):
                env = dict(os.environ, KO_HOME=str(profile))
                code, output, repaint = run_child([str(runtime / 'luajit'),
                    str(repo / 'spec/koreader/source_archive_verify_benchmark.lua'),
                    str(profile / 'plugins/weread.koplugin'), str(old), str(fixture), mode, str(size), str(expected)],
                    env, b'', runtime, timeout=150)
                if code or repaint or output.count(FRAME) != 1:
                    raise ValueError('archive verification benchmark failed')
                rows.append(json.loads(output.split(FRAME)[1]))
            result[mode] = dict(samples=rows, cpu_seconds_median=statistics.median(row['cpu_seconds'] for row in rows),
                                peak_rss_kib_median=statistics.median(row['peak_rss_kib'] for row in rows))
        print(json.dumps(dict(bytes=size, runs=3, cases=result)))


if __name__ == '__main__':
    main()
